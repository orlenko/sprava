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
    close(): Promise<void>;
}

export async function serve(handler: Handler): Promise<{ url: string; server: Server }> {
    const server = createServer((req, res) => void handler(req, res));
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    return { url: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, server };
}

export async function startTestRelay(options: { raw?: Store; env?: Record<string, string>; now?: () => number } = {}): Promise<TestRelay> {
    const raw = options.raw ?? new FsStore(await mkdtemp(join(tmpdir(), 'sprava-relay-')));
    const config = readConfig({
        SPRAVA_INSTANCE: INSTANCE,
        SPRAVA_WEB_ORIGIN: WEB_ORIGIN,
        SPRAVA_SETUP_CODE: SETUP_CODE,
        SPRAVA_STORAGE: 'fs:/unused',
        ...options.env,
    });
    const logs: string[] = [];
    const { relay, handler } = await startRelay(config, scoped(raw, INSTANCE), {
        log: jsonLog((line) => logs.push(line)),
        ...(options.now ? { now: options.now } : {}),
    });
    const { url, server } = await serve(handler);
    return {
        url,
        relay,
        raw,
        logs,
        close: () => new Promise((resolve) => server.close(() => resolve())),
    };
}
