// The relay's configuration, read only from environment variables (companion-v0 §13). None has a default that
// points anywhere; a missing or malformed value stops the relay before it serves anything.

export type Storage = { kind: 'fs'; dir: string } | { kind: 's3'; s3: S3Config };

export interface S3Config {
    endpoint: string;
    region: string;
    bucket: string;
    accessKeyId: string;
    secretAccessKey: string;
}

export interface Config {
    instance: string;
    /** Checked again at start: required while the relay is unclaimed, ignored after (§6). */
    setupCode: string | null;
    webOrigin: string;
    storage: Storage;
    port: number;
}

export class ConfigError extends Error {}

type Env = Record<string, string | undefined>;

export function readConfig(env: Env): Config {
    const instance = required(env, 'SPRAVA_INSTANCE');
    if (!/^[0-9a-f]{32}$/.test(instance)) {
        throw new ConfigError('SPRAVA_INSTANCE must be 32 lowercase hex characters, as `openssl rand -hex 16` prints.');
    }
    const webOrigin = required(env, 'SPRAVA_WEB_ORIGIN');
    if (!isOrigin(webOrigin)) {
        throw new ConfigError('SPRAVA_WEB_ORIGIN must be an origin such as https://companion.example.org, with no path or trailing slash.');
    }
    const port = env.PORT === undefined || env.PORT === '' ? 8080 : Number(env.PORT);
    if (!Number.isInteger(port) || port < 1 || port > 65535 || !/^[0-9]+$/.test(env.PORT ?? '8080')) {
        throw new ConfigError('PORT must be a port number.');
    }
    const setupCode = env.SPRAVA_SETUP_CODE === undefined || env.SPRAVA_SETUP_CODE === '' ? null : env.SPRAVA_SETUP_CODE;
    return { instance, setupCode, webOrigin, storage: readStorage(env), port };
}

function readStorage(env: Env): Storage {
    const storage = required(env, 'SPRAVA_STORAGE');
    if (storage.startsWith('fs:')) {
        const dir = storage.slice(3);
        if (!dir.startsWith('/')) throw new ConfigError('SPRAVA_STORAGE=fs:<dir> needs an absolute directory.');
        return { kind: 'fs', dir };
    }
    if (storage !== 's3') throw new ConfigError('SPRAVA_STORAGE must be `s3` or `fs:<absolute directory>`.');
    const endpoint = required(env, 'S3_ENDPOINT');
    let url: URL;
    try {
        url = new URL(endpoint);
    } catch {
        throw new ConfigError('S3_ENDPOINT must be a URL such as https://region.storage.example.org.');
    }
    if (url.pathname !== '/' || url.search !== '' || !(url.protocol === 'https:' || isLocal(url))) {
        throw new ConfigError('S3_ENDPOINT must be an https URL with no path.');
    }
    return {
        kind: 's3',
        s3: {
            endpoint: url.origin,
            region: required(env, 'S3_REGION'),
            bucket: required(env, 'S3_BUCKET'),
            accessKeyId: required(env, 'S3_ACCESS_KEY_ID'),
            secretAccessKey: required(env, 'S3_SECRET_ACCESS_KEY'),
        },
    };
}

/** §6: exactly what `openssl rand -base64 32` prints: 44 standard base64 characters that decode to 32 bytes. */
export function isSetupCode(code: string): boolean {
    return /^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$/.test(code);
}

/** §5.1, §7.7: `https://host[:port]`, or `http://localhost[:port]` for development, with nothing after it. */
export function isOrigin(text: string): boolean {
    try {
        const url = new URL(text);
        return url.origin === text && (url.protocol === 'https:' || isLocal(url));
    } catch {
        return false;
    }
}

function isLocal(url: URL): boolean {
    return url.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
}

function required(env: Env, name: string): string {
    const value = env[name];
    if (value === undefined || value === '') throw new ConfigError(`${name} is required.`);
    return value;
}
