// Plain-words labels for dates, times and pending actions. Pure functions; every result is shown as text.
import type { ViewItem } from './view-payloads.ts';
import type { OutboxEntry } from './outbox.ts';

/** The local calendar day of `now`, as YYYY-MM-DD. */
export function localDay(now = new Date()): string {
    return `${String(now.getFullYear()).padStart(4, '0')}-${String(now.getMonth() + 1).padStart(2, '0')}-` +
        String(now.getDate()).padStart(2, '0');
}
const dayNumber = (date: string) => Date.parse(`${date}T00:00:00Z`) / 86400000;

/** "today", "tomorrow", "yesterday", else a short weekday and date, with the year when it is not this year's. */
export function dayLabel(date: string, today: string, locale?: string): string {
    const difference = dayNumber(date) - dayNumber(today);
    if (difference === 0) return 'today';
    if (difference === 1) return 'tomorrow';
    if (difference === -1) return 'yesterday';
    // Any date the Mac may publish renders; one this formatter cannot read shows as written.
    try {
        return new Intl.DateTimeFormat(locale, { weekday: 'short', day: 'numeric', month: 'short', timeZone: 'UTC',
            ...(date.slice(0, 4) === today.slice(0, 4) ? {} : { year: 'numeric' }) }).format(new Date(`${date}T00:00:00Z`));
    } catch { return date; }
}

/** A time the Mac wrote (UTC), in the phone's own zone: the clock time today, else the day and the time. */
export function timeLabel(time: string, now = new Date(), locale?: string): string {
    const at = new Date(Date.parse(time.replace(':60Z', ':59Z')));
    if (Number.isNaN(at.getTime())) return time;
    const clock = new Intl.DateTimeFormat(locale, { hour: 'numeric', minute: '2-digit' }).format(at);
    return localDay(at) === localDay(now) ? clock : `${dayLabel(localDay(at), localDay(now), locale)}, ${clock}`;
}

/** What the person needs to know about an item's dates and waiting, in one line each. */
export function itemFacts(item: ViewItem, today: string, locale?: string): string[] {
    const facts: string[] = [];
    if (item.status === 'blocked') facts.push(item.waitingOn ? `Blocked: ${item.waitingOn}` : 'Blocked');
    else if (item.status === 'waiting') facts.push(item.waitingOn ? `Waiting on ${item.waitingOn}` : 'Waiting');
    if (item.followUpAt) facts.push(item.followUpAt <= today ? `Follow up: due ${dayLabel(item.followUpAt, today, locale)}` :
        `Follow up ${dayLabel(item.followUpAt, today, locale)}`);
    if (item.due) facts.push(item.due < today ? `Overdue: was due ${dayLabel(item.due, today, locale)}` :
        `Due ${dayLabel(item.due, today, locale)}`);
    return facts;
}

const actionNames: Record<OutboxEntry['type'], string> = { done: 'Done', drop: 'Drop', follow_up: 'Follow up',
    arrived: 'Arrived', postpone: 'Postpone', note: 'Note' };
const stateNames: Record<OutboxEntry['state'], string> = {
    queued: 'Saved on this phone; not sent yet',
    attempted: 'Sending',
    sent: 'Sent; waiting for your Mac',
    'not sent': 'Not sent: the pairing changed or it waited too long',
    conflict: 'Not applied: it changed on your Mac since. Check it there',
    rejected: 'Refused by your Mac',
    unresolved: 'No answer from your Mac; it may still apply it',
};
/** One pending action, by its kind, number and state; pending entries hold no title (§9.8). */
export function pendingLabel(entry: Pick<OutboxEntry, 'type' | 'seq' | 'state' | 'madeAt'>, now = new Date(), locale?: string): string {
    return `${actionNames[entry.type]} #${entry.seq} · ${stateNames[entry.state]} · ${timeLabel(entry.madeAt, now, locale)}`;
}

/** Six digits as two groups of three (§4.3). */
export function codeLabel(code: string): string {
    return /^\d{6}$/.test(code) ? `${code.slice(0, 3)} ${code.slice(3)}` : code;
}

/** Automatic reads stay well under the relay's 600 reads an hour (§7.5); sending is checked more often. */
export const REFRESH_EVERY = 60000;
export function refreshDue(lastRefresh: number | undefined, now: number, forced: boolean, hidden: boolean): boolean {
    return forced || (!hidden && (lastRefresh === undefined || now - lastRefresh >= REFRESH_EVERY));
}
