// Starts the relay from its environment (companion-v0 §13). One instance only (§7).
import { createServer } from 'node:http';
import { ConfigError, readConfig, type Config } from './config.ts';
import { InconsistentStore } from './lease.ts';
import { jsonLog } from './log.ts';
import { startRelay } from './relay.ts';
import { FsStore } from './store/fs.ts';
import { S3Store } from './store/s3.ts';
import { scoped, type Store } from './store/store.ts';

function openStore(config: Config): Store {
    return config.storage.kind === 'fs' ? new FsStore(config.storage.dir) : new S3Store(config.storage.s3);
}

async function main(): Promise<void> {
    const log = jsonLog((line) => process.stdout.write(line + '\n'));
    try {
        const config = readConfig(process.env);
        let stop = (): void => {};
        const started = await startRelay(config, scoped(openStore(config), config.instance), { log, onFenced: () => stop() });
        const server = createServer({ requestTimeout: 65_000 }, (req, res) => void started.handler(req, res));
        server.listen(config.port, () => log.event('listening', { port: config.port, storage: config.storage.kind }));
        stop = (): void => {
            started.stop();
            server.close(() => process.exit(0));
            server.closeIdleConnections();
            setTimeout(() => process.exit(0), 10_000).unref();
        };
        process.on('SIGTERM', stop);
        process.on('SIGINT', stop);
        started.ready.catch(() => {
            process.stderr.write('sprava-relay: The relay could not read its state; it stops.\n');
            process.exit(1);
        });
    } catch (error) {
        // A configuration error is a plain sentence naming the variable, never its value.
        const sentence = error instanceof ConfigError || error instanceof InconsistentStore ? error.message : 'The relay could not start.';
        process.stderr.write(`sprava-relay: ${sentence}\n`);
        process.exit(1);
    }
}

await main();
