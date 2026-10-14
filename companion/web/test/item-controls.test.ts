import assert from 'node:assert/strict';
import { test } from 'node:test';
import { allowedActions, itemAction } from '../src/item-controls.ts';
import type { ViewItem } from '../src/view-payloads.ts';
import { id } from './owner-fixture.ts';
const item = (status: ViewItem['status'], due: string | null = null): ViewItem => ({
    id: 7, changedIn: 2, title: 'Invented item', status, due, priority: null, waitingOn: null,
    followUpAt: null, notes: null, tags: [], contexts: [] });
test('controls follow the allowed status/effect table and do not offer postpone without a deadline', () => {
    assert.deepEqual(allowedActions(item('open')), ['done', 'drop']);
    assert.deepEqual(allowedActions(item('open', '2026-10-21')), ['done', 'drop', 'postpone']);
    for (const status of ['waiting', 'blocked'] as const)
        assert.deepEqual(allowedActions(item(status)), ['done', 'drop', 'arrived', 'follow_up']);
});
test('item actions preserve typed ids and the published view version rather than changed_in', () => {
    const number = itemAction('done', id, item('open'), 7);
    const string = itemAction('done', id, { ...item('open'), id: '7' }, 7);
    assert.equal(number.item, 7); assert.equal(string.item, '7');
    assert.equal(number.seenVersion, 7); assert.equal(number.text, null);
    const action = itemAction('follow_up', id, item('waiting'), 8, '2026-10-22');
    assert.equal(action.date, '2026-10-22'); assert.equal(action.seenVersion, 8);
    assert.equal(itemAction('follow_up', id, item('waiting'), 8).date, null, 'no invented date enters an unfinished editor');
    assert.throws(() => itemAction('arrived', id, item('open'), 7));
    assert.throws(() => itemAction('postpone', id, item('open'), 7, '2026-10-22'));
    assert.throws(() => itemAction('postpone', id, item('open', '2026-10-21'), 0, '2026-10-22'));
});
