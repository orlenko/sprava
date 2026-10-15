// Bounded, generation-scoped owner refresh (companion-v0 §§4.4, 7.5, 10.3).
import { BrowserStore } from './browser-store.ts';
import { PayloadError } from './payload.ts';
import { RelayClient, RelayError } from './relay-client.ts';
import type { RelayReply } from './relay-client.ts';
import { resumeAcknowledgement } from './pairing-flow.ts';

export interface RefreshEnvironment { fetcher?: typeof fetch; clock?: () => number; signal?: AbortSignal }
export interface RefreshResult {
    status: 'unpaired' | 'stale' | 'offline' | 'reached' | 'refused'; lastReachedAt?: number;
}
class StaleRefresh extends Error {}

/** Refresh one selected view; unopened binders do not download their entire caches. */
export async function refresh(store: BrowserStore, binderId?: string,
    environment: RefreshEnvironment = {}): Promise<RefreshResult> {
    const initial = (await store.read()).pairing;
    if (!initial) return { status: 'unpaired' };
    const generation = initial.generation, clock = environment.clock ?? Date.now;
    const client = new RelayClient(initial.relayOrigin, initial.deviceId, environment.fetcher);
    const controller = new AbortController(), cancel = () => controller.abort();
    const timeout = setTimeout(cancel, 30000);
    environment.signal?.addEventListener('abort', cancel, { once: true });
    if (environment.signal?.aborted) cancel();
    let lastReachedAt: number | undefined, refused = false;
    const budgets = { keys: 5, index: 5, outcomes: 5 };
    const current = async () => {
        const state = await store.read();
        if (state.pairing?.generation !== generation) throw new StaleRefresh();
        return state;
    };
    const contacted = <T>(reply: RelayReply<T>): RelayReply<T> => {
        lastReachedAt = clock();
        if (reply.status === 401 || reply.status === 403) refused = true;
        return reply;
    };
    // Network/schema failures can cost a candidate. Storage failures must reach the caller.
    const candidate = async (operation: () => Promise<boolean>) => {
        try { return await operation(); }
        catch (error) {
            if (error instanceof PayloadError || error instanceof RelayError) return false;
            throw error;
        }
    };
    const find = async (kind: keyof typeof budgets) => {
        let below: number | undefined;
        while (budgets[kind] > 0 && !controller.signal.aborted && !refused) {
            await current();
            const listing = contacted(await client.list(kind, initial.token, below, controller.signal));
            if (!listing.value) return;
            for (const name of listing.value.names) {
                if (budgets[kind]-- <= 0) return;
                const revision = Number(name.slice(name.lastIndexOf('/') + 1));
                const state = await current(), p = state.pairing!;
                const floor = kind === 'keys' ? p.epoch + 1 : kind === 'outcomes' ? p.outcomesRevision :
                    Math.max(p.minIndexRevision, state.index?.revision ?? 0);
                if (revision < floor || controller.signal.aborted || refused) return;
                if (await candidate(async () => {
                    const reply = contacted(await client.getObject(name, initial.token, controller.signal));
                    if (!reply.value) return false;
                    const latest = await current();
                    if (kind === 'keys') return store.acceptKeys(revision, reply.value, generation);
                    if (kind === 'outcomes') return store.acceptOutcomes(revision, reply.value, generation);
                    return store.acceptIndex(revision, latest.pairing!.epoch, reply.value, generation);
                })) return;
            }
            if (listing.value.next === null) return;
            below = listing.value.next;
        }
    };
    const selected = async (): Promise<boolean> => {
        const state = await current(), index = state.index;
        if (!binderId || !index || index.epoch !== state.pairing!.epoch) return false;
        const binder = index.binders.find(b => b.id === binderId);
        if (!binder || await store.readView(binderId)) return false;
        const reply = contacted(await client.getObject(`views/${binderId}/${binder.viewVersion}`,
            initial.token, controller.signal));
        if (reply.status === 404) return true;
        if (reply.value) await candidate(() => store.acceptView(binderId, binder.viewVersion, reply.value!, generation));
        return false;
    };
    try {
        // Isolate unavailable prefixes: outcomes are epoch-independent and can still resolve sent actions.
        for (const kind of ['keys', 'index', 'outcomes'] as const) {
            try { await find(kind); } catch (error) { if (!(error instanceof RelayError)) throw error; }
        }
        try {
            if (!refused && !controller.signal.aborted && await selected()) {
                // A removed view points to a newer index. Re-list once, sharing the five-candidate budget.
                await find('index');
                if (!refused && !controller.signal.aborted) await selected();
            }
        } catch (error) { if (!(error instanceof RelayError)) throw error; }
        await current();
        if (!refused && !controller.signal.aborted) await resumeAcknowledgement(store,
            { ...environment, signal: controller.signal }, generation);
        await current();
        return { status: refused ? 'refused' : lastReachedAt === undefined ? 'offline' : 'reached', lastReachedAt };
    } catch (error) {
        if (error instanceof StaleRefresh) return { status: 'stale' };
        throw error;
    } finally {
        clearTimeout(timeout); environment.signal?.removeEventListener('abort', cancel);
    }
}
