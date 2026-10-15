import assert from 'node:assert/strict';
import { test } from 'node:test';
import { IDBFactory, IDBKeyRange, IDBObjectStore } from 'fake-indexeddb';
import { BrowserStore } from '../src/browser-store.ts';
import { OutboxError } from '../src/outbox.ts';
import type { SendAttempt } from '../src/outbox-state.ts';
import { sendOne } from '../src/sender.ts';
import { encodeB64 } from '../src/encoding.ts';
import { writeJson } from '../../shared/json.ts';
import { id, key, raw, publicBytes, sealed } from './owner-fixture.ts';

const now = Date.parse('2026-10-08T07:06:05Z'), time = (n = now) => new Date(n).toISOString().replace('.000Z', 'Z');
const note = () => ({ type: 'note' as const, text: 'Invented queued note' });
globalThis.IDBKeyRange = IDBKeyRange;
async function paired() {
    const factory = new IDBFactory(), store = await BrowserStore.open('fixture', factory), r = await store.reserve(id);
    assert.ok(r);
    await store.install(r, { deviceId: id, relayOrigin: 'https://relay.example', instanceId: '0'.repeat(32), token: encodeB64(raw),
        expiresAt: time(), deviceKey: await key(), wrapKey: await key(), delivery: sealed(`pairings/${id}/key`, 'wrap', 1,
            { device_id: id, epoch: 1, min_index_revision: 0, account_key: encodeB64(raw), owner_signing_key: encodeB64(publicBytes) }, false) });
    return { store, factory };
}
function outcomes(attempt: SendAttempt, outcome = 'applied', revision = 1, seq = attempt.entry.seq) {
    const value = { device_id: id, revision, generated_at: time(), outcomes: [
        { request_id: attempt.entry.requestId, seq, outcome, decided_at: time() }], pad: '' };
    value.pad = ' '.repeat(640 - writeJson(value).length);
    return sealed(`devices/${id}/outcomes/${revision}`, 'device', 0, value);
}
function fakeLocks(): Pick<LockManager, 'request'> {
    let tail = Promise.resolve();
    return { request(name: string, options: LockOptions, callback: () => Promise<unknown>) {
        assert.equal(name, 'sprava-companion-send'); assert.equal(options.mode, 'exclusive');
        const result = tail.then(callback); tail = result.then(() => {}, () => {}); return result;
    } } as Pick<LockManager, 'request'>;
}

test('attempted commits before bytes are exposed, and retries preserve the original request bytes and order', async () => {
    const { store } = await paired(), original = await store.enqueue(note(), time());
    await store.enqueue(note(), time());
    const first = await store.beginAttempt(now); assert.ok(first);
    assert.equal((await store.readOutbox()).entries[0]!.state, 'attempted');
    assert.equal(first.entry.firstAttemptedAt, time()); assert.deepEqual(first.entry.bytes, original.bytes);
    await store.recordAttempt(first, 503, now);
    assert.equal(await store.beginAttempt(now + 1000), null, 'a later seq cannot overtake a delayed retry');
    const retry = await store.beginAttempt(now + 2000); assert.ok(retry);
    assert.equal(retry.entry.seq, first.entry.seq); assert.equal(retry.entry.requestId, first.entry.requestId);
    assert.deepEqual(retry.entry.bytes, first.entry.bytes);
    await store.recordAttempt(retry, 201, now + 2000);
    assert.equal((await store.readOutbox()).entries[0]!.state, 'sent');
    assert.equal((await store.beginAttempt(now + 2000))!.entry.seq, 2);
    store.close();
});

test('retry statuses grow a durable backoff to five minutes, survive restart, and handle clock changes', async () => {
    const { store, factory } = await paired(); await store.enqueue(note(), time());
    let n = now;
    for (const status of [429, 507, 500, null, 502, 503, 504, 503, 503, 503]) {
        const attempt = await store.beginAttempt(n); assert.ok(attempt);
        await store.recordAttempt(attempt, status, n);
        n += (await store.readOutbox()).entries[0]!.backoff * 1000;
    }
    assert.equal((await store.readOutbox()).entries[0]!.backoff, 300); store.close();
    const reopened = await BrowserStore.open('fixture', factory);
    assert.equal(await reopened.beginAttempt(n - 1000), null);
    assert.ok(await reopened.beginAttempt(n - 301000), 'deadline more than 5 minutes ahead counts as now');
    reopened.close();
});

test('ambiguous refusals stay visible; auth refusal suspends sending without erasing keys or entries', async () => {
    for (const status of [400, 401, 403, 413]) {
        const { store } = await paired(); await store.enqueue(note(), time()); await store.enqueue(note(), time());
        const attempt = await store.beginAttempt(now); assert.ok(attempt); await store.recordAttempt(attempt, status, now);
        const p = (await store.read()).pairing!;
        assert.equal((await store.readOutbox()).entries[0]!.state, 'unresolved'); assert.ok(p.deviceKey && p.token);
        assert.equal(Boolean(p.sendingSuspended), status === 401 || status === 403);
        assert.equal(Boolean(await store.beginAttempt(now)), status !== 401 && status !== 403);
        store.close();
    }
});

