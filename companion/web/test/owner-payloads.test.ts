import assert from 'node:assert/strict';
import { test } from 'node:test';
import { encodeB64 } from '../src/encoding.ts';
import { openDeviceKeys, openIndex, openPairingDelivery } from '../src/owner-payloads.ts';
import { isDate, isTime, PayloadError } from '../src/payload.ts';
import { sealObject, openObject } from '../src/sealed.ts';
import { id, key, otherId, owner, publicBytes, raw, sealed } from './owner-fixture.ts';

const delivery = () => ({ account_key: encodeB64(raw), epoch: 1, device_id: id, min_index_revision: 7,
    owner_signing_key: encodeB64(publicBytes) });
const binder = () => ({ id, name: 'Invented binder', view_version: 3, key: encodeB64(raw) });
const index = () => ({ revision: 7, generated_at: '2026-10-08T07:06:05Z', binders: [binder()] });

test('pairing delivery authenticates the wrap, checks the recipient, and imports secret/pinned owner keys (§8.2)', async () => {
    const result = await openPairingDelivery(id, id, await key(), sealed(`pairings/${id}/key`, 'wrap', 1, delivery(), false));
    assert.deepEqual(Object.keys(result).sort(), ['accountKey', 'epoch', 'minIndexRevision', 'ownerKey']);
    assert.equal(result.epoch, 1); assert.equal(result.minIndexRevision, 7);
    assert.equal(result.accountKey.extractable, false);
    await assert.rejects(crypto.subtle.exportKey('raw', result.accountKey));
    const message = await sealObject(`requests/${id}/${id}`, 1, result.accountKey, new TextEncoder().encode('{}'));
    assert.deepEqual(await openObject(`requests/${id}/${id}`, 1, await key(), message), Object.create(null));
    const empty = sealed('index/7', 'account', 1, { ...index(), binders: [] });
    assert.equal((await openIndex(7, 1, result.accountKey, result.ownerKey, empty)).revision, 7);
});

test('pairing delivery refuses malformed keys, wrong recipients, mismatched epochs and non-integer floors', async () => {
    const wrap = await key();
    for (const changes of [
        { account_key: 'AA' }, { account_key: encodeB64(raw) + '=' }, { owner_signing_key: 'AA' },
        { epoch: 0 }, { epoch: 2 }, { device_id: otherId }, { min_index_revision: -1 },
        { min_index_revision: 9007199254740992 }, { min_index_revision: undefined },
    ]) await assert.rejects(openPairingDelivery(id, id, wrap,
        sealed(`pairings/${id}/key`, 'wrap', 1, { ...delivery(), ...changes }, false)), PayloadError);
    const wrong = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
    await assert.rejects(openPairingDelivery(id, id, wrong,
        sealed(`pairings/${id}/key`, 'wrap', 1, delivery(), false)), PayloadError);
    const fractional = JSON.stringify(delivery()).replace('"min_index_revision":7', '"min_index_revision":7.0');
    await assert.rejects(openPairingDelivery(id, id, wrap,
        sealed(`pairings/${id}/key`, 'wrap', 1, null, false, fractional)), PayloadError);
});

test('authenticated device-key rotation checks the device and epoch and cannot change the owner pin (§8.3)', async () => {
    const deviceKey = await key(), ownerKey = await owner();
    const value = { account_key: encodeB64(raw), epoch: 2, device_id: id };
    const result = await openDeviceKeys(id, 2, deviceKey, ownerKey,
        sealed(`devices/${id}/keys/2`, 'device', 2, { ...value, x: true }));
    assert.deepEqual(Object.keys(result).sort(), ['accountKey', 'epoch']);
    assert.equal(result.accountKey.extractable, false);
    for (const changes of [{ epoch: 1 }, { epoch: 3 }, { device_id: otherId }, { account_key: 'AA' }])
        await assert.rejects(openDeviceKeys(id, 2, deviceKey, ownerKey,
            sealed(`devices/${id}/keys/2`, 'device', 2, { ...value, ...changes })), PayloadError);
    await assert.rejects(openDeviceKeys(id, 2, deviceKey, ownerKey,
        sealed(`devices/${id}/keys/2`, 'device', 2, value, false)), PayloadError);
});

