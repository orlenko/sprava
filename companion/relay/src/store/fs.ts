// A store in a local folder, for development and tests (companion-v0 §13, `SPRAVA_STORAGE=fs:<dir>`).
import { randomBytes } from 'node:crypto';
import { link, mkdir, open, readdir, readFile, rename, unlink } from 'node:fs/promises';
import { dirname, join, relative, sep } from 'node:path';
import type { Store } from './store.ts';

const TEMP = '.tmp-';

export class FsStore implements Store {
    readonly root: string;
    readonly #syncDir: (dir: string) => Promise<void>;

    /** `syncDir` is for tests that watch the order of writes and folder syncs; it defaults to fsync. */
    constructor(root: string, options: { syncDir?: (dir: string) => Promise<void> } = {}) {
        this.root = root;
        this.#syncDir = options.syncDir ?? fsyncDir;
    }

    async get(key: string): Promise<Uint8Array | null> {
        try {
            return new Uint8Array(await readFile(this.#path(key)));
        } catch (error) {
            if (isMissing(error)) return null;
            throw error;
        }
    }

    async has(key: string): Promise<boolean> {
        return (await this.get(key)) !== null;
    }

    // Every write is durable before it is acknowledged: the file is synced before it gets its name, and the folder
    // after, since syncing a file does not persist its directory entry (as AtomicFile does on the Mac side).
    async put(key: string, body: Uint8Array): Promise<void> {
        const temp = await this.#writeTemp(key, body);
        try {
            await rename(temp, this.#path(key));
        } catch (error) {
            await unlink(temp).catch(() => undefined);
            throw error;
        }
        await this.#syncDir(dirname(this.#path(key)));
    }

    /** §6 step 5: a temporary file in the same folder, linked to the final name, which fails if it exists. */
    async putIfAbsent(key: string, body: Uint8Array): Promise<boolean> {
        const temp = await this.#writeTemp(key, body);
        let created: boolean;
        try {
            await link(temp, this.#path(key));
            created = true;
        } catch (error) {
            if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error;
            created = false;
        } finally {
            await unlink(temp).catch(() => undefined);
        }
        await this.#syncDir(dirname(this.#path(key)));
        return created;
    }

    async delete(key: string): Promise<void> {
        try {
            await unlink(this.#path(key));
        } catch (error) {
            if (isMissing(error)) return;
            throw error;
        }
        await this.#syncDir(dirname(this.#path(key)));
    }

    async list(prefix: string): Promise<string[]> {
        // A prefix is plain segments too; only its last may be empty or partial.
        if (prefix.split('/').slice(0, -1).some((s) => s === '' || s === '.' || s === '..')) throw new Error('invalid store prefix');
        const slash = prefix.lastIndexOf('/');
        const base = slash < 0 ? '' : prefix.slice(0, slash + 1);
        const keys: string[] = [];
        await this.#walk(base, prefix, keys);
        return keys.sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
    }

    async #walk(folder: string, prefix: string, keys: string[]): Promise<void> {
        let entries;
        try {
            entries = await readdir(join(this.root, folder), { withFileTypes: true });
        } catch (error) {
            if (isMissing(error) || (error as NodeJS.ErrnoException).code === 'ENOTDIR') return;
            throw error;
        }
        for (const entry of entries) {
            if (entry.name.startsWith(TEMP)) continue;
            const key = folder + entry.name;
            if (entry.isDirectory()) {
                if ((key + '/').startsWith(prefix) || prefix.startsWith(key + '/')) await this.#walk(key + '/', prefix, keys);
            } else if (key.startsWith(prefix)) {
                keys.push(key);
            }
        }
    }

    async #writeTemp(key: string, body: Uint8Array): Promise<string> {
        const folder = dirname(this.#path(key));
        const first = await mkdir(folder, { recursive: true });
        if (first !== undefined) {
            // New folders are entries in their parents: each parent is synced, from the first one made down.
            for (let dir = first; ; dir = join(dir, relative(dir, folder).split(sep)[0]!)) {
                await this.#syncDir(dirname(dir));
                if (dir === folder) break;
            }
        }
        const temp = join(folder, TEMP + randomBytes(8).toString('hex'));
        const file = await open(temp, 'wx');
        try {
            await file.writeFile(body);
            await file.sync();
            await file.close();
        } catch (error) {
            await file.close().catch(() => undefined);
            await unlink(temp).catch(() => undefined);
            throw error;
        }
        return temp;
    }

    /** Keys are relative paths of plain segments; anything else is a programming error. */
    #path(key: string): string {
        const segments = key.split('/');
        if (segments.some((s) => s === '' || s === '.' || s === '..' || s.startsWith(TEMP))) {
            throw new Error('invalid store key');
        }
        return join(this.root, ...segments);
    }
}

async function fsyncDir(dir: string): Promise<void> {
    const handle = await open(dir, 'r');
    try {
        await handle.sync();
    } finally {
        await handle.close();
    }
}

function isMissing(error: unknown): boolean {
    const code = (error as NodeJS.ErrnoException).code;
    return code === 'ENOENT' || code === 'ENOTDIR';
}
