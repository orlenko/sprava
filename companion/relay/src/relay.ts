// The relay: its shared state, what it checks before serving, and its routes (companion-v0 §7).
import type { IncomingMessage, ServerResponse } from 'node:http';
import { ConfigError, isSetupCode, type Config } from './config.ts';
import { createHandler, type Principal, type Route } from './http.ts';
import type { Log } from './log.ts';
import { Mutex, type Store } from './store/store.ts';

export interface Relay {
    readonly config: Config;
    /** The store, already scoped to `SPRAVA_INSTANCE/` (§7.8). */
    readonly store: Store;
    readonly log: Log;
    /** §6 step 5: claims, pairing joins, object and request creation take this one lock. */
    readonly lock: Mutex;
    now(): number;
    claimed: boolean;
}

export interface RelayOptions {
    log: Log;
    now?: () => number;
    bodyTimeoutMs?: number;
}

export type Handler = (req: IncomingMessage, res: ServerResponse) => Promise<void>;

/** Checks what must hold before serving, then builds the request handler. */
export async function startRelay(config: Config, store: Store, options: RelayOptions): Promise<{ relay: Relay; handler: Handler }> {
    const relay: Relay = {
        config,
        store,
        log: options.log,
        lock: new Mutex(),
        now: options.now ?? Date.now,
        claimed: await store.has('owner.json'),
    };
    // §6: an unclaimed relay refuses to start without a well-formed setup code.
    if (!relay.claimed && (config.setupCode === null || !isSetupCode(config.setupCode))) {
        throw new ConfigError('SPRAVA_SETUP_CODE is required until the relay is claimed: 44 characters, as `openssl rand -base64 32` prints.');
    }
    const routes: Route[] = [health(relay)];
    const handler = createHandler({
        routes,
        webOrigin: config.webOrigin,
        log: options.log,
        authenticate: async (): Promise<Principal | null> => null,
        isClaimed: () => relay.claimed,
        ...(options.bodyTimeoutMs === undefined ? {} : { bodyTimeoutMs: options.bodyTimeoutMs }),
    });
    return { relay, handler };
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
