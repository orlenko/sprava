// Claiming the relay (companion-v0 §6): the one owner, fixed once with the deployer's setup code.
import { isHashHex, sameBytes, sameSecret, sha256Hex } from './encoding.ts';
import { HttpError, type Route } from './http.ts';
import { OWNER } from './layout.ts';
import { SlidingWindow, sleep } from './limits.ts';
import type { Relay } from './relay.ts';
import { Mutex, writeOnce } from './store/store.ts';

/** §6 step 1: at most 10 claims a second, one at a time; a claim that waited 5 seconds is 503. */
export const CLAIM_TIMING = { intervalMs: 100, maxWaitMs: 5000, failureWindowMs: 600_000, failureDelayMs: 2000 };

export function claimRoute(relay: Relay, timing = CLAIM_TIMING): Route {
    const pacer = new Mutex();
    const failures = new SlidingWindow(timing.failureWindowMs);
    let lastStart = -Infinity;
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
            const record = new Uint8Array(Buffer.from(`{"owner_token_sha256":"${hash}"}`, 'utf8'));
            const arrived = performance.now();
            const outcome = await pacer.run(async () => {
                const wait = Math.max(0, lastStart + timing.intervalMs - performance.now());
                if (performance.now() + wait - arrived > timing.maxWaitMs) return 'busy';
                await sleep(wait);
                lastStart = performance.now();
                return decide(relay, code, hash, record, call.address, failures);
            });
            if (outcome === 'busy') throw new HttpError(503, 'The relay is busy; try again.', { 'Retry-After': '1' });
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

async function decide(relay: Relay, code: string, hash: string, record: Uint8Array, address: string, failures: SlidingWindow): Promise<'claimed' | 'taken' | 'wrong' | 'throttled'> {
    // Step 2: already claimed. 204 only for a retry of the claim that won.
    const existing = await relay.store.get(OWNER);
    if (existing !== null) return sameBytes(existing, record) ? 'claimed' : 'taken';
    // Step 3: the code first, so a correct code is never refused because of failures.
    if (!sameSecret(sha256Hex(code), sha256Hex(relay.config.setupCode ?? ''))) {
        // Step 4: failures per client address over the last 10 minutes.
        return failures.hit(address, relay.now()) > 5 ? 'throttled' : 'wrong';
    }
    // Step 5: create if absent, under the creation lock.
    const result = await relay.lock.run(() => writeOnce(relay.store, OWNER, record));
    if (result === 'different') return 'taken';
    relay.ownerHash = hash;
    relay.log.event('claimed');
    return 'claimed';
}
