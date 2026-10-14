import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { JsonObject } from '../../shared/json.ts';
import { parseStrict, unsignedValue } from '../../shared/json.ts';
import { helloPayload, requestPayload, sealHello, sealRequest, sealRevocation, validateAction } from '../src/device-payloads.ts';
import type { RequestAction } from '../src/device-payloads.ts';
import { PayloadError } from '../src/payload.ts';
import { openPayload } from '../src/sealed.ts';
import { id, otherId, key } from './owner-fixture.ts';

const time = '2026-10-08T07:06:05Z';
const action = (): RequestAction => ({ type: 'done', binder: id, item: -7, seenVersion: 7 });
const decode = (a: RequestAction) => parseStrict(requestPayload(a, 1, time), 48128) as JsonObject;

test('every action follows the request table, retaining the exact item-id type and chosen date', () => {
    for (const type of ['done', 'drop', 'arrived', 'follow_up', 'postpone'] as const) {
        const a = { ...action(), type, date: ['follow_up', 'postpone'].includes(type) ? '2026-10-09' : null };
        const value = decode(a);
        assert.equal(value.type, type); assert.equal(value.date, a.date);
        assert.equal(unsignedValue(value.item), null, 'negative ids remain signed');
    }
    assert.equal(decode({ ...action(), item: '7' }).item, '7');
    assert.equal(decode({ type: 'note', text: 'Invented note' }).binder, null);
    assert.equal(decode({ type: 'note', binder: id, text: 'Invented note' }).binder, id);
});

test('notes enforce inclusive scalar and encoded-byte limits, allowed controls and Unicode scalar validity', () => {
    for (const note of ['x'.repeat(10000), '😀'.repeat(10000), 'Invented\tnote\n'])
        assert.doesNotThrow(() => validateAction({ type: 'note', text: note }));
    for (const note of ['', 'x'.repeat(10001), '😀'.repeat(10001), '"'.repeat(10000) + 'x', '\x00', '\r', '\ud800'])
        assert.throws(() => validateAction({ type: 'note', text: note }), PayloadError);
    // Each backslash encodes as two bytes: scalar and byte limits are checked independently.
    assert.doesNotThrow(() => validateAction({ type: 'note', text: '\\'.repeat(10000) }));
    assert.equal(decode({ type: 'note', text: '  ' }).text, '  ', 'never trim what the person wrote');
});

test('bad action combinations, ids, versions and dates are refused before numbering', () => {
    for (const change of [{ binder: null }, { binder: 'invalid' }, { item: 0 }, { item: '' }, { item: 1.5 },
        { item: Number.MAX_SAFE_INTEGER + 1 }, { item: '\ud800' }, { seenVersion: 0 }, { seenVersion: 1.5 },
        { date: '2026-10-09' }, { text: 'Invented note' }])
        assert.throws(() => validateAction({ ...action(), ...change }), PayloadError);
    for (const a of [{ ...action(), type: 'follow_up', date: '2026-02-30' },
        { ...action(), type: 'postpone' }, { type: 'note', item: 'x', text: 'Invented note' },
        { type: 'note', seenVersion: 7, text: 'Invented note' }])
        assert.throws(() => validateAction(a as RequestAction), PayloadError);
    for (const seq of [0, -1, 1.5, Number.MAX_SAFE_INTEGER + 1]) assert.throws(() => requestPayload(action(), seq, time), PayloadError);
    assert.throws(() => requestPayload(action(), 1, '2026-10-08'), PayloadError);
});

test('sealed requests use the smallest whole-KiB target and preserve exactly what was validated', async () => {
    const k = await key();
    for (const a of [action(), { type: 'note', text: 'Invented short note' } as RequestAction,
        { type: 'note', text: '😀'.repeat(10000) } as RequestAction]) {
        const bytes = await sealRequest(id, otherId, 2, k, a, 1, time);
        const opened = await openPayload(`requests/${id}/${otherId}`, 2, k, bytes);
        assert.equal(opened.plaintextLength % 1024, 0);
        const pad = opened.value.pad as string;
        assert.match(pad, /^ *$/); assert.ok(pad.length < 1024);
        assert.equal(opened.value.type, a.type); assert.equal(opened.value.text, a.text ?? null);
        assert.ok(bytes.length <= 65536);
    }
});

test('hello labels have private fixed padding and reject controls, oversize labels and lone surrogates', async () => {
    const k = await key();
    assert.equal(helloPayload('😀'.repeat(40)).length, 512);
    for (const label of ['', 'x'.repeat(41), 'Invented\nphone', '\x7f', '\ud800'])
        assert.throws(() => helloPayload(label), PayloadError);
    const bytes = await sealHello(id, k, 'Invented phone');
    const opened = await openPayload(`pairings/${id}/hello`, 0, k, bytes);
    assert.equal(opened.plaintextLength, 512); assert.equal(opened.value.label, 'Invented phone');
});

test('revocation is bound to the installed instance and generation, separate from all numbered actions', async () => {
    const k = await key(), bytes = await sealRevocation(id, k, '0'.repeat(32), otherId, time);
    const opened = await openPayload(`devices/${id}/revocation`, 0, k, bytes);
    assert.equal(opened.value.type, 'revoke-self'); assert.equal(opened.value.pairing_generation, otherId);
    assert.equal(opened.value.instance, '0'.repeat(32));
    await assert.rejects(sealRevocation(id, k, 'invalid', otherId, time), PayloadError);
});
