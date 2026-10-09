import assert from 'node:assert/strict';
import { test } from 'node:test';
import { itemIdValue, JsonError, JsonNumber, parseStrict, unsignedValue, writeJson } from '../src/json.ts';
import { vectorBytes, vectors } from './vectors.ts';

const LIMIT = 4096;

test('strict-json vectors (§14 case 11): every listed text is refused', () => {
    for (const entry of vectors['strict-json'].refuse) {
        assert.throws(() => parseStrict(vectorBytes(entry), entry.limit ?? LIMIT), JsonError, entry.why);
    }
});

test('strict-json vectors (§14 case 11): the accepted texts parse', () => {
    for (const entry of vectors['strict-json'].accept) {
        assert.doesNotThrow(() => parseStrict(vectorBytes(entry), entry.limit ?? LIMIT), entry.why);
    }
    assert.deepEqual(parseStrict(Buffer.from('{"a":"\\ud83d\\ude00"}'), LIMIT), Object.assign(Object.create(null), { a: '😀' }));
});

test('strict-json vectors (§14 case 11): integers follow §3', () => {
    for (const { text, item_id, unsigned } of vectors['strict-json'].numbers) {
        let value;
        try {
            value = (parseStrict(Buffer.from(`{"n":${text}}`), LIMIT) as Record<string, JsonNumber>).n;
        } catch {
            value = undefined;
        }
        assert.equal(itemIdValue(value) !== null, item_id, `${text} as an item id`);
        assert.equal(unsignedValue(value) !== null, unsigned, `${text} as an unsigned integer`);
    }
});

test('the parser reads JSON values and refuses malformed text', () => {
    const value = parseStrict(Buffer.from(' {"a":[true,false,null,"x\\n\\u00e9",-1.5e3],"b":{}} '), LIMIT);
    assert.deepEqual(JSON.parse(JSON.stringify(value, (_k, v) => (v instanceof JsonNumber ? v.raw : v))), {
        a: [true, false, null, 'x\né', '-1.5e3'],
        b: {},
    });
    for (const bad of ['', '{', '{"a":1,}', '[1,]', '{"a" 1}', '"\u0001"', '"\\x"', 'tru', '{} {}', '"\\ud800\\u0041"', "{'a':1}"]) {
        assert.throws(() => parseStrict(Buffer.from(bad), LIMIT), JsonError, JSON.stringify(bad));
    }
});

test('a member named __proto__ is an ordinary member', () => {
    const value = parseStrict(Buffer.from('{"__proto__":{"x":1}}'), LIMIT) as Record<string, unknown>;
    assert.ok(Object.hasOwn(value, '__proto__'));
});

test('serialization vector (§14 case 12): writers emit exactly these bytes', () => {
    const v = vectors.serialization;
    const text = Buffer.from(v.string_hex, 'hex').toString('utf8');
    const written = Buffer.from(writeJson(text));
    assert.equal(written.toString('hex'), v.written_hex);
    assert.equal(written.length - 2, v.encoded_size);
    assert.equal(parseStrict(written, LIMIT), text);
});
