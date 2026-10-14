import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { decodeB64, utf8 } from '../src/encoding.ts';
import { importKey, openObject, sealObject } from '../src/sealed.ts';
import { confirmationCode, devicePairingKeys, newPairingKeyPair, PairingKeyError } from '../src/pairing-keys.ts';

const vectors = JSON.parse(readFileSync(new URL('../../testdata/companion-v0-vectors.json', import.meta.url), 'utf8'));
const v = vectors['pairing-derivation'];
async function fixture(): Promise<CryptoKeyPair> {
    const privateKey = await crypto.subtle.importKey('jwk', { kty: 'OKP', crv: 'X25519',
        d: Buffer.from(v.device_private_hex, 'hex').toString('base64url'), x: v.device_public_b64 }, 'X25519', false, ['deriveBits']);
    const publicKey = await crypto.subtle.importKey('raw', decodeB64(v.device_public_b64)!, 'X25519', true, []);
    return { privateKey, publicKey };
}

test('X25519 and HKDF reproduce the independent committed derivation vectors (§14 case 5)', async () => {
    const local = await fixture();
    for (const d of v.devices) {
        const keys = await devicePairingKeys(v.pairing_id, d.device_id, decodeB64(v.owner_public_b64)!, local);
        assert.equal(keys.code, d.confirmation);
        assert.equal(Buffer.from(keys.publicKey).toString('base64url'), v.device_public_b64);
        assert.equal(keys.wrap.extractable, false);
        assert.equal(keys.device.extractable, false);
        // WebCrypto keys cannot be exported: authenticate a device-sealed message with each expected raw key.
        const hello = `pairings/${v.pairing_id}/hello`;
        const wrapped = await sealObject(hello, 0, keys.wrap, utf8('{"label":"Invented device"}'));
        assert.equal((await openObject(hello, 0, await importKey(Buffer.from(d.wrap_hex, 'hex')), wrapped)).label, 'Invented device');
        const request = `requests/${d.device_id}/${d.device_id}`;
        const sealed = await sealObject(request, 1, keys.device, utf8('{"text":"Invented note"}'));
        assert.equal((await openObject(request, 1, await importKey(Buffer.from(d.device_hex, 'hex')), sealed)).text, 'Invented note');
        await assert.rejects(crypto.subtle.exportKey('raw', keys.wrap));
        await assert.rejects(crypto.subtle.exportKey('raw', keys.device));
    }
});

test('changing the transcript device id or pairing id changes both keys and the confirmation code', async () => {
    const local = await fixture(), a = decodeB64(v.owner_public_b64)!;
    const first = await devicePairingKeys(v.pairing_id, v.devices[0].device_id, a, local);
    const second = await devicePairingKeys(v.pairing_id, v.devices[1].device_id, a, local);
    const third = await devicePairingKeys(v.devices[0].device_id, v.devices[0].device_id, a, local);
    assert.notEqual(first.code, second.code);
    assert.notEqual(first.code, third.code);
    const name = `pairings/${v.pairing_id}/hello`;
    const sealed = await sealObject(name, 0, first.wrap, utf8('{}'));
    await assert.rejects(openObject(name, 0, second.wrap, sealed));
    await assert.rejects(openObject(name, 0, third.wrap, sealed));
});

test('low-order public keys and an all-zero provider result are refused (§14 case 6)', async t => {
    const local = await fixture(), d = v.devices[0].device_id;
    await assert.rejects(devicePairingKeys(v.pairing_id, d, new Uint8Array(32), local), PairingKeyError);
    t.mock.method(crypto.subtle, 'deriveBits', () => Promise.resolve(new ArrayBuffer(32)));
    await assert.rejects(devicePairingKeys(v.pairing_id, d, decodeB64(v.owner_public_b64)!, local), PairingKeyError);
});

test('confirmation-code vectors use unsigned big-endian arithmetic and keep leading zeros (§14 case 7)', () => {
    for (const { hex, code } of vectors['confirmation-code'].values)
        assert.equal(confirmationCode(Buffer.from(hex, 'hex')), code);
    assert.throws(() => confirmationCode(new Uint8Array(3)), PairingKeyError);
});

test('new device keypairs keep private keys non-extractable; malformed transcripts are refused', async () => {
    const local = await newPairingKeyPair();
    assert.equal(local.privateKey.extractable, false);
    await assert.rejects(crypto.subtle.exportKey('jwk', local.privateKey));
    const a = decodeB64(v.owner_public_b64)!, d = v.devices[0].device_id;
    for (const [p, id, publicBytes] of [[v.pairing_id + '=', d, a], [v.pairing_id, d + '=', a],
        [v.pairing_id, d, new Uint8Array(31)]]) {
        await assert.rejects(devicePairingKeys(p as string, id as string, publicBytes as Uint8Array, local), PairingKeyError);
    }
});
