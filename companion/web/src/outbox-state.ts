// Durable attempt/results and outcomes admission (companion-v0 §§9.8, 10.2–10.3).
import type { BrowserState, Pairing } from './browser-store.ts';
import type { OutboxEntry } from './outbox.ts';
import { OutboxError } from './outbox.ts';
import { openOutcomes } from './outcomes-payloads.ts';

export interface SendAttempt {
    generation: string; deviceId: string; relayOrigin: string; token: string; entry: OutboxEntry;
}
const day30 = 30 * 86400000;
function time(now: number): string {
    const value = new Date(now).toISOString().replace(/\.\d{3}Z$/, 'Z');
    if (value.length !== 20) throw new OutboxError();
    return value;
}
function expired(value: string | null, now: number): boolean {
    return value !== null && now - Date.parse(value) >= day30;
}
function guard(tx: IDBTransaction, work: () => void): () => void {
    return () => { try { work(); } catch { tx.abort(); } };
}

/** All callbacks perform only synchronous IDB work; success waits for complete, including no-op results. */
function write<T>(db: IDBDatabase, work: (state: BrowserState | undefined, tx: IDBTransaction,
    done: (value: T) => void) => void): Promise<T> {
    return new Promise((resolve, reject) => {
        let tx: IDBTransaction;
        try {
            tx = db.transaction(['state', 'outbox'], 'readwrite', { durability: 'strict' });
            if (tx.durability !== 'strict') { tx.abort(); throw new OutboxError(); }
        } catch { reject(new OutboxError()); return; }
        let result: T;
        tx.oncomplete = () => resolve(result);
        tx.onabort = () => reject(new OutboxError()); tx.onerror = () => reject(new OutboxError());
        const request = tx.objectStore('state').get('current');
        request.onsuccess = guard(tx, () => {
            const state = request.result as BrowserState | undefined;
            if (state && state.version !== 1) throw new OutboxError();
            work(state, tx, value => { result = value; });
        });
    });
}

/** §9.8 step 2: under the send lock, choose the lowest pending seq and commit attempted before returning bytes. */
export function beginAttempt(db: IDBDatabase, now: number): Promise<SendAttempt | null> {
    const nowText = time(now);
    return write(db, (state, tx, done) => {
        const p = state?.pairing;
        if (!p || p.sendingSuspended) { done(null); return; }
        const store = tx.objectStore('outbox'), index = store.index('by-generation-state-seq');
        const candidates: (OutboxEntry | null)[] = [];
        for (const status of ['queued', 'attempted']) {
            const request = index.openCursor(IDBKeyRange.bound([p.generation, status], [p.generation, status, []]));
            request.onsuccess = guard(tx, () => {
                const cursor = request.result;
                if (cursor) {
                    const entry = cursor.value as OutboxEntry;
                    if (status === 'queued' ? expired(entry.madeAt, now) : expired(entry.firstAttemptedAt, now)) {
                        entry.state = status === 'queued' ? 'not sent' : 'unresolved';
                        cursor.update(entry); cursor.continue(); return;
                    }
                }
                candidates.push(cursor ? cursor.value as OutboxEntry : null);
                if (candidates.length !== 2) return;
                const entry = candidates.filter((e): e is OutboxEntry => e !== null).sort((a, b) => a.seq - b.seq)[0];
                if (!entry) { done(null); return; }
                const deadline = entry.nextAttemptAt === null ? now : Date.parse(entry.nextAttemptAt);
                if (deadline > now && deadline <= now + 300000) { done(null); return; }
                if (!entry.bytes) throw new OutboxError();
                if (entry.state === 'queued') {
                    entry.state = 'attempted'; entry.firstAttemptedAt = nowText;
                    store.put(entry, [entry.generation, entry.seq, entry.requestId]);
                }
                done({ generation: p.generation, deviceId: p.deviceId, relayOrigin: p.relayOrigin, token: p.token, entry });
            });
        }
    });
}

