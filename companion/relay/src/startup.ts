// At start, before serving: repair and clean up what a crash may have left (companion-v0 §7.8), in the spec's
// order. No step ever deletes a revocation marker, and an unreadable record stops the start rather than being
// taken for a missing one (layout.ts, readRecord).
import type { Devices } from './devices.ts';
import { deviceKeys, EMPTY, groupParts, pairingKeys, readRecord, type DeviceRecord, type PairingCreated } from './layout.ts';
import type { Relay } from './relay.ts';
import { deleteAll, writeOnce } from './store/store.ts';

export async function repairAtStart(relay: Relay, devices: Devices): Promise<void> {
    const { store } = relay;
    const now = relay.now();
    let deviceParts = groupParts(await store.list('devices/'), 'devices');
    const pairingParts = groupParts(await store.list('pairings/'), 'pairings');
    // 0. A deleted pairing keeps only its tombstone; it counts as missing for every rule below.
    for (const [p, parts] of pairingParts) {
        if (!parts.has('deleted')) continue;
        for (const part of parts) if (part !== 'deleted') await store.delete(`pairings/${p}/${part}`);
        pairingParts.delete(p);
    }
    const created = new Map<string, PairingCreated>();
    for (const [p, parts] of pairingParts) {
        const record = parts.has('created.json') ? readRecord<PairingCreated>(await store.get(pairingKeys(p).created)) : null;
        if (record !== null) created.set(p, record);
    }
    const has = (d: string, part: string): boolean => deviceParts.get(d)?.has(part) ?? false;
    const expired = (p: string): boolean => {
        const record = created.get(p);
        return record === undefined || !(Date.parse(record.expires_at) > now);
    };

    // 1. A stored self-revocation without its marker gets the marker.
    for (const d of deviceParts.keys()) {
        if (has(d, 'revocation') && !has(d, 'revoked')) await devices.markRevoked(d);
    }
    deviceParts = groupParts(await store.list('devices/'), 'devices');

    // 2. The device of a pairing that was keyed or acknowledged is active, unless it is revoked.
    for (const [p, parts] of pairingParts) {
        const d = created.get(p)?.device_id;
        if (d !== undefined && (parts.has('key.sha256') || parts.has('ack')) && !has(d, 'revoked') && !has(d, 'active')) {
            await relay.lock.run(() => writeOnce(store, deviceKeys(d).active, EMPTY));
            deviceParts.get(d)?.add('active');
        }
    }

    // 3. Pairings past their expiry go, with their device's record if that device is still pending.
    for (const [p, parts] of pairingParts) {
        const record = created.get(p);
        if (record === undefined || !expired(p)) continue;
        const d = record.device_id;
        if (!has(d, 'active') && !has(d, 'revoked')) {
            // Revoked first, as a deletion with its pairing does, so no late write can bring it back.
            await devices.markRevoked(d);
            await devices.deleteParts(d);
        }
        for (const part of parts) await store.delete(`pairings/${p}/${part}`);
        pairingParts.delete(p);
    }

    // 4. Parts whose pairing has no created.json, or whose device has no record.json, revocation markers excepted.
    for (const [p, parts] of pairingParts) {
        if (created.has(p)) continue;
        for (const part of parts) await store.delete(`pairings/${p}/${part}`);
        pairingParts.delete(p);
    }
    deviceParts = groupParts(await store.list('devices/'), 'devices');
    for (const [d, parts] of deviceParts) {
        if (parts.has('record.json')) continue;
        for (const key of await store.list(`devices/${d}/`)) if (key !== deviceKeys(d).revoked) await store.delete(key);
    }

    // 5. Pending devices whose pairing is missing or expired lose their record.
    deviceParts = groupParts(await store.list('devices/'), 'devices');
    for (const [d, parts] of deviceParts) {
        if (!parts.has('record.json') || parts.has('active') || parts.has('revoked')) continue;
        const record = readRecord<DeviceRecord>(await store.get(deviceKeys(d).record));
        if (record === null || !pairingParts.has(record.pairing_id) || expired(record.pairing_id)) {
            await devices.markRevoked(d);
            await devices.deleteParts(d);
        }
    }

    // 6. A marker without a stored revocation is an owner deletion a crash cut short: finish it.
    deviceParts = groupParts(await store.list('devices/'), 'devices');
    for (const [d, parts] of deviceParts) {
        if (parts.has('revoked') && !parts.has('revocation')) await devices.deleteParts(d);
        // A self-revocation that stopped before its pending requests were deleted is finished; its record and
        // proof stay for the owner.
        else if (parts.has('revoked') && parts.has('revocation')) await deleteAll(store, `requests/${d}/`);
    }
}
