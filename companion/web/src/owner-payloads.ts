// Authentication and schema validation of owner key/index payloads (companion-v0 §§8.2–8.4).
// Results are provisional: callers must durably commit state and high-water marks (§10.2) before use.
import { parseStrict } from '../../shared/json.ts';
import { isId } from './encoding.ts';
import { importKey, openObject } from './sealed.ts';
import { integer, isTime, keyBytes, object, PayloadError, text } from './payload.ts';

export interface PairingDelivery {
    accountKey: CryptoKey;
    ownerKey: CryptoKey;
    epoch: number;
    minIndexRevision: number;
}

export interface BinderIndexEntry {
    id: string;
    name: string;
    viewVersion: number;
    key: CryptoKey;
}

export interface BinderIndex {
    revision: number;
    epoch: number;
    generatedAt: string;
    binders: BinderIndexEntry[];
}

function positive(n: number): void {
    if (!Number.isSafeInteger(n) || n < 1) throw new PayloadError();
}

async function secret(bytes: Uint8Array): Promise<CryptoKey> {
    try { return await importKey(bytes); }
    finally { bytes.fill(0); }
}

/** §8.2: use the envelope epoch only to authenticate the wrapped delivery, then check its payload matches. */
export async function openPairingDelivery(pairingId: string, deviceId: string, wrap: CryptoKey,
    bytes: Uint8Array): Promise<PairingDelivery> {
    try {
        if (!isId(pairingId) || !isId(deviceId)) throw new PayloadError();
        const epoch = integer(object(parseStrict(bytes, 1024)).e, 1);
        const value = await openObject(`pairings/${pairingId}/key`, epoch, wrap, bytes);
        if (integer(value.epoch, 1) !== epoch || value.device_id !== deviceId) throw new PayloadError();
        const accountBytes = keyBytes(value.account_key), signingBytes = keyBytes(value.owner_signing_key);
        const minIndexRevision = integer(value.min_index_revision);
        const ownerKey = await crypto.subtle.importKey('raw', signingBytes, 'Ed25519', false, ['verify']);
        const accountKey = await secret(accountBytes);
        return { accountKey, ownerKey, epoch, minIndexRevision };
    } catch { throw new PayloadError(); }
}

/** §8.3: rotations change only the account key/epoch; they never replace the pinned owner signing key. */
export async function openDeviceKeys(deviceId: string, epoch: number, deviceKey: CryptoKey,
    ownerKey: CryptoKey, bytes: Uint8Array): Promise<{ accountKey: CryptoKey; epoch: number }> {
    try {
        if (!isId(deviceId)) throw new PayloadError();
        positive(epoch);
        const value = await openObject(`devices/${deviceId}/keys/${epoch}`, epoch, deviceKey, bytes, ownerKey);
        if (integer(value.epoch, 1) !== epoch || value.device_id !== deviceId) throw new PayloadError();
        return { accountKey: await secret(keyBytes(value.account_key)), epoch };
    } catch { throw new PayloadError(); }
}

/** §8.4: validate the complete authenticated index before importing any binder key. */
export async function openIndex(revision: number, epoch: number, accountKey: CryptoKey,
    ownerKey: CryptoKey, bytes: Uint8Array): Promise<BinderIndex> {
    const pending: Uint8Array[] = [];
    try {
        positive(revision); positive(epoch);
        const value = await openObject(`index/${revision}`, epoch, accountKey, bytes, ownerKey);
        if (integer(value.revision, 1) !== revision || !isTime(value.generated_at) ||
            !Array.isArray(value.binders) || value.binders.length > 100) throw new PayloadError();
        const ids = new Set<string>();
        const entries = value.binders.map(entry => {
            const b = object(entry);
            if (typeof b.id !== 'string' || !isId(b.id) || ids.has(b.id)) throw new PayloadError();
            ids.add(b.id);
            const name = text(b.name, 1, 200, 800), viewVersion = integer(b.view_version, 1);
            const key = keyBytes(b.key); pending.push(key);
            return { id: b.id, name, viewVersion, key };
        });
        const binders: BinderIndexEntry[] = [];
        for (const entry of entries)
            binders.push({ id: entry.id, name: entry.name, viewVersion: entry.viewVersion, key: await secret(entry.key) });
        return { revision, epoch, generatedAt: value.generated_at, binders };
    } catch { throw new PayloadError(); }
    finally { for (const bytes of pending) bytes.fill(0); }
}
