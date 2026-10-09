// The relay: its shared state, what it checks before serving, and its routes (companion-v0 §7).
import type { IncomingMessage, ServerResponse } from 'node:http';
import { CLAIM_TIMING, claimRoute } from './claim.ts';
import { ConfigError, isSetupCode, type Config } from './config.ts';
import { deviceRoutes, Devices } from './devices.ts';
import { isHashHex } from './encoding.ts';
import { createHandler, type Route } from './http.ts';
import { OWNER, readRecord } from './layout.ts';
import { Lease, LEASE_TIMING, sleep } from './lease.ts';
import type { Log } from './log.ts';
import { repairAtStart } from './startup.ts';
import { Mutex, type Store } from './store/store.ts';

export interface Relay {
    readonly config: Config;
    /** The store, already scoped to `SPRAVA_INSTANCE/` (§7.8). */
    readonly store: Store;
    readonly log: Log;
    /** §6 step 5: claims, pairing joins, object and request creation take this one lock. */
    readonly lock: Mutex;
    now(): number;
    /** The owner token's hash once the relay is claimed (§6), else null. */
    ownerHash: string | null;
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
    claimTiming?: typeof CLAIM_TIMING;
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

async function readOwner(store: Store): Promise<string | null> {
    const owner = readRecord<{ owner_token_sha256: unknown }>(await store.get(OWNER));
    if (owner === null) return null;
    if (!isHashHex(owner.owner_token_sha256)) throw new Error('The owner record is unreadable.');
    return owner.owner_token_sha256;
}

/** Checks what must hold before serving, takes the lease, and builds the handler; the rest happens in `ready`. */
export async function startRelay(config: Config, store: Store, options: RelayOptions): Promise<Started> {
    const ownerHash = await readOwner(store);
    // §6: an unclaimed relay refuses to start without a well-formed setup code.
    if (ownerHash === null && (config.setupCode === null || !isSetupCode(config.setupCode))) {
        throw new ConfigError('SPRAVA_SETUP_CODE is required until the relay is claimed: 44 characters, as `openssl rand -base64 32` prints.');
    }
    const timing = options.lease ?? LEASE_TIMING;
    const { lease } = await Lease.take(store, options.log, timing, options.onFenced);
    const timers: NodeJS.Timeout[] = [];
    const relay: Relay = {
        config,
        store: lease.fenceStore(),
        log: options.log,
        lock: new Mutex(),
        now: options.now ?? Date.now,
        ownerHash,
        repeat(ms, name, work) {
            const timer = setInterval(() => void work().catch(() => options.log.event('error', { kind: name })), ms);
            timer.unref();
            timers.push(timer);
        },
    };
    const devices = new Devices(relay);
    let isReady = false;
    const ready = (async () => {
        // Whatever an earlier process began writing has ended before this one reads anything (lease.ts).
        // Always, even when no earlier lease was listed: another process may be starting at the same moment, and
        // after the wait each sees the other's lease and only the higher one goes on.
        await sleep(timing.warmupMs);
        await lease.check();
        await lease.assertHeld();
        relay.ownerHash = await readOwner(relay.store);
        await repairAtStart(relay, devices);
        await devices.load();
        await lease.retireEarlier();
        isReady = true;
        options.log.event('ready');
    })();
    const routes: Route[] = [health(relay), claimRoute(relay, options.claimTiming), ...deviceRoutes(relay, devices)];
    const handler = createHandler({
        routes,
        webOrigin: config.webOrigin,
        log: options.log,
        authenticate: (token) => devices.authenticate(token),
        isClaimed: () => relay.ownerHash !== null,
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
        handle: async () => ({ status: 200, json: { protocol: 0, claimed: relay.ownerHash !== null, instance: relay.config.instance } }),
    };
}
