// Runs a relay in this process on a free port, over a fresh local folder, for the endpoint tests.
import { mkdtemp } from 'node:fs/promises';
import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readConfig } from '../src/config.ts';
import { jsonLog } from '../src/log.ts';
import { startRelay, type Handler, type Relay } from '../src/relay.ts';
import { FsStore } from '../src/store/fs.ts';
import { scoped, type Store } from '../src/store/store.ts';

export const WEB_ORIGIN = 'https://companion.example.org';
export const INSTANCE = '0123456789abcdef0123456789abcdef';
export const SETUP_CODE = 'q83vEjRWeJCrze8SNFZ4kKvN7xI0VniQq83vEjRWeJA=';

export interface TestRelay {
    url: string;
    relay: Relay;
    /** The whole folder, unscoped. */
    raw: Store;
    logs: string[];
    ready: Promise<void>;
    close(): Promise<void>;
}

/** Tests take leases that are checked often and need no wait unless they ask for one. */
export const TEST_LEASE = { checkMs: 50, warmupMs: 0 };

export async function serve(handler: Handler): Promise<{ url: string; server: Server }> {
    const server = createServer((req, res) => void handler(req, res));
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    server.unref(); // a failed test that never closes it must not keep the run alive
    return { url: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, server };
}

export interface TestOptions {
    raw?: Store;
    env?: Record<string, string>;
    now?: () => number;
    lease?: { checkMs: number; warmupMs: number };
    /** False to get the relay while it is still warming up. */
    waitReady?: boolean;
}

export async function startTestRelay(options: TestOptions = {}): Promise<TestRelay> {
    const raw = options.raw ?? new FsStore(await mkdtemp(join(tmpdir(), 'sprava-relay-')));
    const config = readConfig({
        SPRAVA_INSTANCE: INSTANCE,
        SPRAVA_WEB_ORIGIN: WEB_ORIGIN,
        SPRAVA_SETUP_CODE: SETUP_CODE,
        SPRAVA_STORAGE: 'fs:/unused',
        ...options.env,
    });
    const logs: string[] = [];
    const started = await startRelay(config, scoped(raw, INSTANCE), {
        log: jsonLog((line) => logs.push(line)),
        lease: options.lease ?? TEST_LEASE,
        ...(options.now ? { now: options.now } : {}),
    });
    if (options.waitReady !== false) await started.ready;
    const { url, server } = await serve(started.handler);
    return {
        url,
        relay: started.relay,
        raw,
        logs,
        ready: started.ready,
        close: () => {
            started.stop();
            return new Promise((resolve) => server.close(() => resolve()));
        },
    };
}
