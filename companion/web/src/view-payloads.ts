// Authenticated view schemas (companion-v0 §8.5). Freshness/durable admission remain the caller's (§10.2).
import { itemIdValue } from '../../shared/json.ts';
import type { Json } from '../../shared/json.ts';
import { isId } from './encoding.ts';
import { integer, isDate, isTime, object, PayloadError, text } from './payload.ts';
import { openObject } from './sealed.ts';

export type ItemId = string | number;
export const bucketNames = ['overdue', 'today', 'next_7_days', 'later', 'no_deadline', 'nudge', 'waiting'] as const;
export type BucketName = typeof bucketNames[number];
export interface ViewItem {
    id: ItemId;
    changedIn: number;
    title: string;
    status: 'open' | 'waiting' | 'blocked';
    priority: string | null;
    due: string | null;
    waitingOn: string | null;
    followUpAt: string | null;
    notes: string | null;
    tags: string[];
    contexts: string[];
}
export interface ClosedItem {
    id: ItemId;
    title: string;
    closedAt: string | null;
    how: 'done' | 'dropped';
}
export interface BinderView {
    version: number;
    generatedAt: string;
    today: string | null;
    binder: { name: string; description: string | null };
    notesOmitted: boolean;
    buckets: Record<BucketName, ItemId[]>;
    items: ViewItem[];
    closed: ClosedItem[];
    documents: { title: string; date: string | null }[];
}

function string(value: Json | undefined): string {
    if (typeof value !== 'string') throw new PayloadError();
    return value;
}
function nullableString(value: Json | undefined): string | null {
    return value === null || value === undefined ? null : string(value);
}
function date(value: Json | undefined): string | null {
    if (value === null || value === undefined) return null;
    if (!isDate(value)) throw new PayloadError();
    return value;
}
function array(value: Json | undefined): Json[] {
    if (!Array.isArray(value)) throw new PayloadError();
    return value;
}
function id(value: Json | undefined): ItemId {
    if (typeof value === 'string') return text(value, 1, 200, 800);
    const n = itemIdValue(value);
    if (n === null) throw new PayloadError();
    return n;
}

/** Unique ids use their JSON type too: 7 and "7" are different, as are canonically equivalent Unicode strings. */
export async function openView(binderId: string, version: number, epoch: number, binderKey: CryptoKey,
    ownerKey: CryptoKey, bytes: Uint8Array): Promise<BinderView> {
    try {
        if (!isId(binderId) || !Number.isSafeInteger(version) || version < 1) throw new PayloadError();
        const value = await openObject(`views/${binderId}/${version}`, epoch, binderKey, bytes, ownerKey);
        if (integer(value.version, 1) !== version || !isTime(value.generated_at) || typeof value.notes_omitted !== 'boolean')
            throw new PayloadError();
        const binder = object(value.binder);
        const seen = new Set<ItemId>();
        const uniqueId = (value: Json | undefined) => {
            const result = id(value);
            if (seen.has(result)) throw new PayloadError();
            seen.add(result);
            return result;
        };
        const items: ViewItem[] = array(value.items).map(entry => {
            const item = object(entry), changedIn = integer(item.changed_in, 1);
            if (changedIn > version || !['open', 'waiting', 'blocked'].includes(string(item.status))) throw new PayloadError();
            return { id: uniqueId(item.id), changedIn, title: string(item.title), status: item.status as ViewItem['status'],
                priority: nullableString(item.priority), due: date(item.due), waitingOn: nullableString(item.waiting_on),
                followUpAt: date(item.follow_up_at), notes: nullableString(item.notes),
                tags: array(item.tags).map(string), contexts: array(item.contexts).map(string) };
        });
        const openIds = new Set(seen);
        const closed: ClosedItem[] = array(value.closed).map(entry => {
            const item = object(entry), how = string(item.how), closedAt = nullableString(item.closed_at);
            if (!['done', 'dropped'].includes(how) || (closedAt !== null && !isDate(closedAt) && !isTime(closedAt)))
                throw new PayloadError();
            return { id: uniqueId(item.id), title: string(item.title), closedAt, how: how as ClosedItem['how'] };
        });
        const bucket = object(value.buckets);
        const buckets = Object.fromEntries(bucketNames.map(name => [name, array(bucket[name]).map(value => {
            const entry = id(value);
            if (!openIds.has(entry)) throw new PayloadError();
            return entry;
        })])) as Record<BucketName, ItemId[]>;
        const documents = array(value.documents).map(entry => {
            const doc = object(entry);
            return { title: string(doc.title), date: date(doc.date) };
        });
        return { version, generatedAt: value.generated_at, today: date(value.today),
            binder: { name: text(binder.name, 1, 200, 800), description: nullableString(binder.description) },
            notesOmitted: value.notes_omitted, buckets, items, closed, documents };
    } catch { throw new PayloadError(); }
}
