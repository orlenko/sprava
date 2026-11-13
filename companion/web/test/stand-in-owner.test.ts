// The web app's own modules against the real relay code and the stand-in owner: pair, read, act, read the outcome.
import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { IDBFactory, IDBKeyRange } from 'fake-indexeddb';
import { BrowserStore } from '../src/browser-store.ts';
import { readDisplayCache } from '../src/display-cache.ts';
import { itemAction } from '../src/item-controls.ts';
import { pairDevice } from '../src/pairing-flow.ts';
import { parsePairingLink } from '../src/pairing-link.ts';
import { refresh } from '../src/refresh.ts';
import { RelayClient } from '../src/relay-client.ts';
import { sendOne } from '../src/sender.ts';
import { startLocalRelay } from '../dev/local-relay.ts';
import { buckets, day, StandInOwner } from '../dev/stand-in-owner.ts';

globalThis.IDBKeyRange = IDBKeyRange;
const web = 'http://localhost:5173';
const relay = await startLocalRelay({ webOrigin: web });
after(() => relay.close());
const quick = (ms: number, signal: AbortSignal) => new Promise<void>((resolve, reject) => {
    const timer = setTimeout(resolve, Math.min(ms, 20));
    signal.addEventListener('abort', () => { clearTimeout(timer); reject(new Error('aborted')); }, { once: true });
});
const now = () => new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');

test('buckets follow the day the view is computed for', () => {
    const today = '2026-03-10', item = (id: string, fields: object) => ({ id, title: id, status: 'open' as const,
        priority: null, due: null, waitingOn: null, followUpAt: null, notes: null, tags: [], contexts: [], changedIn: 1, ...fields });
    assert.deepEqual(buckets([item('a', { due: '2026-03-09' }), item('b', { due: today }), item('c', { due: '2026-03-17' }),
        item('d', { due: '2026-03-18' }), item('e', {}), item('f', { status: 'waiting', followUpAt: today }),
        item('g', { status: 'blocked' })], today),
    { overdue: ['a'], today: ['b'], next_7_days: ['c'], later: ['d'], no_deadline: ['e'], nudge: ['f'], waiting: ['g'] });
    assert.equal(day(1, new Date(2026, 1, 28)), '2026-03-01');
});

test('a device pairs with the stand-in owner, shows its binders, and learns what became of its actions', async () => {
    const owner = new StandInOwner(relay.origin, `${web}/`);
    await owner.claim(relay.setupCode);
    await owner.publish();
    const link = parsePairingLink(new URL(await owner.startPairing()).hash);
    const store = await BrowserStore.open('stand-in', new IDBFactory());
    let shown = '';
    const pairing = pairDevice(store, link, 'Invented phone', { wait: quick, onCode: code => { shown = code; } });
    const joined = await owner.waitForJoin(undefined, 20);
    assert.equal(joined.label, 'Invented phone');
    await owner.confirm();
    await owner.waitForAcknowledgement(undefined, 20);
    assert.equal((await pairing).acknowledgement, 'acknowledged');
    assert.equal(joined.code.replace(' ', ''), shown, 'both sides derive the same confirmation code');

    const home = owner.binders[0]!, allotment = owner.binders[1]!;
    assert.equal((await refresh(store, home.id)).status, 'reached');
    let cache = await readDisplayCache(store, home.id);
    assert.deepEqual(cache.index?.binders.map(b => b.name), ['Home', 'Allotment', 'Choir']);
    assert.deepEqual(cache.view?.buckets.overdue, ['renew-library-card']);
    assert.deepEqual(cache.view?.buckets.nudge, ['kettle-refund']);

    await refresh(store, allotment.id);
    cache = await readDisplayCache(store, allotment.id);
    const view = cache.view!, numeric = view.items.find(i => i.id === 7)!, gate = view.items.find(i => i.id === 8)!;
    const generation = cache.generation!;
    await store.enqueue(itemAction('done', allotment.id, numeric, view.version), now(), generation);
    await store.enqueue(itemAction('follow_up', allotment.id, gate, view.version, day(5)), now(), generation);
    await store.enqueue(itemAction('postpone', allotment.id, numeric, view.version, day(9)), now(), generation);
    await store.enqueue({ type: 'note', text: 'Invented note from the phone' }, now(), generation);
    for (let i = 0; i < 4; i++) assert.equal(await sendOne(store, (attempt, signal) =>
        new RelayClient(attempt.relayOrigin, attempt.deviceId).send(attempt, signal)), 'recorded');

    const decided = await owner.drain();
    assert.deepEqual(decided.map(d => [d.seq, d.type, d.outcome]),
        [[1, 'done', 'applied'], [2, 'follow_up', 'applied'], [3, 'postpone', 'conflict'], [4, 'note', 'applied']]);
    assert.deepEqual(owner.notes, ['Invented note from the phone']);

    await refresh(store, allotment.id);
    cache = await readDisplayCache(store, allotment.id);
    assert.equal(cache.view?.items.some(i => i.id === 7), false, 'the closed item left the view');
    assert.equal(cache.view?.closed[0]?.id, 7);
    assert.equal(cache.view?.items.find(i => i.id === 8)?.followUpAt, day(5));
    const left = (await store.readOutbox(50)).entries;
    assert.deepEqual(left.map(e => [e.seq, e.state]), [[3, 'conflict']], 'applied actions resolve; the conflict stays visible');
    assert.deepEqual(await owner.drain(), [], 'nothing is decided twice');
    store.close();
});
