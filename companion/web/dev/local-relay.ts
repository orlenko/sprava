// A relay for local development and tests: the relay's own code, run in this process over a fresh local folder,
// listening on localhost only. Never built into dist/. Its instance and setup code are random for each start.
import { randomBytes } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readConfig } from '../../relay/src/config.ts';
import { jsonLog } from '../../relay/src/log.ts';
import { startRelay } from '../../relay/src/relay.ts';
import { FsStore } from '../../relay/src/store/fs.ts';
import { scoped } from '../../relay/src/store/store.ts';

export interface LocalRelay {
    /** `http://localhost:<port>`, the form a pairing link carries. */
    origin: string;
    setupCode: string;
    folder: string;
    close(): Promise<void>;
}

/**
 * Starts a relay that accepts browser calls from `webOrigin` only. Port 0 picks a free one. Passing the port,
 * folder, instance and setup code of an earlier start brings the same relay back after `close`, as a restart would.
 */
export async function startLocalRelay(options: { webOrigin: string; port?: number; folder?: string;
    instance?: string; setupCode?: string; log?: (line: string) => void }): Promise<LocalRelay & { instance: string }> {
    const owned = options.folder === undefined;
    const folder = options.folder ?? await mkdtemp(join(tmpdir(), 'sprava-relay-dev-'));
    const instance = options.instance ?? randomBytes(16).toString('hex'), setupCode = options.setupCode ?? randomBytes(32).toString('base64');
    const config = readConfig({ SPRAVA_INSTANCE: instance, SPRAVA_SETUP_CODE: setupCode,
        SPRAVA_WEB_ORIGIN: options.webOrigin, SPRAVA_STORAGE: `fs:${folder}` });
    // One process owns the folder, so it needs none of the warm-up that guards a host running two (§7.9). The
    // relay's own timers do not keep a process alive, so this one does until the relay is ready.
    const keepAlive = setInterval(() => {}, 1000);
    const started = await (async () => {
        const relay = await startRelay(config, scoped(new FsStore(folder), instance),
            { log: jsonLog(options.log ?? (() => {})), lease: { checkMs: 1000, warmupMs: 0 } });
        await relay.ready;
        return relay;
    })().finally(() => clearInterval(keepAlive));
    // "localhost" may resolve to either loopback address; listen on both, and on nothing else.
    const servers: Server[] = [];
    const listen = (host: string, port: number) => new Promise<number>((resolve, reject) => {
        const server = createServer({ requestTimeout: 65_000 }, (req, res) => void started.handler(req, res));
        server.once('error', reject);
        server.listen(port, host, () => { servers.push(server); resolve((server.address() as AddressInfo).port); });
    });
    const port = await listen('127.0.0.1', options.port ?? 0);
    await listen('::1', port).catch(() => {}); // a machine without IPv6 loopback still has the first
    return { origin: `http://localhost:${port}`, setupCode, folder, instance,
        async close() {
            started.stop();
            await Promise.all(servers.map(server => new Promise<void>(resolve => {
                server.close(() => resolve()); server.closeAllConnections();
            })));
            if (owned) await rm(folder, { recursive: true, force: true });
        } };
}
