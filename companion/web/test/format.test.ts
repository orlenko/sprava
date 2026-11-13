import assert from 'node:assert/strict';
import { test } from 'node:test';
import { codeLabel, dayLabel, itemFacts, localDay, pendingLabel, REFRESH_EVERY, refreshDue, timeLabel } from '../src/format.ts';
import type { ViewItem } from '../src/view-payloads.ts';

const today = '2026-03-10';
const item = (fields: Partial<ViewItem>): ViewItem => ({ id: 1, changedIn: 1, title: 'Invented', status: 'open', priority: null,
    due: null, waitingOn: null, followUpAt: null, notes: null, tags: [], contexts: [], ...fields });

test('days read as words near today and as short dates further off, with the year only when it differs', () => {
    assert.equal(dayLabel(today, today), 'today');
    assert.equal(dayLabel('2026-03-11', today), 'tomorrow');
    assert.equal(dayLabel('2026-03-09', today), 'yesterday');
    assert.equal(dayLabel('2026-03-17', today, 'en-GB'), 'Tue 17 Mar');
    assert.match(dayLabel('2027-01-05', today, 'en-GB'), /^Tue,? 5 Jan 2027$/);
});

test('dates and times with a year below 1000, which a view may carry, still render', () => {
    // Regression: localDay wrote year 99 as "99", and dayLabel then threw on the invalid date it built.
    const now = new Date('2026-03-10T12:00:00Z');
    const early = new Date(2000, 2, 10); early.setFullYear(99);
    assert.equal(localDay(early), '0099-03-10');
    assert.match(timeLabel('0099-03-10T12:00:00Z', now, 'en-GB'), /0099|99/);
    assert.match(dayLabel('0099-03-10', today, 'en-GB'), /99/);
    assert.equal(timeLabel('not a time', now), 'not a time');
});

test('an item says what is late, what it waits on and when to chase it', () => {
    assert.deepEqual(itemFacts(item({ due: '2026-03-08' }), today, 'en-GB'), ['Overdue: was due Sun 8 Mar']);
    assert.deepEqual(itemFacts(item({ due: today }), today), ['Due today']);
    assert.deepEqual(itemFacts(item({ status: 'waiting', waitingOn: 'Example Shop', followUpAt: '2026-03-09' }), today),
        ['Waiting on Example Shop', 'Follow up: due yesterday']);
    assert.deepEqual(itemFacts(item({ status: 'blocked', followUpAt: '2026-03-11' }), today), ['Blocked', 'Follow up tomorrow']);
    assert.deepEqual(itemFacts(item({}), today), []);
});

test('pending actions name their kind, number and state in plain words', () => {
    const now = new Date('2026-03-10T12:00:00Z');
    const label = pendingLabel({ type: 'follow_up', seq: 4, state: 'sent', madeAt: '2026-03-10T11:58:00Z' }, now, 'en-GB');
    assert.match(label, /^Follow up #4 · Sent; waiting for your Mac · /);
    assert.match(pendingLabel({ type: 'done', seq: 2, state: 'conflict', madeAt: '2026-03-10T11:58:00Z' }, now), /changed on your Mac/);
});

test('the confirmation code shows as two groups of three (§4.3)', () => {
    assert.equal(codeLabel('042917'), '042 917');
});

test('automatic reads stay under the relay limit of 600 an hour; a forced read always runs', () => {
    // Regression: the app read three listings every 10 seconds, 1,080 an hour, and the relay answered 429.
    let reads = 0, last: number | undefined;
    for (let now = 0; now < 3600000; now += 10000) if (refreshDue(last, now, false, false)) { reads += 3; last = now; }
    assert.ok(reads <= 200, `${reads} listings an hour`);
    assert.equal(refreshDue(0, REFRESH_EVERY - 1, false, false), false);
    assert.equal(refreshDue(0, 1, true, true), true);
    assert.equal(refreshDue(0, REFRESH_EVERY, false, true), false, 'a hidden page does not poll');
});
