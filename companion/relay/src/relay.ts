// The relay: its shared state, what it checks before serving, and its routes (companion-v0 §7).
import type { IncomingMessage, ServerResponse } from 'node:http';
import { CLAIM_TIMING, claimRoute } from './claim.ts';
import { ConfigError, isSetupCode, type Config } from './config.ts';
import { deviceRoutes, Devices } from './devices.ts';
import { isHashHex, sameBytes, sha256Hex } from './encoding.ts';
import { createHandler, type Route } from './http.ts';
import { OWNER, ownerRecord } from './layout.ts';
import { Lease, LEASE_TIMING, sleep } from './lease.ts';
import type { Log } from './log.ts';
import { repairAtStart } from './startup.ts';
import { INTENTS, KeyedMutex, Mutex, setWriter, writeOnce, type Store } from './store/store.ts';

export interface Relay {
    readonly config: Config;
    /** The store, already scoped to `SPRAVA_INSTANCE/` (§7.8). */
    readonly store: Store;
    readonly log: Log;
    /**
     * §6 step 5: the creation lock, for claims, pairing joins and object writes. Lock order (devices.ts): a device's
     * lock first, then this one; code holding this one never takes a device lock.
     */
    readonly lock: Mutex;
    /** One lock per device, held for every action of the device and every change to it (devices.ts). */
    readonly deviceLocks: KeyedMutex;
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

export class ClaimConflict extends Error {}

/**
 * The owner, from its record (§6): none, or the hash it holds. Only a record that cannot be read, which nothing
 * the relay writes can produce, fails the start.
 */
async function readOwner(store: Store): Promise<string | null> {
    const owner = await store.get(OWNER);
    if (owner === null) return null;
    const hash = /^\{"owner_token_sha256":"([0-9a-f]{64})"\}$/.exec(Buffer.from(owner).toString('utf8'))?.[1];
    if (hash === undefined || !isHashHex(hash) || !sameBytes(owner, ownerRecord(hash))) {
        throw new ClaimConflict('The owner record is unreadable; start over with a new SPRAVA_INSTANCE and setup code.');
    }
    return hash;
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
    const fenced = lease.fenceStore();
    setWriter(fenced, lease.name);
    const relay: Relay = {
        config,
        store: fenced,
        log: options.log,
        lock: new Mutex(),
        deviceLocks: new KeyedMutex(),
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
        // The owner record made durable (a write may have failed after it became readable). Every claim intent but
        // the owner's is cleared: after the warm-up, none of them can still be followed by its bytes (§7.9), so
        // none can block a claim; with no owner, all of them go.
        if (relay.ownerHash !== null) await writeOnce(relay.store, OWNER, ownerRecord(relay.ownerHash));
        const kept = relay.ownerHash === null ? null : `${INTENTS}${OWNER}/${sha256Hex(ownerRecord(relay.ownerHash))}`;
        for (const intent of await relay.store.list(`${INTENTS}${OWNER}/`)) if (intent !== kept) await relay.store.delete(intent);
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
        guard: (principal, action, signal) => devices.guard(principal, action, signal),
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
