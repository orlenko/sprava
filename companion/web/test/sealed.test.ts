import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { createCipheriv, createPrivateKey, createPublicKey, sign } from 'node:crypto';
import { encodeB64, joinBytes, utf8 } from '../src/encoding.ts';
import { importKey, openObject, sealObject, SealedError } from '../src/sealed.ts';
import { unsignedValue, writeJson } from '../../shared/json.ts';

// Invented, public test keys. The owner fixture uses Node's separate crypto API,
// so an incorrect WebCrypto implementation cannot pass just by round-tripping itself.
const raw = Uint8Array.from({ length: 32 }, (_, i) => i);
const nonce = Uint8Array.from({ length: 12 }, (_, i) => i);
const id = 'AAAAAAAAAAAAAAAAAAAAAA';
const signing = createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), Buffer.from(raw)]),
    format: 'der', type: 'pkcs8' });
const publicBytes = createPublicKey(signing).export({ format: 'der', type: 'spki' }).subarray(-32);
const owner = () => crypto.subtle.importKey('raw', new Uint8Array(publicBytes), 'Ed25519', false, ['verify']);
const vectors = JSON.parse(readFileSync(new URL('../../testdata/companion-v0-vectors.json', import.meta.url), 'utf8'));

function envelope(name: string, kid: string, epoch: number, plaintext: Uint8Array, signed = true): Record<string, unknown> {
    const cipher = createCipheriv('aes-256-gcm', raw, nonce);
    cipher.setAAD(utf8(`sprava-companion/v0|${name}|${kid}|${epoch}`));
    const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final(), cipher.getAuthTag()]);
    const e: Record<string, unknown> = { v: 0, kid, e: epoch, n: encodeB64(nonce), c: encodeB64(ciphertext) };
    if (signed) e.s = encodeB64(sign(null,
        joinBytes(utf8(`sprava-companion/v0 signed|${name}|${kid}|${epoch}|`), nonce, ciphertext), signing));
    return e;
}

test('signed index fixture has the exact committed cipher and is opened after owner authentication (§14 cases 2–3)', async () => {
    const v = vectors['seal-index'];
    assert.equal(Buffer.from(utf8(`sprava-companion/v0|index/1|account|1`)).toString('hex'), v.aad_hex);
    assert.equal(JSON.stringify(envelope('index/1', 'account', 1, utf8(v.plaintext))), v.envelope);
    const value = await openObject('index/1', 1, await importKey(raw), utf8(v.envelope), await owner());
    assert.equal(unsignedValue(value.revision), 1);
    assert.deepEqual(value.binders, []);
});

test('the owner signature binds every object kind to its name, key id and epoch (§§4.2, 4.5)', async () => {
    const key = await importKey(raw), publicKey = await owner();
    for (const [name, kid, epoch] of [
        ['index/1', 'account', 1], [`views/${id}/7`, id, 3],
        [`devices/${id}/keys/3`, 'device', 3], [`devices/${id}/outcomes/7`, 'device', 0],
    ] as const) {
        const e = envelope(name, kid, epoch, utf8('{"verified":true}'));
        assert.equal((await openObject(name, epoch, key, writeJson(e), publicKey)).verified, true);
        await assert.rejects(openObject(name + '1', epoch, key, writeJson(e), publicKey), SealedError);
        await assert.rejects(openObject(name, epoch + 1, key, writeJson(e), publicKey), SealedError);
        await assert.rejects(openObject(name, epoch, key, writeJson({ ...e, kid: 'wrap' }), publicKey), SealedError);
    }
});

test('absent, malformed, modified and foreign-owner signatures never reach decryption', async t => {
    const key = await importKey(raw), publicKey = await owner();
    const e = envelope('index/1', 'account', 1, utf8('{}'));
    let decrypts = 0;
    t.mock.method(crypto.subtle, 'decrypt', () => { decrypts++; throw new Error('must not decrypt'); });
    for (const altered of [
        { ...e, s: undefined }, { ...e, s: 'AA' }, { ...e, s: encodeB64(new Uint8Array(64)) },
        { ...e, n: encodeB64(new Uint8Array(12).fill(9)) }, { ...e, c: encodeB64(new Uint8Array(16)) },
    ]) await assert.rejects(openObject('index/1', 1, key, writeJson(altered), publicKey), SealedError);
    const foreign = await crypto.subtle.generateKey('Ed25519', false, ['sign', 'verify']) as CryptoKeyPair;
    await assert.rejects(openObject('index/1', 1, key, writeJson(e), foreign.publicKey), SealedError);
    await assert.rejects(openObject('index/1', 1, key, writeJson(e)), SealedError);
    assert.equal(decrypts, 0);
});

