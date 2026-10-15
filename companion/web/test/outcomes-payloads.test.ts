import assert from 'node:assert/strict';
import { test } from 'node:test';
import { writeJson } from '../../shared/json.ts';
import { encodeB64 } from '../src/encoding.ts';
import { openOutcomes } from '../src/outcomes-payloads.ts';
import { PayloadError } from '../src/payload.ts';
import { id, key, otherId, owner, sealed } from './owner-fixture.ts';

const entry = (request_id = id, seq = 1, outcome = 'applied') =>
    ({ request_id, seq, outcome, decided_at: '2026-10-08T07:06:05Z' });
const payload = () => ({ device_id: id, revision: 7, generated_at: '2026-10-08T07:06:05Z', outcomes: [entry()], pad: '' });
function padded(value: Record<string, unknown>, target?: number): Record<string, unknown> {
    const v = { ...value, pad: '' }, n = (v as { outcomes?: unknown[] }).outcomes?.length ?? 0;
    return { ...v, pad: ' '.repeat((target ?? 512 + 128 * n) - writeJson(v).length) };
}
async function open(value: unknown, plaintext?: string) {
    return openOutcomes(id, 7, await key(), await owner(),
        sealed(`devices/${id}/outcomes/7`, 'device', 0, value, true, plaintext));
}

test('authenticated, padded outcomes expose only protocol fields and keep unknown distinct from final outcomes', async () => {
    const outcomes = ['applied', 'conflict', 'rejected', 'unknown'].map((outcome, i) =>
        entry(encodeB64(new Uint8Array(16).fill(i)), i + 1, outcome));
    const result = await open(padded({ ...payload(), outcomes, ignored: true }));
    assert.deepEqual(result.outcomes.map(o => o.outcome), ['applied', 'conflict', 'rejected', 'unknown']);
    assert.deepEqual(Object.keys(result).sort(), ['generatedAt', 'outcomes', 'revision']);
    assert.deepEqual(Object.keys(result.outcomes[0]!).sort(), ['decidedAt', 'outcome', 'requestId', 'seq']);
    assert.deepEqual((await open(padded({ ...payload(), outcomes: [] }))).outcomes, []);
});

test('original plaintext byte length, not reserialized JSON, controls padding acceptance', async () => {
    const base = JSON.stringify({ ...payload(), pad: '' });
    const length = 640 - new TextEncoder().encode(base).length - 1;
    const spaced = base.replace('"pad":""', `"pad":"${' '.repeat(length)}"`) + '\n';
    assert.equal(new TextEncoder().encode(spaced).length, 640);
    assert.equal((await open(null, spaced)).outcomes.length, 1);
    for (const value of [{ ...padded(payload()), pad: undefined }, { ...padded(payload()), pad: '\t' },
        { ...padded(payload()), pad: '\n' }, padded(payload(), 639), padded(payload(), 641)])
        await assert.rejects(open(value), PayloadError);
    const padding = padded(payload()).pad as string;
    await assert.rejects(open({ ...payload(), pad: padding.slice(1) + '\n' }), PayloadError);
});

test('wrong device/revision, repeated request ids and malformed entry fields reject the whole object', async () => {
    for (const change of [{ device_id: otherId }, { revision: 8 }, { revision: 0 },
        { generated_at: '2026-02-30T07:06:05Z' }, { outcomes: [entry(), entry()] }, { outcomes: null }]) {
        const value = { ...payload(), ...change };
        await assert.rejects(open(padded(value)), PayloadError);
    }
    for (const change of [{ request_id: 'invalid' }, { seq: 0 }, { seq: -1 }, { seq: 1.5 },
        { seq: '1' }, { outcome: 'sent' }, { outcome: null }, { decided_at: 'invalid' }])
        await assert.rejects(open(padded({ ...payload(), outcomes: [{ ...entry(), ...change }] })), PayloadError);
    const lexical = JSON.stringify(padded(payload())).replace('"seq":1', '"seq":1.0').replace('"pad":"  ', '"pad":"');
    assert.equal(new TextEncoder().encode(lexical).length, 640);
    await assert.rejects(open(null, lexical), PayloadError);
});

test('2000 outcomes fit the exact bound; excess entries and oversize plaintext are refused', async () => {
    const outcomes = Array.from({ length: 2000 }, (_, i) => {
        const bytes = new Uint8Array(16); new DataView(bytes.buffer).setUint32(0, i);
        return entry(encodeB64(bytes), i + 1, 'unknown');
    });
    assert.equal((await open(padded({ ...payload(), outcomes }))).outcomes.length, 2000);
    await assert.rejects(open(padded({ ...payload(), outcomes: [...outcomes, entry(otherId, 2001)] })), PayloadError);
});

test('unsigned, renamed and wrong-epoch outcomes cannot be used as device confirmations', async () => {
    const value = padded(payload()), k = await key(), s = await owner();
    await assert.rejects(openOutcomes(id, 7, k, s, sealed(`devices/${id}/outcomes/7`, 'device', 0, value, false)), PayloadError);
    await assert.rejects(openOutcomes(id, 8, k, s, sealed(`devices/${id}/outcomes/7`, 'device', 0, value)), PayloadError);
    await assert.rejects(openOutcomes(id, 7, k, s, sealed(`devices/${id}/outcomes/7`, 'device', 1, value)), PayloadError);
});