test('index validates names, revision and metadata before importing non-extractable binder keys (§8.4)', async () => {
    const result = await openIndex(7, 1, await key(), await owner(),
        sealed('index/7', 'account', 1, { ...index(), ignored: 'not returned' }));
    assert.deepEqual(Object.keys(result).sort(), ['binders', 'epoch', 'generatedAt', 'revision']);
    assert.deepEqual(Object.keys(result.binders[0]!).sort(), ['id', 'key', 'name', 'viewVersion']);
    assert.equal(result.binders[0]!.name, 'Invented binder');
    assert.equal(result.binders[0]!.viewVersion, 3);
    assert.equal(result.binders[0]!.key.extractable, false);
    await assert.rejects(crypto.subtle.exportKey('raw', result.binders[0]!.key));
    assert.equal(result.generatedAt, '2026-10-08T07:06:05Z');
});

test('invalid index entries invalidate the whole snapshot without importing any binder key', async t => {
    const accountKey = await key(), ownerKey = await owner();
    const importOriginal = crypto.subtle.importKey.bind(crypto.subtle);
    let imports = 0;
    t.mock.method(crypto.subtle, 'importKey', (...args: any[]) => { imports++; return (importOriginal as any)(...args); });
    const badBinders = [
        [binder(), binder()], [{ ...binder(), id: 'bad' }], [{ ...binder(), name: '' }],
        [{ ...binder(), name: 'x'.repeat(201) }], [{ ...binder(), name: '\u0001'.repeat(134) }],
        [{ ...binder(), key: 'AA' }], [{ ...binder(), view_version: 0 }], [{ ...binder(), view_version: 1.5 }],
        [binder(), { ...binder(), id: otherId, key: 'AA' }], Array(101).fill(binder()), [null],
    ];
    for (const binders of badBinders)
        await assert.rejects(openIndex(7, 1, accountKey, ownerKey, sealed('index/7', 'account', 1, { ...index(), binders })), PayloadError);
    assert.equal(imports, 0);
    for (const changes of [{ revision: 8 }, { generated_at: '2026-02-30T07:06:05Z' }, { binders: null }])
        await assert.rejects(openIndex(7, 1, accountKey, ownerKey, sealed('index/7', 'account', 1, { ...index(), ...changes })), PayloadError);
});

test('index scalar/byte and binder-count boundaries are inclusive', async () => {
    const accountKey = await key(), ownerKey = await owner();
    const emoji = { ...binder(), name: '😀'.repeat(200) };
    assert.equal((await openIndex(7, 1, accountKey, ownerKey,
        sealed('index/7', 'account', 1, { ...index(), binders: [emoji] }))).binders[0]!.name, emoji.name);
    const binders = Array.from({ length: 100 }, (_, i) => ({ ...binder(), id: encodeB64(new Uint8Array(16).fill(i)) }));
    assert.equal((await openIndex(7, 1, accountKey, ownerKey,
        sealed('index/7', 'account', 1, { ...index(), binders }))).binders.length, 100);
});

test('calendar and UTC timestamp validation preserves the Mac calendar and refuses normalization', () => {
    for (const value of ['0001-01-01', '1582-10-10', '2000-02-29', '9999-12-31']) assert.equal(isDate(value), true, value);
    for (const value of ['0000-01-01', '1900-02-29', '2026-02-30', '2026-01-00', '2026-13-01', '2026-W27-1'])
        assert.equal(isDate(value), false, value);
    for (const value of ['2026-10-08T07:06:05Z', '0001-01-01T00:00:00Z', '1990-12-31T23:59:60Z'])
        assert.equal(isTime(value), true, value);
    for (const value of ['2026-10-08T24:00:00Z', '2026-10-08T07:60:00Z', '2026-10-08T07:06:60Z',
        '2026-10-08T07:06:05.0Z', '2026-10-08T07:06:05+00:00', '2026-10-08t07:06:05z'])
        assert.equal(isTime(value), false, value);
});
