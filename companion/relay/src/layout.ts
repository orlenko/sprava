// The names of what the relay keeps under `SPRAVA_INSTANCE/`, and the records it writes (companion-v0 §7.8).

/**
 * Claims (§6): `claims/{digest}`, empty, a claim's intent; `owner/{digest}`, its owner record. Both are named by the
 * SHA-256 of the owner record's bytes, so a late write of either repeats the same name and bytes. The binding claim
 * is the lowest-named claim intent; the owner is its record, when that exists; only its retry may write it, or be
 * acknowledged (claim.ts).
 */
export const CLAIMS = 'claims/';
export const OWNERS = 'owner/';
export const ownerRecord = (hash: string): Uint8Array => new Uint8Array(Buffer.from(`{"owner_token_sha256":"${hash}"}`, 'utf8'));

export const deviceKeys = (d: string) => ({
    record: `devices/${d}/record.json`,
    active: `devices/${d}/active`,
    revoked: `devices/${d}/revoked`,
    revocation: `devices/${d}/revocation`,
    lastSeen: `devices/${d}/last_seen`,
    /** `devices/{D}/tokens/{sha256}`: one per token the relay made at a join, named by the token's hash. */
    tokens: `devices/${d}/tokens/`,
    token: (hash: string) => `devices/${d}/tokens/${hash}`,
});

export const pairingKeys = (p: string) => ({
    created: `pairings/${p}/created.json`,
    joined: `pairings/${p}/joined.json`,
    keySha: `pairings/${p}/key.sha256`,
    key: `pairings/${p}/key`,
    ack: `pairings/${p}/ack`,
    /** The pairing's tombstone: written before any part is deleted, never deleted itself. */
    deleted: `pairings/${p}/deleted`,
});

/** Everything of a device outside `devices/{D}/`: its pending requests, keys and outcomes objects. */
export const deviceElsewhere = (d: string) => [
    `requests/${d}/`,
    `objects/devices/${d}/`,
    `tombstones/requests/${d}/`,
    `tombstones/objects/devices/${d}/`,
    `floors/requests/${d}/`,
    `floors/objects/devices/${d}/`,
    `ordinals/${d}/`,
];

/**
 * `devices/{D}/record.json`, written once at join. It holds only what every join of the pairing derives alike, so
 * a late write from an earlier attempt repeats the same bytes; the token's hash is in the name of its own marker
 * (`tokens/{sha256}`, holding when it was made), so a late attempt adds a token nobody holds and replaces nothing.
 */
export interface DeviceRecord {
    pairing_id: string;
}

export interface TokenRecord {
    joined_at: string;
}

/** `pairings/{P}/created.json`, written once when the owner makes the pairing. */
export interface PairingCreated {
    owner_public_key: string;
    device_id: string;
    secret_sha256: string;
    expires_at: string;
}

/** Groups the keys under `devices/` or `pairings/` by id: id → the names of its parts. */
export function groupParts(keys: string[], top: 'devices' | 'pairings'): Map<string, Set<string>> {
    const groups = new Map<string, Set<string>>();
    for (const key of keys) {
        const [first, id, part] = key.split('/');
        if (first !== top || id === undefined || part === undefined) continue;
        if (!groups.has(id)) groups.set(id, new Set());
        groups.get(id)!.add(part);
    }
    return groups;
}

export class UnreadableRecord extends Error {}

/**
 * Reads one of the relay's own JSON records: null only when it is missing. An unreadable record is an error, never
 * taken for an absent one, so nothing is decided or deleted because a read went wrong.
 */
export function readRecord<T>(bytes: Uint8Array | null): T | null {
    if (bytes === null) return null;
    let value: unknown;
    try {
        value = JSON.parse(Buffer.from(bytes).toString('utf8'));
    } catch {
        throw new UnreadableRecord('a record of the relay is unreadable');
    }
    if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new UnreadableRecord('a record of the relay is unreadable');
    return value as T;
}

export const EMPTY = new Uint8Array();
