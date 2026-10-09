import assert from 'node:assert/strict';
import { test } from 'node:test';
import { decodeB64, encodeB64, formatTime, isHashHex, isId, isToken, newId, newToken, parseUnsigned, sameSecret, tokenHash } from '../src/encoding.ts';
import { vectors } from './vectors.ts';

test('b64 vectors (§14 case 1): valid encodings round-trip', () => {
    for (const { hex, b64 } of vectors.b64.valid) {
        assert.equal(encodeB64(Buffer.from(hex, 'hex')), b64);
        assert.equal(Buffer.from(decodeB64(b64)!).toString('hex'), hex);
    }
});

test('b64 vectors (§14 case 1): padding, foreign characters and non-zero trailing bits are refused', () => {
    for (const { b64 } of vectors.b64.invalid) assert.equal(decodeB64(b64), null, b64);
});

test('token-hash vector (§14 case 9): SHA-256 over the 43 ASCII characters, in lowercase hex', () => {
    const v = vectors['token-hash'];
    assert.equal(tokenHash(v.token), v.sha256);
    assert.notEqual(tokenHash(v.token), v.wrong_reading);
    assert.ok(isHashHex(v.sha256));
    assert.ok(!isHashHex(v.refused_owner_token_sha256));
    assert.ok(isToken(v.token));
    assert.ok(!isToken(v.refused_bearer));
});

test('ids and tokens have exactly their sizes', () => {
    assert.ok(isId(newId()));
    assert.ok(isToken(newToken()));
    assert.ok(!isId('AAAAAAAAAAAAAAAAAAAAAB'), 'non-zero trailing bits');
    assert.ok(!isId('AAAAAAAAAAAAAAAAAAAAA'));
    assert.ok(!isId(7));
    assert.ok(!isToken(newId()));
});

test('secrets compare equal only when identical', () => {
    assert.ok(sameSecret('abc', 'abc'));
    assert.ok(!sameSecret('abc', 'abd'));
    assert.ok(!sameSecret('abc', 'abcd'));
});

test('times are written to the second, in UTC', () => {
    assert.equal(formatTime(Date.UTC(2026, 9, 8, 7, 6, 5, 999)), '2026-10-08T07:06:05Z');
});

test('unsigned integers in names and queries follow §3', () => {
    assert.equal(parseUnsigned('0'), 0);
    assert.equal(parseUnsigned('42'), 42);
    assert.equal(parseUnsigned('9007199254740991'), 2 ** 53 - 1);
    for (const bad of ['', '01', '-1', '1.0', '1e2', '+1', '9007199254740992', ' 1']) assert.equal(parseUnsigned(bad), null, bad);
});
