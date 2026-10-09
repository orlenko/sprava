// A store in an S3-compatible bucket (companion-v0 §13, `SPRAVA_STORAGE=s3`), signed with AWS Signature
// Version 4 using only node:crypto, and addressed path-style so any S3-compatible host works.
import { createHash, createHmac } from 'node:crypto';
import type { S3Config } from '../config.ts';
import type { Store } from './store.ts';

export class S3Error extends Error {
    readonly status: number;
    constructor(operation: string, status: number) {
        super(`S3 ${operation} failed with status ${status}`);
        this.name = 'S3Error';
        this.status = status;
    }
}

type Fetch = typeof fetch;

export class S3Store implements Store {
    readonly #config: S3Config;
    readonly #fetch: Fetch;
    readonly #now: () => Date;

    constructor(config: S3Config, options: { fetch?: Fetch; now?: () => Date } = {}) {
        this.#config = config;
        this.#fetch = options.fetch ?? fetch;
        this.#now = options.now ?? (() => new Date());
    }

    async get(key: string): Promise<Uint8Array | null> {
        const res = await this.#send('GET', key);
        if (res.status === 404) return null;
        if (res.status !== 200) throw new S3Error('GET', res.status);
        return new Uint8Array(await res.arrayBuffer());
    }

    async has(key: string): Promise<boolean> {
        const res = await this.#send('HEAD', key);
        if (res.status === 404) return false;
        if (res.status !== 200) throw new S3Error('HEAD', res.status);
        return true;
    }

    async put(key: string, body: Uint8Array): Promise<void> {
        const res = await this.#send('PUT', key, {}, body);
        if (res.status !== 200) throw new S3Error('PUT', res.status);
    }

    /** §6 step 5: `If-None-Match: *` as a second guard; a store that ignores it overwrites, so callers hold the lock. */
    async putIfAbsent(key: string, body: Uint8Array): Promise<boolean> {
        const res = await this.#send('PUT', key, {}, body, { 'if-none-match': '*' });
        if (res.status === 412) return false;
        if (res.status !== 200) throw new S3Error('PUT', res.status);
        return true;
    }

    /** A store that answered 200 to the write already holds it durably; this only verifies that it is there. */
    async sync(key: string): Promise<void> {
        if (!(await this.has(key))) throw new S3Error('HEAD', 404);
    }

    async delete(key: string): Promise<void> {
        const res = await this.#send('DELETE', key);
        if (res.status !== 204 && res.status !== 200 && res.status !== 404) throw new S3Error('DELETE', res.status);
    }

    async list(prefix: string): Promise<string[]> {
        const keys: string[] = [];
        let token: string | null = null;
        do {
            const query: Record<string, string> = { 'list-type': '2', prefix };
            if (token !== null) query['continuation-token'] = token;
            const res = await this.#send('GET', null, query);
            if (res.status !== 200) throw new S3Error('LIST', res.status);
            const xml = await res.text();
            for (const match of xml.matchAll(/<Contents>[\s\S]*?<Key>([\s\S]*?)<\/Key>[\s\S]*?<\/Contents>/g)) keys.push(unescapeXml(match[1]!));
            token = /<IsTruncated>true<\/IsTruncated>/.test(xml) ? unescapeXml(/<NextContinuationToken>([\s\S]*?)<\/NextContinuationToken>/.exec(xml)?.[1] ?? '') : null;
            if (token === '') throw new S3Error('LIST', 200);
        } while (token !== null);
        return keys;
    }

    /** One signed request, retried twice on a network error or a 5xx. */
    async #send(method: string, key: string | null, query: Record<string, string> = {}, body?: Uint8Array, extra: Record<string, string> = {}): Promise<Response> {
        const { endpoint, bucket } = this.#config;
        const path = '/' + [bucket, ...(key === null ? [] : key.split('/'))].map(uriEncode).join('/');
        const search = canonicalQuery(query);
        const url = new URL(endpoint + path + (search ? `?${search}` : ''));
        for (let attempt = 0; ; attempt++) {
            const headers = signV4({
                method,
                host: url.host,
                path,
                query,
                headers: extra,
                payload: body ?? new Uint8Array(),
                date: this.#now(),
                ...this.#config,
            });
            try {
                const init: RequestInit = { method, headers, signal: AbortSignal.timeout(30_000) };
                if (body !== undefined) init.body = body;
                const res = await this.#fetch(url, init);
                if (res.status < 500 || attempt >= 2) return res;
                await res.arrayBuffer().catch(() => undefined);
            } catch (error) {
                if (attempt >= 2) throw error;
            }
            await new Promise((r) => setTimeout(r, 100 * 4 ** attempt));
        }
    }
}

export interface SignInput {
    method: string;
    host: string;
    /** The path as sent, already encoded. */
    path: string;
    query: Record<string, string>;
    headers: Record<string, string>;
    payload: Uint8Array;
    date: Date;
    region: string;
    accessKeyId: string;
    secretAccessKey: string;
}

/** AWS Signature Version 4 for S3: the headers to send, Authorization included. */
export function signV4(input: SignInput): Record<string, string> {
    const amzDate = input.date.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
    const day = amzDate.slice(0, 8);
    const headers: Record<string, string> = {
        ...Object.fromEntries(Object.entries(input.headers).map(([k, v]) => [k.toLowerCase(), v.trim()])),
        host: input.host,
        'x-amz-content-sha256': sha256(input.payload),
        'x-amz-date': amzDate,
    };
    const names = Object.keys(headers).sort();
    const signed = names.join(';');
    const canonical = [
        input.method,
        input.path,
        canonicalQuery(input.query),
        names.map((n) => `${n}:${headers[n]}\n`).join(''),
        signed,
        headers['x-amz-content-sha256'],
    ].join('\n');
    const scope = `${day}/${input.region}/s3/aws4_request`;
    const toSign = ['AWS4-HMAC-SHA256', amzDate, scope, sha256(canonical)].join('\n');
    let key: Buffer = hmac(`AWS4${input.secretAccessKey}`, day);
    for (const part of [input.region, 's3', 'aws4_request']) key = hmac(key, part);
    const signature = createHmac('sha256', key).update(toSign).digest('hex');
    delete headers.host; // fetch sends it from the URL, as signed
    headers.authorization = `AWS4-HMAC-SHA256 Credential=${input.accessKeyId}/${scope}, SignedHeaders=${signed}, Signature=${signature}`;
    return headers;
}

function canonicalQuery(query: Record<string, string>): string {
    return Object.keys(query)
        .sort()
        .map((k) => `${uriEncode(k)}=${uriEncode(query[k]!)}`)
        .join('&');
}

/** RFC 3986 unreserved characters stay; everything else is percent-encoded, as SigV4 requires. */
function uriEncode(text: string): string {
    return encodeURIComponent(text).replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);
}

function sha256(data: Uint8Array | string): string {
    return createHash('sha256').update(data).digest('hex');
}

function hmac(key: string | Buffer, data: string): Buffer {
    return createHmac('sha256', key).update(data).digest();
}

function unescapeXml(text: string): string {
    return text.replace(/&(amp|lt|gt|quot|apos|#x[0-9a-fA-F]+|#[0-9]+);/g, (_, e: string) =>
        e === 'amp' ? '&' : e === 'lt' ? '<' : e === 'gt' ? '>' : e === 'quot' ? '"' : e === 'apos' ? "'" : String.fromCodePoint(e[1] === 'x' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10)),
    );
}
