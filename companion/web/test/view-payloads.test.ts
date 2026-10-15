import assert from 'node:assert/strict';
import { test } from 'node:test';
import { openView, bucketNames } from '../src/view-payloads.ts';
import { PayloadError } from '../src/payload.ts';
import { id, key, owner, sealed } from './owner-fixture.ts';

const item = (id: string | number = 'item-1') => ({ id, changed_in: 3, title: 'Invented item', status: 'open',
    priority: null, due: null, waiting_on: null, follow_up_at: null, notes: null, tags: [], contexts: [] });
const view = () => ({ version: 7, generated_at: '2026-10-08T07:06:05Z', today: '2026-10-08',
    binder: { name: 'Invented binder', description: null }, notes_omitted: false,
    buckets: Object.fromEntries(bucketNames.map(name => [name, name === 'no_deadline' ? ['item-1'] : []])),
    items: [item()], closed: [], documents: [] });
async function open(value: unknown, plaintext?: string) {
    return openView(id, 7, 1, await key(), await owner(), sealed(`views/${id}/7`, id, 1, value, true, plaintext));
}

test('a complete authenticated view returns only defined fields, with legacy nullable fields normalized (§8.5)', async () => {
    const value = view();
    value.items[0]!.title = '<script>Invented inert title</script>';
    const result = await open({ ...value, unknown: 'not exposed', documents: [{ title: '', date: null }],
        closed: [{ id: -7, title: '', closed_at: '2026-10-07', how: 'done' }] });
    assert.equal(result.items[0]!.title, value.items[0]!.title, 'text remains data; the screen must render text, not HTML');
    assert.equal(result.closed[0]!.closedAt, '2026-10-07');
    assert.deepEqual(result.documents, [{ title: '', date: null }]);
    assert.deepEqual(Object.keys(result).sort(), ['binder', 'buckets', 'closed', 'documents', 'generatedAt', 'items', 'notesOmitted', 'today', 'version']);
    assert.equal(result.binder.description, null);
    assert.equal((await open({ ...view(), today: null })).today, null);
});

test('item ids preserve JSON types and Unicode scalar identity without normalization', async () => {
    const ids = [7, '7', 'é', 'e\u0301'];
    const result = await open({ ...view(), items: ids.map(item), buckets: {
        ...view().buckets, no_deadline: ids,
    } });
    assert.deepEqual(result.items.map(i => i.id), ids);
    assert.deepEqual(result.buckets.no_deadline, ids);
});

test('repeated ids, closed bucket members, missing members and invalid id forms reject the whole view', async () => {
    for (const value of [
        { ...view(), items: [item(), item()] },
        { ...view(), closed: [{ id: 'item-1', title: '', closed_at: null, how: 'done' }] },
        { ...view(), buckets: { ...view().buckets, no_deadline: ['absent'] } },
        { ...view(), buckets: { ...view().buckets, today: undefined } },
        { ...view(), items: [item(0)] }, { ...view(), items: [item('')] },
        { ...view(), items: [item(9007199254740992)] }, { ...view(), items: [item('😀'.repeat(201))] },
        { ...view(), closed: [{ id: 'closed', title: '', closed_at: null, how: 'done' }],
            buckets: { ...view().buckets, no_deadline: ['closed'] } },
    ]) await assert.rejects(open(value), PayloadError);
});

test('changed_in must be a canonical integer between 1 and the view version', async () => {
    for (const changed_in of [0, 8, -1, 1.5, undefined])
        await assert.rejects(open({ ...view(), items: [{ ...item(), changed_in }] }), PayloadError);
    const fractional = JSON.stringify(view()).replace('"changed_in":3', '"changed_in":3.0');
    await assert.rejects(open(null, fractional), PayloadError);
    const numericId = JSON.stringify({ ...view(), items: [item(7)], buckets: { ...view().buckets, no_deadline: [7] } });
    await assert.rejects(open(null, numericId.replace('"id":7', '"id":7e0')), PayloadError);
});

test('field types, statuses, dates and versions are checked instead of coercing invalid data', async () => {
    for (const changes of [
        { title: null }, { status: 'done' }, { priority: 1 }, { due: '2026-02-30' }, { follow_up_at: '20261008' },
        { waiting_on: [] }, { notes: 7 }, { tags: [1] }, { contexts: null },
    ]) await assert.rejects(open({ ...view(), items: [{ ...item(), ...changes }] }), PayloadError);
    for (const changes of [
        { version: 8 }, { generated_at: '2026-10-08' }, { today: '2026-02-30' }, { notes_omitted: 'false' },
        { binder: { name: '', description: null } }, { binder: { name: 'Invented binder', description: 7 } },
        { closed: [{ id: 'closed', title: '', closed_at: 'invalid', how: 'done' }] },
        { closed: [{ id: 'closed', title: '', closed_at: null, how: 'open' }] },
        { documents: [{ title: null, date: null }] }, { documents: [{ title: '', date: '2026-02-30' }] },
    ]) await assert.rejects(open({ ...view(), ...changes }), PayloadError);
});

test('unsigned views, another name/epoch, and plaintext above the view bound never produce display data', async () => {
    const binderKey = await key(), ownerKey = await owner();
    await assert.rejects(openView(id, 7, 1, binderKey, ownerKey, sealed(`views/${id}/7`, id, 1, view(), false)), PayloadError);
    const bytes = sealed(`views/${id}/7`, id, 1, view());
    await assert.rejects(openView(id, 8, 1, binderKey, ownerKey, bytes), PayloadError);
    await assert.rejects(openView(id, 7, 2, binderKey, ownerKey, bytes), PayloadError);
    await assert.rejects(open({ ...view(), binder: { name: 'Invented binder', description: 'x'.repeat(778240) } }), PayloadError);
});
