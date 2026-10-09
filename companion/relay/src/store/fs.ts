// A store in a local folder, for development and tests (companion-v0 §13, `SPRAVA_STORAGE=fs:<dir>`).
//
// Durability: nothing is acknowledged before it would survive a power loss. A file is synced before it gets its
// name, and the folder after, since syncing a file does not persist its directory entry (as AtomicFile does on the
// Mac side). A folder counts as durable only once its own entry has been synced in its parent, which is tried
// again on every write until it succeeds, so a failed sync is never forgotten.
//
// Names: keys are case-sensitive, and folders often are not (APFS by default). Each upper-case letter is stored as
// `^` and its lower-case form, so two keys that differ only in case never share a file.
import { randomBytes } from 'node:crypto';
import { link, mkdir, open, readdir, readFile, rename, unlink } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import type { Store } from './store.ts';

const TEMP = '.tmp-';
const SEGMENT = /^[A-Za-z0-9._-]+$/;

export class FsStore implements Store {
    readonly root: string;
    readonly #syncDir: (dir: string) => Promise<void>;
    /** Folders whose entries are known durable, up to a bound; one not in it is synced in its parent again. */
    readonly #durable = new Set<string>();

    /** `syncDir` is for tests that watch the order of writes and folder syncs; it defaults to fsync. */
    constructor(root: string, options: { syncDir?: (dir: string) => Promise<void> } = {}) {
        // Normalized, so a trailing slash or a dot segment cannot keep the folder walk from ever reaching it.
        this.root = resolve(root);
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

    /** Makes an object that exists durable: its folders, the file and its entry are synced again. */
    async sync(key: string): Promise<void> {
        const path = this.#path(key);
        await this.#ensureFolder(dirname(path));
        const file = await open(path, 'r');
        try {
            await file.sync();
        } finally {
            await file.close();
        }
        await this.#syncDir(dirname(path));
    }

    /**
     * A deletion is acknowledged only once durable: the folder is synced even when the file is already gone, since
     * an earlier attempt may have removed it and then failed to sync. A folder that does not exist held nothing.
     */
    async delete(key: string): Promise<void> {
        try {
            await unlink(this.#path(key));
        } catch (error) {
            if (!isMissing(error)) throw error;
        }
        try {
            await this.#syncDir(dirname(this.#path(key)));
        } catch (error) {
            if (!isMissing(error)) throw error;
        }
    }

    async list(prefix: string): Promise<string[]> {
        // A prefix is plain segments too; only its last may be empty or partial.
        const segments = prefix.split('/');
        if (segments.slice(0, -1).some((s) => !SEGMENT.test(s) || s === '.' || s === '..') || !/^[A-Za-z0-9._-]*$/.test(segments.at(-1)!)) {
            throw new Error('invalid store prefix');
        }
        const base = segments.slice(0, -1);
        const keys: string[] = [];
        await this.#walk(join(this.root, ...base.map(encode)), base.map((s) => s + '/').join(''), prefix, keys);
        return keys.sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
    }

    async #walk(folder: string, keyFolder: string, prefix: string, keys: string[]): Promise<void> {
        let entries;
        try {
            entries = await readdir(folder, { withFileTypes: true });
        } catch (error) {
            if (isMissing(error)) return;
            throw error;
        }
        for (const entry of entries) {
            if (entry.name.startsWith(TEMP)) continue;
            const key = keyFolder + decode(entry.name);
            if (entry.isDirectory()) {
                if ((key + '/').startsWith(prefix) || prefix.startsWith(key + '/')) await this.#walk(join(folder, entry.name), key + '/', prefix, keys);
            } else if (key.startsWith(prefix)) {
                keys.push(key);
            }
        }
    }

    /** Every folder from the root down to `folder` exists, and its entry is durable in its parent. */
    async #ensureFolder(folder: string): Promise<void> {
        const chain: string[] = [];
        for (let dir = folder; dir !== this.root && !this.#durable.has(dir); dir = dirname(dir)) {
            if (dirname(dir) === dir) throw new Error('a store folder outside its root');
            chain.unshift(dir);
        }
        for (const dir of chain) {
            await mkdir(dir).catch((error: NodeJS.ErrnoException) => {
                if (error.code !== 'EEXIST') throw error;
            });
            await this.#syncDir(dirname(dir));
            if (this.#durable.size >= 100_000) this.#durable.clear();
            this.#durable.add(dir);
        }
    }

    async #writeTemp(key: string, body: Uint8Array): Promise<string> {
        const folder = dirname(this.#path(key));
        await this.#ensureFolder(folder);
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

    /** Keys are relative paths of plain ASCII segments; anything else is a programming error. */
    #path(key: string): string {
        const segments = key.split('/');
        if (segments.some((s) => !SEGMENT.test(s) || s === '.' || s === '..' || s.startsWith(TEMP))) {
            throw new Error('invalid store key');
        }
        return join(this.root, ...segments.map(encode));
    }
}

/** `A` is stored as `^a`, so names that differ only in case stay apart on a folder that ignores case. */
function encode(segment: string): string {
    return segment.replace(/[A-Z]/g, (c) => `^${c.toLowerCase()}`);
}

function decode(name: string): string {
    return name.replace(/\^([a-z])/g, (_, c: string) => c.toUpperCase());
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
