// Durable numbering/enqueue; network attempts are a separate component (companion-v0 §9.8 step 1).
import type { BrowserState } from './browser-store.ts';
import { encodeB64 } from './encoding.ts';
import { sealRequest, validateAction } from './device-payloads.ts';
import type { RequestAction, RequestType } from './device-payloads.ts';

export class OutboxError extends Error {
    constructor() { super('The action could not be saved. Keep your draft and try again.'); }
}
export interface OutboxEntry {
    generation: string; seq: number; requestId: string; type: RequestType;
    state: 'queued' | 'attempted' | 'sent' | 'not sent' | 'conflict' | 'rejected' | 'unresolved';
    madeAt: string; firstAttemptedAt: string | null; backoff: number; nextAttemptAt: string | null;
    bytes?: Uint8Array;
}

function snapshot(db: IDBDatabase): Promise<BrowserState | undefined> {
    return new Promise((resolve, reject) => {
        let tx: IDBTransaction;
        try { tx = db.transaction('state', 'readonly'); } catch { reject(new OutboxError()); return; }
        const request = tx.objectStore('state').get('current');
        tx.oncomplete = () => resolve(request.result);
        tx.onabort = () => reject(new OutboxError()); tx.onerror = () => reject(new OutboxError());
    });
}

/** §9.8 step 1: never seal a started action for a different generation; save sequence and ciphertext atomically. */
export async function enqueue(db: IDBDatabase, action: RequestAction, madeAt: string): Promise<OutboxEntry> {
    const valid = validateAction(action);
    let initial = await snapshot(db), p = initial?.pairing;
    if (initial?.version !== 1 || !p) throw new OutboxError();
    const generation = p.generation, deviceId = p.deviceId, relayOrigin = p.relayOrigin;
    for (;;) {
        if (!Number.isSafeInteger(p.nextSeq) || p.nextSeq < 1 || p.nextSeq >= Number.MAX_SAFE_INTEGER) throw new OutboxError();
        const seq = p.nextSeq, requestId = encodeB64(crypto.getRandomValues(new Uint8Array(16)));
        const bytes = await sealRequest(deviceId, requestId, p.epoch, p.deviceKey, valid, seq, madeAt);
        const entry: OutboxEntry = { generation, seq, requestId, type: valid.type, state: 'queued', madeAt,
            firstAttemptedAt: null, backoff: 0, nextAttemptAt: null, bytes };
        const result = await new Promise<{ entry?: OutboxEntry; state?: BrowserState }>((resolve, reject) => {
            let tx: IDBTransaction;
            try {
                tx = db.transaction(['state', 'outbox'], 'readwrite', { durability: 'strict' });
                if (tx.durability !== 'strict') { tx.abort(); throw new OutboxError(); }
            } catch { reject(new OutboxError()); return; }
            let result: { entry?: OutboxEntry; state?: BrowserState };
            tx.oncomplete = () => resolve(result);
            tx.onabort = () => reject(new OutboxError()); tx.onerror = () => reject(new OutboxError());
            const stateStore = tx.objectStore('state'), outbox = tx.objectStore('outbox'), read = stateStore.get('current');
            read.onsuccess = () => {
                try {
                    const state = read.result as BrowserState | undefined, current = state?.pairing;
                    if (state && state.version !== 1) throw new OutboxError();
                    if (!current || current.generation !== generation || current.deviceId !== deviceId || current.relayOrigin !== relayOrigin) {
                        entry.state = 'not sent'; delete entry.bytes;
                        outbox.add(entry, [generation, seq, requestId]); result = { entry };
                    } else if (current.nextSeq !== seq) result = { state };
                    else {
                        current.nextSeq = seq + 1;
                        stateStore.put(state, 'current'); outbox.add(entry, [generation, seq, requestId]); result = { entry };
                    }
                } catch { tx.abort(); }
            };
        });
        if (result.entry) return result.entry;
        initial = result.state; p = initial?.pairing;
        if (!p) throw new OutboxError();
        // No write occurred; another window took the number. Reseal with its new seq and a new R.
    }
}

export interface OutboxPage { entries: Omit<OutboxEntry, 'bytes'>[]; next: IDBValidKey | null }

/** Bounded metadata pages for pending-action display; never materializes the whole ciphertext queue. */
export function readOutbox(db: IDBDatabase, limit = 50, after?: IDBValidKey): Promise<OutboxPage> {
    return new Promise((resolve, reject) => {
        if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100) { reject(new OutboxError()); return; }
        let tx: IDBTransaction;
        try { tx = db.transaction('outbox', 'readonly'); } catch { reject(new OutboxError()); return; }
        const entries: Omit<OutboxEntry, 'bytes'>[] = [];
        let next: IDBValidKey | null = null;
        let request: IDBRequest<IDBCursorWithValue | null>;
        try { request = tx.objectStore('outbox').openCursor(after === undefined ? null : IDBKeyRange.lowerBound(after, true)); }
        catch { tx.abort(); reject(new OutboxError()); return; }
        request.onsuccess = () => {
            const cursor = request.result;
            if (!cursor) { next = null; return; }
            if (entries.length === limit) return;
            const { bytes: _bytes, ...metadata } = cursor.value as OutboxEntry;
            entries.push(metadata); next = cursor.key; cursor.continue();
        };
        tx.oncomplete = () => resolve({ entries, next });
        tx.onabort = () => reject(new OutboxError()); tx.onerror = () => reject(new OutboxError());
    });
}
