import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { decodeB64, encodeB64 } from '../src/encoding.ts';
import { JsonError, parseStrict, writeJson } from '../../shared/json.ts';

const vectors = JSON.parse(readFileSync(new URL('../../testdata/companion-v0-vectors.json', import.meta.url), 'utf8'));
function bytes(entry: any): Uint8Array {
    if (entry.text !== undefined) return new TextEncoder().encode(entry.text);
    if (entry.hex !== undefined) return Buffer.from(entry.hex, 'hex');
    const f = entry.fill;
    return new TextEncoder().encode(f.before + f.repeat.repeat(f.length - f.before.length - f.after.length) + f.after);
}

test('browser encodings reproduce the committed base64url vectors (§14 case 1)', () => {
    for (const { hex, b64 } of vectors.b64.valid) {
        assert.equal(encodeB64(Buffer.from(hex, 'hex')), b64);
        assert.equal(Buffer.from(decodeB64(b64)!).toString('hex'), hex);
    }
    for (const { b64 } of vectors.b64.invalid) assert.equal(decodeB64(b64), null);
    assert.equal(decodeB64('AA\n'), null);
    const large = new Uint8Array(778240).fill(193);
    assert.deepEqual(decodeB64(encodeB64(large)), large, 'large ciphertext never spreads into function arguments');
});

test('the browser and relay use the same strict reader for every JSON rejection vector (§14 case 11)', () => {
    for (const entry of vectors['strict-json'].refuse)
        assert.throws(() => parseStrict(bytes(entry), entry.limit ?? 4096), JsonError, entry.why);
    for (const entry of vectors['strict-json'].accept)
        assert.doesNotThrow(() => parseStrict(bytes(entry), entry.limit ?? 4096), entry.why);
});

test('the shared browser-safe writer preserves the exact serialization vector (§14 case 12)', () => {
    const v = vectors.serialization;
    const text = Buffer.from(v.string_hex, 'hex').toString('utf8');
    const written = writeJson(text);
    assert.equal(Buffer.from(written).toString('hex'), v.written_hex);
    assert.equal(written.length - 2, v.encoded_size);
});
