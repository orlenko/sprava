// The relay: its shared state, what it checks before serving, and its routes (companion-v0 §7).
import type { IncomingMessage, ServerResponse } from 'node:http';
import { CLAIM_TIMING, claimRoute, ownerIn, UnreadableOwner } from './claim.ts';
import { ConfigError, isSetupCode, type Config } from './config.ts';
import { deviceRoutes, Devices } from './devices.ts';
import { sha256Hex } from './encoding.ts';
import { createHandler, type Route } from './http.ts';
import { OWNERS, ownerRecord } from './layout.ts';
import { Lease, LEASE_TIMING, sleep } from './lease.ts';
import type { Log } from './log.ts';
import { objects } from './objects.ts';
import { pairings } from './pairings.ts';
import { requests } from './requests.ts';
import { repairAtStart } from './startup.ts';
import { KeyedMutex, Mutex, writeOnce, type Store } from './store/store.ts';

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
    /** This process's lease name (lease.ts), written where a choice must belong to one process. */
    readonly writer: string;
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

/** The owner (claim.ts, ownerIn); only an owner record that cannot be read fails the start. */
async function readOwner(store: Store): Promise<string | null> {
    try {
        return await ownerIn(store);
    } catch (error) {
        if (error instanceof UnreadableOwner) {
            throw new ClaimConflict('The owner record is unreadable; start over with a new SPRAVA_INSTANCE and setup code.');
        }
        throw error;
    }
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
        deviceLocks: new KeyedMutex(),
        writer: lease.name,
        now: options.now ?? Date.now,
        ownerHash,
        repeat(ms, name, work) {
            const timer = setInterval(() => void work().catch(() => options.log.event('error', { kind: name })), ms);
            timer.unref();
            timers.push(timer);
        },
    };
    const devices = new Devices(relay);
    const pairing = pairings(relay, devices);
    const mailbox = requests(relay, devices);
    const published = objects(relay, devices);
    let isReady = false;
    const ready = (async () => {
        // Whatever an earlier process began writing has ended before this one reads anything (lease.ts).
        // Always, even when no earlier lease was listed: another process may be starting at the same moment, and
        // after the wait each sees the other's lease and only the higher one goes on.
        await sleep(timing.warmupMs);
        await lease.check();
        await lease.assertHeld();
        relay.ownerHash = await readOwner(relay.store);
        // The owner record made durable (a write may have failed after it became readable). Claim intents are never
        // deleted: one binds the slot to its claim for good (README, accepted trade-off A).
        if (relay.ownerHash !== null) await relay.store.sync(`${OWNERS}${sha256Hex(ownerRecord(relay.ownerHash))}`);
        await repairAtStart(relay, devices);
        await devices.load();
        // §7.6, §7.8: each device's next ordinal is derived from what is stored, before serving.
        await mailbox.sweep();
        await lease.retireEarlier();
        // §7.3: pairings are deleted 10 minutes after they were made; a sweep each minute, and on every access.
        relay.repeat(60_000, 'pairing-sweep', pairing.sweep);
        relay.repeat(3_600_000, 'request-sweep', mailbox.sweep);
        relay.repeat(3_600_000, 'object-sweep', published.sweep);
        isReady = true;
        options.log.event('ready');
    })();
    const routes: Route[] = [
        health(relay),
        claimRoute(relay, options.claimTiming),
        ...deviceRoutes(relay, devices),
        ...pairing.routes,
        ...published.routes,
        ...mailbox.routes,
    ];
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
