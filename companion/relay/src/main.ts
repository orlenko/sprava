// Starts the relay from its environment (companion-v0 §13). One instance only (§7).
import { createServer } from 'node:http';
import { ConfigError, readConfig, type Config } from './config.ts';
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
        const { handler } = await startRelay(config, scoped(openStore(config), config.instance), { log });
        const server = createServer({ requestTimeout: 65_000 }, (req, res) => void handler(req, res));
        server.listen(config.port, () => log.event('listening', { port: config.port, storage: config.storage.kind }));
        const stop = (): void => {
            server.close(() => process.exit(0));
            server.closeIdleConnections();
            setTimeout(() => process.exit(0), 10_000).unref();
        };
        process.on('SIGTERM', stop);
        process.on('SIGINT', stop);
    } catch (error) {
        // A configuration error is a plain sentence naming the variable, never its value.
        const sentence = error instanceof ConfigError ? error.message : 'The relay could not start.';
        process.stderr.write(`sprava-relay: ${sentence}\n`);
        process.exit(1);
    }
}

await main();