test('duplicate fields, noncanonical encodings, wrong versions and nonce lengths are refused before decrypt', async t => {
    const key = await importKey(raw), publicKey = await owner();
    const e = envelope('index/1', 'account', 1, utf8('{}'));
    let decrypts = 0;
    t.mock.method(crypto.subtle, 'decrypt', () => { decrypts++; throw new Error('must not decrypt'); });
    const repeated = JSON.stringify(e).replace('{', '{"v":0,');
    const cases = [utf8(repeated), utf8(JSON.stringify(e).replace('"e":1', '"e":1.0')),
        writeJson({ ...e, v: 1 }), writeJson({ ...e, e: -1 }), writeJson({ ...e, n: 'AA' }),
        writeJson({ ...e, c: e.c + '=' }), new Uint8Array(1048577)];
    for (const bytes of cases) await assert.rejects(openObject('index/1', 1, key, bytes, publicKey), SealedError);
    assert.equal(decrypts, 0);
});

test('valid owner authentication cannot make a malformed plaintext acceptable', async () => {
    const key = await importKey(raw), publicKey = await owner();
    for (const plaintext of ['{"a":1,"a":2}', '{"a":"\\ud800"}', '[]', '{']) {
        const e = envelope('index/1', 'account', 1, utf8(plaintext));
        await assert.rejects(openObject('index/1', 1, key, writeJson(e), publicKey), SealedError);
    }
});

test('device seals use fresh nonces, non-extractable keys, ordered envelope fields and authenticated object names', async () => {
    const key = await importKey(raw), name = `requests/${id}/${id}`;
    assert.equal(key.extractable, false);
    await assert.rejects(crypto.subtle.exportKey('raw', key));
    const a = await sealObject(name, 3, key, utf8('{"text":"Invented note"}'));
    const b = await sealObject(name, 3, key, utf8('{"text":"Invented note"}'));
    assert.notEqual(JSON.parse(new TextDecoder().decode(a)).n, JSON.parse(new TextDecoder().decode(b)).n);
    assert.deepEqual(Object.keys(JSON.parse(new TextDecoder().decode(a))), ['v', 'kid', 'e', 'n', 'c']);
    assert.equal((await openObject(name, 3, key, a)).text, 'Invented note');
    const tampered = JSON.parse(new TextDecoder().decode(a));
    const c = Buffer.from(tampered.c, 'base64url'); c[c.length - 1]! ^= 1;
    tampered.c = c.toString('base64url');
    await assert.rejects(openObject(name, 3, key, writeJson(tampered)), SealedError);
    await assert.rejects(openObject(name, 3, key, writeJson({ ...JSON.parse(new TextDecoder().decode(a)), s: null })), SealedError);
    await assert.rejects(sealObject('index/1', 1, key, utf8('{}')), SealedError, 'device cannot publish as owner');
});

test('pairing hello/key and revocation use their own epoch rules; unknown names are refused', async () => {
    const key = await importKey(raw);
    for (const [name, epoch] of [[`pairings/${id}/hello`, 0], [`pairings/${id}/key`, 1], [`devices/${id}/revocation`, 0]] as const) {
        const bytes = await sealObject(name, epoch, key, utf8('{}'));
        assert.deepEqual(await openObject(name, epoch, key, bytes), Object.create(null));
    }
    for (const [name, epoch] of [['index/0', 1], [`views/${id}/0`, 1], [`devices/${id}/keys/1`, 2],
        [`devices/${id}/outcomes/1`, 1], [`pairings/${id}/hello`, 1], [`pairings/${id}/key`, 0],
        [`requests/${id}/${id}`, 0], ['other/1', 1], ['index/01', 1]] as const)
        await assert.rejects(openObject(name, epoch, key, utf8('{}')), SealedError);
});

test('opening an envelope is independent of JSON member order (§4.5)', async () => {
    const e = envelope('index/1', 'account', 1, utf8('{}'));
    const reordered = Object.fromEntries(Object.entries(e).reverse());
    assert.deepEqual(await openObject('index/1', 1, await importKey(raw), writeJson(reordered), await owner()), Object.create(null));
});
