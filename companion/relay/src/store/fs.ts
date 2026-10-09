// A store in a local folder, for development and tests (companion-v0 §13, `SPRAVA_STORAGE=fs:<dir>`).
import { randomBytes } from 'node:crypto';
import { link, mkdir, open, readdir, readFile, rename, unlink } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import type { Store } from './store.ts';

const TEMP = '.tmp-';

export class FsStore implements Store {
    readonly root: string;

    constructor(root: string) {
        this.root = root;
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
        await rename(temp, this.#path(key));
    }

    /** §6 step 5: a temporary file in the same folder, linked to the final name, which fails if it exists. */
    async putIfAbsent(key: string, body: Uint8Array): Promise<boolean> {
        const temp = await this.#writeTemp(key, body);
        try {
            await link(temp, this.#path(key));
            return true;
        } catch (error) {
            if ((error as NodeJS.ErrnoException).code === 'EEXIST') return false;
            throw error;
        } finally {
            await unlink(temp).catch(() => undefined);
        }
    }

    async delete(key: string): Promise<void> {
        try {
            await unlink(this.#path(key));
        } catch (error) {
            if (!isMissing(error)) throw error;
        }
    }

    async list(prefix: string): Promise<string[]> {
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
        const path = this.#path(key);
        await mkdir(dirname(path), { recursive: true });
        const temp = join(dirname(path), TEMP + randomBytes(8).toString('hex'));
        const file = await open(temp, 'wx');
        try {
            await file.writeFile(body);
            await file.sync();
        } finally {
            await file.close();
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

function isMissing(error: unknown): boolean {
    const code = (error as NodeJS.ErrnoException).code;
    return code === 'ENOENT' || code === 'ENOTDIR';
}
