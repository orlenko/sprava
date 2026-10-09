// The names of what the relay keeps under `SPRAVA_INSTANCE/`, and the records it writes (companion-v0 §7.8).

export const OWNER = 'owner.json';

export const deviceKeys = (d: string) => ({
    record: `devices/${d}/record.json`,
    active: `devices/${d}/active`,
    revoked: `devices/${d}/revoked`,
    revocation: `devices/${d}/revocation`,
    lastSeen: `devices/${d}/last_seen`,
});

export const pairingKeys = (p: string) => ({
    created: `pairings/${p}/created.json`,
    joined: `pairings/${p}/joined.json`,
    keySha: `pairings/${p}/key.sha256`,
    key: `pairings/${p}/key`,
    ack: `pairings/${p}/ack`,
});

/** Everything of a device outside `devices/{D}/`: its pending requests, keys and outcomes objects. */
export const deviceElsewhere = (d: string) => [`requests/${d}/`, `objects/devices/${d}/keys/`, `objects/devices/${d}/outcomes/`];

/** `devices/{D}/record.json`, written once at join. */
export interface DeviceRecord {
    token_sha256: string;
    pairing_id: string;
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

/** Reads one of the relay's own JSON records; null when it is missing or unreadable. */
export function readRecord<T>(bytes: Uint8Array | null): T | null {
    if (bytes === null) return null;
    try {
        const value: unknown = JSON.parse(Buffer.from(bytes).toString('utf8'));
        return typeof value === 'object' && value !== null ? (value as T) : null;
    } catch {
        return null;
    }
}

export const EMPTY = new Uint8Array();