/** §9.8 step 2.4: late replies cannot recreate or overwrite an entry that an outcome already resolved. */
export function recordAttempt(db: IDBDatabase, attempt: SendAttempt, status: number | null, now: number): Promise<boolean> {
    const nowText = time(now);
    return write(db, (state, tx, done) => {
        if (state?.pairing?.generation !== attempt.generation) { done(false); return; }
        const store = tx.objectStore('outbox'), key = [attempt.generation, attempt.entry.seq, attempt.entry.requestId];
        const request = store.get(key);
        request.onsuccess = guard(tx, () => {
            const entry = request.result as OutboxEntry | undefined;
            if (!entry || entry.state !== 'attempted') { done(false); return; }
            if (status === 201 || status === 409) {
                entry.state = 'sent'; entry.sentAt = nowText; delete entry.bytes;
            } else if (status !== null && status >= 400 && status < 500 && status !== 429) {
                entry.state = 'unresolved';
                if (status === 401 || status === 403) {
                    state.pairing!.sendingSuspended = true; tx.objectStore('state').put(state, 'current');
                }
            } else {
                entry.backoff = entry.backoff === 0 ? 2 : Math.min(300, entry.backoff * 2);
                entry.nextAttemptAt = time(now + entry.backoff * 1000);
            }
            store.put(entry, key); done(true);
        });
    });
}

async function pairing(db: IDBDatabase): Promise<Pairing | undefined> {
    return new Promise((resolve, reject) => {
        let tx: IDBTransaction;
        try { tx = db.transaction('state', 'readonly'); } catch { reject(new OutboxError()); return; }
        const request = tx.objectStore('state').get('current');
        tx.oncomplete = () => resolve(request.result?.pairing);
        tx.onabort = () => reject(new OutboxError()); tx.onerror = () => reject(new OutboxError());
    });
}

/** §§9.8 step 3, 10.2: authenticated outcomes and their high-water mark commit with matching entry transitions. */
export async function acceptOutcomes(db: IDBDatabase, revision: number, input: Uint8Array, generation?: string): Promise<boolean> {
    const bytes = input.slice();
    for (let retry = 0; retry <= 3; retry++) {
        const before = await pairing(db);
        if (!before || (generation !== undefined && before.generation !== generation) || revision < before.outcomesRevision) return false;
        const opened = await openOutcomes(before.deviceId, revision, before.deviceKey, before.ownerKey, bytes);
        const committed = await write(db, (state, tx, done) => {
            const p = state?.pairing;
            if (!p || p.generation !== before.generation || p.deviceId !== before.deviceId || p.epoch !== before.epoch ||
                revision < p.outcomesRevision) { done(false); return; }
            p.outcomesRevision = revision; tx.objectStore('state').put(state, 'current');
            const store = tx.objectStore('outbox');
            for (const outcome of opened.outcomes) {
                const key = [p.generation, outcome.seq, outcome.requestId], request = store.get(key);
                request.onsuccess = guard(tx, () => {
                    const entry = request.result as OutboxEntry | undefined;
                    if (!entry || !['attempted', 'sent', 'unresolved'].includes(entry.state)) return;
                    if (outcome.outcome === 'applied') store.delete(key);
                    else {
                        entry.state = outcome.outcome === 'unknown' ? 'unresolved' : outcome.outcome;
                        store.put(entry, key);
                    }
                });
            }
            done(true);
        });
        if (committed) return true;
    }
    return false;
}

/** §9.8: refreshes expire the outbox in bounded pages; sent actions remain visible as unresolved after 30 days. */
export function expireOutbox(db: IDBDatabase, now: number, limit = 100, after?: IDBValidKey): Promise<IDBValidKey | null> {
    time(now);
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100) throw new OutboxError();
    return write(db, (state, tx, done) => {
        const p = state?.pairing;
        if (!p || (after !== undefined && (!Array.isArray(after) || after[0] !== p.generation))) { done(null); return; }
        const range = IDBKeyRange.bound(after ?? [p.generation], [p.generation, []], after !== undefined);
        const request = tx.objectStore('outbox').openCursor(range);
        let count = 0, next: IDBValidKey | null = null;
        request.onsuccess = guard(tx, () => {
            const cursor = request.result;
            if (!cursor) { done(null); return; }
            if (count === limit) { done(next); return; }
            const entry = cursor.value as OutboxEntry;
            if (entry.state === 'queued' && expired(entry.madeAt, now)) { entry.state = 'not sent'; cursor.update(entry); }
            else if (['attempted', 'sent'].includes(entry.state) && expired(entry.firstAttemptedAt, now)) {
                entry.state = 'unresolved'; cursor.update(entry);
            }
            count++; next = cursor.key; cursor.continue();
        });
    });
}