test('signed outcomes atomically resolve matching entries and their revision; late replies cannot overwrite them', async () => {
    for (const outcome of ['applied', 'conflict', 'rejected', 'unknown']) {
        const { store } = await paired(); await store.enqueue(note(), time());
        const attempt = await store.beginAttempt(now); assert.ok(attempt);
        assert.equal(await store.acceptOutcomes(2, outcomes(attempt, outcome, 2)), true);
        const entries = (await store.readOutbox()).entries;
        assert.equal(entries.length, outcome === 'applied' ? 0 : 1);
        if (entries[0]) assert.equal(entries[0].state, outcome === 'unknown' ? 'unresolved' : outcome);
        assert.equal((await store.read()).pairing!.outcomesRevision, 2);
        assert.equal(await store.recordAttempt(attempt, 201, now), false);
        assert.equal(await store.acceptOutcomes(1, outcomes(attempt, 'applied', 1)), false);
        store.close();
    }
});

test('outcomes cannot resolve a queued entry or a mismatched seq; failure rolls back the revision and entry together', async () => {
    const { store } = await paired(), entry = await store.enqueue(note(), time()), p = (await store.read()).pairing!;
    const tentative = { generation: p.generation, deviceId: id, relayOrigin: p.relayOrigin, token: p.token, entry };
    await store.acceptOutcomes(1, outcomes(tentative));
    assert.equal((await store.readOutbox()).entries[0]!.state, 'queued');
    const attempt = await store.beginAttempt(now); assert.ok(attempt);
    await store.acceptOutcomes(2, outcomes(attempt, 'applied', 2, entry.seq + 1));
    assert.equal((await store.readOutbox()).entries[0]!.state, 'attempted');
    const remove = IDBObjectStore.prototype.delete;
    IDBObjectStore.prototype.delete = function (...args: Parameters<IDBObjectStore['delete']>) {
        if (this.name === 'outbox') throw new DOMException('Invented quota failure', 'QuotaExceededError');
        return remove.apply(this, args);
    };
    try {
        await assert.rejects(store.acceptOutcomes(3, outcomes(attempt, 'applied', 3)), OutboxError);
        assert.equal((await store.read()).pairing!.outcomesRevision, 2);
        assert.equal((await store.readOutbox()).entries[0]!.state, 'attempted');
    } finally { IDBObjectStore.prototype.delete = remove; store.close(); }
});

test('30-day expiry never sends old queued actions; attempted actions stay unresolved and late outcomes can resolve them', async () => {
    const { store } = await paired(); await store.enqueue(note(), time(now - 31 * 86400000));
    await store.enqueue(note(), time()); const attempt = await store.beginAttempt(now); assert.ok(attempt);
    assert.equal(attempt.entry.seq, 2); assert.equal((await store.readOutbox()).entries[0]!.state, 'not sent');
    assert.equal(await store.beginAttempt(now + 30 * 86400000), null);
    assert.equal((await store.readOutbox()).entries[1]!.state, 'unresolved');
    await store.acceptOutcomes(1, outcomes(attempt)); assert.equal((await store.readOutbox()).entries.length, 1);
    store.close();
});

test('one shared lock covers durable attempted, transport and durable result; two windows send in sequence', async () => {
    const { store, factory } = await paired(), second = await BrowserStore.open('fixture', factory);
    await store.enqueue(note(), time()); await store.enqueue(note(), time());
    const locks = fakeLocks(), reached = Promise.withResolvers<void>(), release = Promise.withResolvers<void>(), seen: number[] = [];
    const transport = async (attempt: SendAttempt) => {
        seen.push(attempt.entry.seq); assert.equal((await store.readOutbox()).entries[attempt.entry.seq - 1]!.state, 'attempted');
        if (attempt.entry.seq === 1) { reached.resolve(); await release.promise; } return 201;
    };
    const first = sendOne(store, transport, locks, () => now); await reached.promise;
    const next = sendOne(second, transport, locks, () => now); assert.deepEqual(seen, [1]);
    release.resolve(); await Promise.all([first, next]); assert.deepEqual(seen, [1, 2]);
    assert.ok((await store.readOutbox()).entries.every(e => e.state === 'sent'));
    store.close(); second.close();
});

test('a timed-out transport aborts and releases the send lock with immutable retry bytes', async context => {
    context.mock.timers.enable({ apis: ['setTimeout'] });
    const { store } = await paired(); const original = await store.enqueue(note(), time());
    const reached = Promise.withResolvers<void>(); let aborted = false;
    const pending = sendOne(store, async (_attempt, signal) => {
        signal.addEventListener('abort', () => { aborted = true; }); reached.resolve();
        return new Promise<number>(() => {});
    }, fakeLocks(), () => now);
    await reached.promise; context.mock.timers.tick(30000); assert.equal(await pending, 'recorded');
    assert.equal(aborted, true); const retry = await store.beginAttempt(now + 2000); assert.ok(retry);
    assert.deepEqual(retry.entry.bytes, original.bytes); assert.equal(retry.entry.backoff, 2);
    store.close(); context.mock.timers.reset();
});


test('bounded expiry pages mark old sent actions unresolved, preserve visibility, and accept a late signed result', async () => {
    const { store } = await paired();
    const attempts: SendAttempt[] = [];
    for (let i = 0; i < 3; i++) {
        await store.enqueue(note(), time()); const attempt = await store.beginAttempt(now); assert.ok(attempt);
        attempts.push(attempt); await store.recordAttempt(attempt, 201, now);
    }
    const at = now + 30 * 86400000;
    const next = await store.expireOutbox(at, 2); assert.ok(next);
    assert.deepEqual((await store.readOutbox()).entries.map(e => e.state), ['unresolved', 'unresolved', 'sent']);
    assert.equal(await store.expireOutbox(at, 2, next), null);
    assert.ok((await store.readOutbox()).entries.every(e => e.state === 'unresolved'));
    await store.acceptOutcomes(1, outcomes(attempts[2]!));
    assert.deepEqual((await store.readOutbox()).entries.map(e => e.seq), [1, 2]); store.close();
});
