// The relay: its shared state, what it checks before serving, and its routes (companion-v0 §7).
import type { IncomingMessage, ServerResponse } from 'node:http';
import { ConfigError, isSetupCode, type Config } from './config.ts';
import { createHandler, type Principal, type Route } from './http.ts';
import { Lease, LEASE_TIMING, sleep } from './lease.ts';
import type { Log } from './log.ts';
import { Mutex, withIntents, type Store } from './store/store.ts';

export interface Relay {
    readonly config: Config;
    /** The store, already scoped to `SPRAVA_INSTANCE/` (§7.8). */
    readonly store: Store;
    readonly log: Log;
    /** §6 step 5: claims, pairing joins, object and request creation take this one lock. */
    readonly lock: Mutex;
    now(): number;
    claimed: boolean;
    /** Runs `work` every `ms` until the relay stops; a failure is logged by name only. */
    repeat(ms: number, name: string, work: () => Promise<void>): void;
}

export interface RelayOptions {
    log: Log;
    now?: () => number;
    bodyTimeoutMs?: number;
    lease?: typeof LEASE_TIMING;
    /** Called once another process has taken over (lease.ts); the process should then exit. */
    onFenced?: () => void;
}

export type Handler = (req: IncomingMessage, res: ServerResponse) => Promise<void>;

export interface Started {
    relay: Relay;
    /** Serves at once: health only, and 503 for everything else until `ready`. */
    handler: Handler;
    /** Resolves once the relay holds its lease alone and has read its state; rejects if it cannot. */
    ready: Promise<void>;
    stop(): void;
}

/** Checks what must hold before serving, takes the lease, and builds the handler; the rest happens in `ready`. */
export async function startRelay(config: Config, store: Store, options: RelayOptions): Promise<Started> {
    const claimed = await store.has('owner.json');
    // §6: an unclaimed relay refuses to start without a well-formed setup code.
    if (!claimed && (config.setupCode === null || !isSetupCode(config.setupCode))) {
        throw new ConfigError('SPRAVA_SETUP_CODE is required until the relay is claimed: 44 characters, as `openssl rand -base64 32` prints.');
    }
    const timing = options.lease ?? LEASE_TIMING;
    const { lease } = await Lease.take(store, options.log, timing, options.onFenced);
    const timers: NodeJS.Timeout[] = [];
    const relay: Relay = {
        config,
        store: withIntents(lease.fenceStore()),
        log: options.log,
        lock: new Mutex(),
        now: options.now ?? Date.now,
        claimed,
        repeat(ms, name, work) {
            const timer = setInterval(() => void work().catch(() => options.log.event('error', { kind: name })), ms);
            timer.unref();
            timers.push(timer);
        },
    };
    let isReady = false;
    const ready = (async () => {
        // Whatever an earlier process began writing has ended before this one reads anything (lease.ts).
        // Always, even when no earlier lease was listed: another process may be starting at the same moment, and
        // after the wait each sees the other's lease and only the higher one goes on.
        await sleep(timing.warmupMs);
        await lease.check();
        await lease.assertHeld();
        relay.claimed = await relay.store.has('owner.json');
        await lease.retireEarlier();
        isReady = true;
        options.log.event('ready');
    })();
    const routes: Route[] = [health(relay)];
    const handler = createHandler({
        routes,
        webOrigin: config.webOrigin,
        log: options.log,
        authenticate: async (): Promise<Principal | null> => null,
        isClaimed: () => relay.claimed,
        isReady: () => isReady && !lease.fenced,
        ...(options.bodyTimeoutMs === undefined ? {} : { bodyTimeoutMs: options.bodyTimeoutMs }),
    });
    return {
        relay,
        handler,
        ready,
        stop: () => {
            lease.stop();
            for (const timer of timers) clearInterval(timer);
        },
    };
}

/** §7.2: the protocol, whether the relay is claimed, and its instance; nothing else. */
function health(relay: Relay): Route {
    return {
        method: 'GET',
        path: '/v0/health',
        access: ['public'],
        browser: true,
        unclaimed: true,
        handle: async () => ({ status: 200, json: { protocol: 0, claimed: relay.claimed, instance: relay.config.instance } }),
    };
}
