// Claiming the relay (companion-v0 §6): the one owner, fixed once with the deployer's setup code.
import { isHashHex, sameSecret, sha256Hex } from './encoding.ts';
import { HttpError, type Route } from './http.ts';
import { CLAIMS, OWNER, ownerRecord } from './layout.ts';
import { SlidingWindow, sleep } from './limits.ts';
import type { Relay } from './relay.ts';
import { Mutex, writeOnce } from './store/store.ts';

/** §6 step 1: at most 10 claims a second, one at a time; a claim that waited 5 seconds is 503. */
export const CLAIM_TIMING = { intervalMs: 100, maxWaitMs: 5000, failureWindowMs: 600_000, failureDelayMs: 2000 };

export function claimRoute(relay: Relay, timing = CLAIM_TIMING): Route {
    const pacer = new Mutex();
    const failures = new SlidingWindow(timing.failureWindowMs, 5);
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
            const record = ownerRecord(hash);
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
    // Step 2: already claimed. Once this process knows its owner, nothing in storage changes that: a vanished or
    // unreadable record never makes a claimed relay claimable again.
    if (relay.ownerHash !== null) return relay.ownerHash === hash ? 'claimed' : 'taken';
    const decided = await claimsIn(relay);
    if (decided.length > 0) {
        // A claim that landed after this process started (a write begun before a restart): a retry of it is that
        // claim, and this process adopts it; any other is refused.
        if (decided.length !== 1 || decided[0] !== hash) return 'taken';
        return (await relay.lock.run(() => writeOnce(relay.store, OWNER, record))) === 'different' ? 'taken' : adopt(relay, hash);
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
