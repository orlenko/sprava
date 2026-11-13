// Decrypt admitted caches only in memory; recheck their prerequisites after asynchronous crypto.
import type { BrowserStore } from './browser-store.ts';
import { openIndex } from './owner-payloads.ts';
import type { BinderIndex } from './owner-payloads.ts';
import { openView } from './view-payloads.ts';
import type { BinderView } from './view-payloads.ts';
import { PayloadError } from './payload.ts';

/** `views` holds every binder whose admitted view matches the current index, for the cross-binder Today. */
export interface DisplayCache {
    generation?: string; index?: BinderIndex; view?: BinderView; binderId?: string; views?: Map<string, BinderView>;
}
const equal = (a: Uint8Array, b: Uint8Array) => a.length === b.length && a.every((v, i) => v === b[i]);

/** The returned generation also identifies which pairing a screen's later actions belong to. */
export async function readDisplayCache(store: BrowserStore, binderId?: string): Promise<DisplayCache> {
    for (let retry = 0; retry <= 3; retry++) {
        const before = await store.read(), p = before.pairing, i = before.index;
        if (!p) return {};
        if (!i || i.epoch !== p.epoch) return { generation: p.generation };
        let index: BinderIndex;
        const views = new Map<string, BinderView>();
        try {
            index = await openIndex(i.revision, i.epoch, p.accountKey, p.ownerKey, i.bytes);
            for (const binder of i.binders) {
                const stored = await store.readView(binder.id);
                if (!stored || stored.epoch !== i.epoch || stored.version !== binder.viewVersion) continue;
                // One view that no longer opens hides only its own binder.
                try { views.set(binder.id, await openView(binder.id, stored.version, i.epoch, binder.key, p.ownerKey, stored.bytes)); }
                catch (error) { if (!(error instanceof PayloadError)) throw error; }
            }
        } catch (error) {
            if (!(error instanceof PayloadError)) throw error;
            return { generation: p.generation };
        }
        const after = await store.read(), current = after.pairing, latest = after.index;
        if (!current || current.generation !== p.generation || current.epoch !== p.epoch ||
            !latest || latest.revision !== i.revision || latest.epoch !== i.epoch || !equal(latest.bytes, i.bytes)) continue;
        if ([...views].some(([id, view]) => (after.viewMarks[id] ?? 0) > view.version)) continue;
        const view = binderId === undefined ? undefined : views.get(binderId);
        return { generation: p.generation, index, view, binderId: index.binders.some(b => b.id === binderId) ? binderId : undefined, views };
    }
    return {};
}
