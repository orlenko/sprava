// Encrypted browser state and atomic admission (companion-v0 §§5.2, 10.2–10.3).
import { decodeB64, encodeB64, isId } from './encoding.ts';
import { openDeviceKeys, openIndex, openPairingDelivery } from './owner-payloads.ts';
import { isRelayOrigin } from './pairing-link.ts';
import { isTime } from './payload.ts';
import { beginAttempt, recordAttempt, acceptOutcomes, expireOutbox } from './outbox-state.ts';
import type { SendAttempt } from './outbox-state.ts';
import { enqueue, readOutbox } from './outbox.ts';
import type { OutboxEntry, OutboxPage } from './outbox.ts';
import type { RequestAction } from './device-payloads.ts';
import { openView } from './view-payloads.ts';

export class StorageError extends Error {
    constructor() { super('Browser storage could not complete the operation.'); }
}

export interface Reservation { generation: string; pairingId: string }
export interface Pairing {
    generation: string; pairingId: string; deviceId: string; relayOrigin: string; instanceId: string;
    token: string; expiresAt: string; acknowledgementPending: boolean;
    accountKey: CryptoKey; deviceKey: CryptoKey; ownerKey: CryptoKey;
    epoch: number; minIndexRevision: number; nextSeq: number; outcomesRevision: number; sendingSuspended?: boolean;
}
export interface StoredIndex {
    revision: number; epoch: number; bytes: Uint8Array;
    binders: { id: string; viewVersion: number; key: CryptoKey }[];
}
export interface StoredView { version: number; epoch: number; bytes: Uint8Array }
export interface BrowserState {
    version: 1; reservation?: Reservation; pairing?: Pairing; index?: StoredIndex;
    viewMarks: Record<string, number>;
}
export interface Installation {
    deviceId: string; relayOrigin: string; instanceId: string; token: string; expiresAt: string;
    deviceKey: CryptoKey; wrapKey: CryptoKey; delivery: Uint8Array;
}
const empty = (): BrowserState => ({ version: 1, viewMarks: {} });
const positive = (n: number) => Number.isSafeInteger(n) && n > 0;
function deviceKey(key: CryptoKey): boolean {
    return !key.extractable && key.type === 'secret' && key.algorithm.name === 'AES-GCM' &&
        (key.algorithm as AesKeyAlgorithm).length === 256 && key.usages.includes('encrypt') && key.usages.includes('decrypt');
}

/** One profile, one database; callers never acknowledge or display until these promises resolve. */
export class BrowserStore {
    private readonly db: IDBDatabase;
    private constructor(db: IDBDatabase) { this.db = db; }

    static open(name = 'sprava-companion', factory: IDBFactory = indexedDB): Promise<BrowserStore> {
        return new Promise((resolve, reject) => {
            let failed = false;
            const request = factory.open(name, 1);
            const fail = () => { failed = true; reject(new StorageError()); };
            request.onupgradeneeded = event => {
                if (event.oldVersion !== 0) { request.transaction!.abort(); return; }
                request.result.createObjectStore('state');
                request.result.createObjectStore('outbox').createIndex('by-generation-state-seq', ['generation', 'state', 'seq']);
                request.result.createObjectStore('views');
            };
            request.onerror = fail;
            request.onblocked = fail;
            request.onsuccess = () => {
                if (failed) { request.result.close(); return; }
                request.result.onversionchange = () => request.result.close();
                resolve(new BrowserStore(request.result));
            };
        });
    }
    close(): void { this.db.close(); }
    enqueue(action: RequestAction, madeAt: string): Promise<OutboxEntry> { return enqueue(this.db, action, madeAt); }
    readOutbox(limit = 50, after?: IDBValidKey): Promise<OutboxPage> { return readOutbox(this.db, limit, after); }

    beginAttempt(now: number): Promise<SendAttempt | null> { return beginAttempt(this.db, now); }
    recordAttempt(attempt: SendAttempt, status: number | null, now: number): Promise<boolean> {
        return recordAttempt(this.db, attempt, status, now);
    }
    acceptOutcomes(revision: number, bytes: Uint8Array): Promise<boolean> { return acceptOutcomes(this.db, revision, bytes); }

