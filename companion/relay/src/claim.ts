// Claiming the relay (companion-v0 §6): the one owner, fixed once with the deployer's setup code.
import { isHashHex, sameSecret, sha256Hex } from './encoding.ts';
import { HttpError, type Route } from './http.ts';
import { CLAIMS, OWNER, ownerRecord } from './layout.ts';
import { SlidingWindow, sleep } from './limits.ts';
import type { Relay } from './relay.ts';
import { writeOnce } from './store/store.ts';

/** §6 step 1: at most 10 claims a second, one at a time; a claim that waited 5 seconds is 503. */
export const CLAIM_TIMING = { intervalMs: 100, maxWaitMs: 5000, failureWindowMs: 600_000, failureDelayMs: 2000 };

export function claimRoute(relay: Relay, timing = CLAIM_TIMING): Route {
    const failures = new SlidingWindow(timing.failureWindowMs, 5);
    const pacer = new ClaimPacer(timing);
    return {
        method: 'POST',
        path: '/v0/claim',
        access: ['public'],
        browser: false,
        unclaimed: true,
        body: { kind: 'json', limit: 1024 },
        async handle(call) {
            const code = call.json.setup_code;
            const hash = call.json.owner_token_sha256;
            if (typeof code !== 'string' || !isHashHex(hash)) {
                throw new HttpError(400, 'A claim needs a setup code and the owner token hash in lowercase hex.');
            }
            // §6: the owner record is derived from the body and nothing else, so every retry writes the same bytes.
            const record = ownerRecord(hash);
            const done = await pacer.turn(call.signal);
            if (done === null) throw new HttpError(503, 'The relay is busy; try again.', { 'Retry-After': '1' });
            let outcome: Awaited<ReturnType<typeof decide>>;
            try {
                outcome = await decide(relay, code, hash, record, call.address, failures);
            } finally {
                done();
            }
            if (outcome === 'throttled') {
                // §6 step 4: the delay holds only this response, not the processing of other claims.
                await sleep(timing.failureDelayMs);
                throw new HttpError(429, 'Too many wrong setup codes from this address; wait and try again.');
            }
            if (outcome === 'wrong') throw new HttpError(403, 'The setup code is not right.');
            if (outcome === 'taken') throw new HttpError(409, 'This relay is already claimed.');
            return { status: 204 };
        },
    };
}

/**
 * §6 step 1: claims run one at a time, at most one start per interval. The queue holds at most as many claims as
 * can start within the wait limit; each queued claim has its own deadline, and leaves the queue when it passes or
 * its client goes away, so it is answered 503 then and never runs later, however long the claim in progress takes.
 */
class ClaimPacer {
    readonly #timing: typeof CLAIM_TIMING;
    readonly #queue: { start: () => void }[] = [];
    #busy = false;
    #lastStart = -Infinity;

    constructor(timing: typeof CLAIM_TIMING) {
        this.#timing = timing;
    }

    /** Waits for this claim's turn; resolves with the function that ends it, or null when it must be refused. */
    turn(signal: AbortSignal): Promise<(() => void) | null> {
        const limit = Math.max(1, Math.floor(this.#timing.maxWaitMs / this.#timing.intervalMs));
        if (this.#queue.length >= limit || signal.aborted) return Promise.resolve(null);
        return new Promise((resolve) => {
            const entry = {
                start: () => {
                    cleanup();
                    resolve(() => {
                        this.#busy = false;
                        this.#pump();
                    });
                },
            };
            const leave = (): void => {
                const at = this.#queue.indexOf(entry);
                if (at < 0) return;
                this.#queue.splice(at, 1);
                cleanup();
                resolve(null);
            };
            const timer = setTimeout(leave, this.#timing.maxWaitMs);
            const cleanup = (): void => {
                clearTimeout(timer);
                signal.removeEventListener('abort', leave);
            };
            signal.addEventListener('abort', leave);
            this.#queue.push(entry);
            this.#pump();
        });
    }

    #pump(): void {
        if (this.#busy || this.#queue.length === 0) return;
        this.#busy = true;
        const wait = Math.max(0, this.#lastStart + this.#timing.intervalMs - performance.now());
        setTimeout(() => {
            const next = this.#queue.shift();
            if (next === undefined) {
                this.#busy = false;
                return;
            }
            this.#lastStart = performance.now();
            next.start();
        }, wait);
    }
}

async function decide(relay: Relay, code: string, hash: string, record: Uint8Array, address: string, failures: SlidingWindow): Promise<'claimed' | 'taken' | 'wrong' | 'throttled'> {
    // Step 2: already claimed. Once this process knows its owner, nothing in storage changes that: a vanished or
    // unreadable record never makes a claimed relay claimable again.
    if (relay.ownerHash !== null) return relay.ownerHash === hash ? 'claimed' : 'taken';
    const decided = await claimsIn(relay);
    if (decided.length > 0) {
        // A claim that landed after this process started (a write begun before a restart): a retry of it is that
        // claim, and this process adopts it; any other is refused.
        if (decided.length !== 1 || decided[0] !== hash) return 'taken';
        // Invariant 2: the claim found may be one whose write failed before it was durable; writeOnce makes it so.
        return relay.lock.run(async () => {
            if ((await writeOnce(relay.store, `${CLAIMS}${hash}`, record)) === 'different') return 'taken';
            return (await writeOnce(relay.store, OWNER, record)) === 'different' ? 'taken' : adopt(relay, hash);
        });
    }
    // Step 3: the code first, so a correct code is never refused because of failures. There is no code to match
    // once the variable is gone, and an empty one never matches.
    const configured = relay.config.setupCode;
    if (configured === null || !sameSecret(sha256Hex(code), sha256Hex(configured))) {
        // Step 4: failures per client address over the last 10 minutes; past the fifth, nothing more is kept.
        return failures.admit(address, relay.now()) ? 'wrong' : 'throttled';
    }
    // Step 5: the decision first, named by its content, then the owner record, under the creation lock.
    return relay.lock.run(async () => {
        if ((await writeOnce(relay.store, `${CLAIMS}${hash}`, record)) === 'different') return 'taken';
        const now = await claimsIn(relay);
        if (now.length !== 1 || now[0] !== hash) {
            relay.log.event('claim-conflict');
            return 'taken';
        }
        return (await writeOnce(relay.store, OWNER, record)) === 'different' ? 'taken' : adopt(relay, hash);
    });
}

/** The claims decided in storage, by hash. */
async function claimsIn(relay: Relay): Promise<string[]> {
    return (await relay.store.list(CLAIMS)).map((key) => key.slice(CLAIMS.length));
}

function adopt(relay: Relay, hash: string): 'claimed' {
    relay.ownerHash = hash;
    relay.log.event('claimed');
    return 'claimed';
}