    expireOutbox(now: number, limit = 100, after?: IDBValidKey): Promise<IDBValidKey | null> {
        return expireOutbox(this.db, now, limit, after);
    }

    // No promises or WebCrypto inside the callback: only IDB work keeps a transaction alive.
    private transaction<T>(write: boolean, change: (state: BrowserState, views: IDBObjectStore) => { value: T; save?: boolean }): Promise<T> {
        return new Promise((resolve, reject) => {
            let tx: IDBTransaction;
            try {
                tx = this.db.transaction(['state', 'views'], write ? 'readwrite' : 'readonly',
                    write ? { durability: 'strict' } : undefined);
                if (write && tx.durability !== 'strict') { tx.abort(); throw new StorageError(); }
            } catch { reject(new StorageError()); return; }
            let result: T;
            tx.onabort = () => reject(new StorageError());
            tx.onerror = () => reject(new StorageError());
            tx.oncomplete = () => resolve(result);
            const store = tx.objectStore('state'), request = store.get('current');
            request.onsuccess = () => {
                try {
                    const state: BrowserState = request.result === undefined ? empty() : request.result;
                    if (state.version !== 1) throw new StorageError();
                    const changed = change(state, tx.objectStore('views')); result = changed.value;
                    if (changed.save) {
                        if (!write) throw new StorageError();
                        store.put(state, 'current');
                    }
                } catch { tx.abort(); }
            };
        });
    }
    read(): Promise<BrowserState> { return this.transaction(false, state => ({ value: state })); }

    /** §10.3: fetch only the requested cache, and only while it matches the current index and pairing epoch. */
    readView(binderId: string): Promise<StoredView | undefined> {
        return new Promise((resolve, reject) => {
            let tx: IDBTransaction;
            try { tx = this.db.transaction(['state', 'views'], 'readonly'); }
            catch { reject(new StorageError()); return; }
            const state = tx.objectStore('state').get('current'), view = tx.objectStore('views').get(binderId);
            tx.onabort = () => reject(new StorageError()); tx.onerror = () => reject(new StorageError());
            tx.oncomplete = () => {
                const s = state.result as BrowserState | undefined, v = view.result as StoredView | undefined;
                const p = s?.pairing, i = s?.index, b = i?.binders.find(b => b.id === binderId);
                resolve(p && i && b && v && i.epoch === p.epoch && v.epoch === i.epoch &&
                    v.version === b.viewVersion && v.version >= (s!.viewMarks[binderId] ?? 0) ? v : undefined);
            };
        });
    }

    /** §5.2 step 2: a fresh reservation cancels earlier flows, but cannot replace an installed pairing. */
    async reserve(pairingId: string): Promise<Reservation | null> {
        if (!isId(pairingId)) throw new StorageError();
        const reservation = { generation: encodeB64(crypto.getRandomValues(new Uint8Array(16))), pairingId };
        return this.transaction(true, state => {
            if (state.pairing) return { value: null };
            state.reservation = reservation;
            return { value: reservation, save: true };
        });
    }

    async cancelReservation(generation: string): Promise<boolean> {
        return this.transaction(true, state => {
            if (state.pairing || state.reservation?.generation !== generation) return { value: false };
            delete state.reservation; return { value: true, save: true };
        });
    }

    /** §5.2 step 5: decrypt first, install only from the still-current reservation, then permit acknowledgement. */
    async install(reservation: Reservation, installation: Installation): Promise<boolean> {
        reservation = { ...reservation };
        installation = { ...installation, delivery: installation.delivery.slice() };
        try {
            if (!isId(reservation.generation) || !isId(reservation.pairingId) ||
                !isId(installation.deviceId) || !/^[0-9a-f]{32}$/.test(installation.instanceId) || !isRelayOrigin(installation.relayOrigin) ||
                decodeB64(installation.token)?.length !== 32 || !isTime(installation.expiresAt) ||
                !deviceKey(installation.deviceKey)) throw new StorageError();
        } catch { throw new StorageError(); }
        const delivery = await openPairingDelivery(reservation.pairingId, installation.deviceId,
            installation.wrapKey, installation.delivery.slice());
        return this.transaction(true, (state, views) => {
            if (state.pairing || state.reservation?.generation !== reservation.generation ||
                state.reservation.pairingId !== reservation.pairingId) return { value: false };
            state.pairing = { generation: reservation.generation, pairingId: reservation.pairingId,
                deviceId: installation.deviceId, relayOrigin: installation.relayOrigin,
                instanceId: installation.instanceId, token: installation.token, expiresAt: installation.expiresAt,
                acknowledgementPending: true, ...delivery, deviceKey: installation.deviceKey,
                nextSeq: 1, outcomesRevision: 0 };
            delete state.reservation; delete state.index; views.clear(); state.viewMarks = {};
            return { value: true, save: true };
        });
    }

    async acknowledged(generation: string, pairingId: string): Promise<boolean> {
        return this.transaction(true, state => {
            const p = state.pairing;
            if (!p || p.generation !== generation || p.pairingId !== pairingId) return { value: false };
            p.acknowledgementPending = false;
            return { value: true, save: true };
        });
    }

    /** §10.2: validate outside IDB, then atomically recheck prerequisites; at most three restarts. */
    async acceptIndex(revision: number, epoch: number, input: Uint8Array): Promise<boolean> {
        const bytes = input.slice();
        for (let retry = 0; retry <= 3; retry++) {
            const before = await this.read(), p = before.pairing;
            if (!p || !positive(revision) || epoch !== p.epoch || revision < p.minIndexRevision ||
                revision < (before.index?.revision ?? 0)) return false;
            const index = await openIndex(revision, epoch, p.accountKey, p.ownerKey, bytes);
            const committed = await this.transaction(true, (state, views) => {
                const current = state.pairing;
                if (!current || current.generation !== p.generation || current.deviceId !== p.deviceId ||
                    current.epoch !== p.epoch || revision < current.minIndexRevision ||
                    revision < (state.index?.revision ?? 0)) return { value: false };
                const previousIds = state.index?.binders.map(b => b.id) ?? [];
                state.index = { revision, epoch, bytes,
                    binders: index.binders.map(({ id, viewVersion, key }) => ({ id, viewVersion, key })) };
                const ids = new Set(index.binders.map(b => b.id));
                for (const id of previousIds) if (!ids.has(id)) views.delete(id);
                return { value: true, save: true };
            });
            if (committed) return true;
        }
        return false;
    }

    async acceptView(binderId: string, version: number, input: Uint8Array): Promise<boolean> {
        const bytes = input.slice();
        for (let retry = 0; retry <= 3; retry++) {
            const before = await this.read(), p = before.pairing, index = before.index;
            const binder = index?.binders.find(b => b.id === binderId);
            if (!p || !index || index.epoch !== p.epoch || !binder || binder.viewVersion !== version ||
                version < (before.viewMarks[binderId] ?? 0)) return false;
            await openView(binderId, version, index.epoch, binder.key, p.ownerKey, bytes);
            const committed = await this.transaction(true, (state, views) => {
                const current = state.pairing, i = state.index, b = i?.binders.find(b => b.id === binderId);
                if (!current || current.generation !== p.generation || current.deviceId !== p.deviceId ||
                    current.epoch !== p.epoch || i?.revision !== index.revision || i.epoch !== index.epoch ||
                    !b || b.viewVersion !== version || version < (state.viewMarks[binderId] ?? 0)) return { value: false };
                views.put({ version, epoch: index.epoch, bytes } satisfies StoredView, binderId);
                state.viewMarks[binderId] = version;
                return { value: true, save: true };
            });
            if (committed) return true;
        }
        return false;
    }

    async acceptKeys(epoch: number, input: Uint8Array): Promise<boolean> {
        const bytes = input.slice();
        for (let retry = 0; retry <= 3; retry++) {
            const before = await this.read(), p = before.pairing;
            if (!p || !positive(epoch) || epoch <= p.epoch) return false;
            const keys = await openDeviceKeys(p.deviceId, epoch, p.deviceKey, p.ownerKey, bytes);
            const committed = await this.transaction(true, state => {
                const current = state.pairing;
                if (!current || current.generation !== p.generation || current.deviceId !== p.deviceId ||
                    current.epoch !== p.epoch || epoch <= current.epoch) return { value: false };
                current.accountKey = keys.accountKey; current.epoch = keys.epoch;
                return { value: true, save: true };
            });
            if (committed) return true;
        }
        return false;
    }
}
