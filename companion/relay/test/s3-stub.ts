// An in-process S3 stub: one bucket in memory, path-style, checking every request's SigV4 signature against
// what was actually sent. With `ignoreIfNoneMatch` it overwrites like DigitalOcean Spaces does (§6, step 5).
import { createServer, type IncomingMessage } from 'node:http';
import type { AddressInfo } from 'node:net';
import { signV4 } from '../src/store/s3.ts';

export const S3_CREDENTIALS = { region: 'test-region', accessKeyId: 'key-id-example', secretAccessKey: 'secret-example' };

export interface S3Stub {
    endpoint: string;
    bucket: string;
    objects: Map<string, Uint8Array>;
    requests: string[];
    /** Answers the next n requests with 503, to test retries. */
    failNext(n: number): void;
    /**
     * Holds back every PUT to a key that `match` accepts: the client is answered 500, as if the write failed, but
     * the stub keeps it and applies it only on `landHeld()`, as a store may when a write lands late.
     */
    hold(match: (key: string) => boolean): void;
    /** Applies the held writes, in the order they arrived, and stops holding. */
    landHeld(): void;
    /** Answers the next listing with this body instead. */
    nextListBody(body: string): void;
    close(): Promise<void>;
}

export async function startS3Stub(options: { ignoreIfNoneMatch?: boolean; pageSize?: number } = {}): Promise<S3Stub> {
    const bucket = 'bucket-example';
    const objects = new Map<string, Uint8Array>();
    const requests: string[] = [];
    let failures = 0;
    let holding: ((key: string) => boolean) | null = null;
    const held: [string, Uint8Array][] = [];
    let listBody: string | null = null;
    const server = createServer(async (req, res) => {
        const body = await readAll(req);
        const url = new URL(req.url ?? '/', 'http://stub');
        requests.push(`${req.method} ${url.search ? 'list' : 'object'}`);
        const reply = (status: number, payload: string | Uint8Array = ''): void => {
            res.writeHead(status);
            res.end(payload);
        };
        if (failures > 0) {
            failures--;
            return reply(503);
        }
        if (!signatureMatches(req, url, body)) return reply(403, '<Error><Code>SignatureDoesNotMatch</Code></Error>');
        const [, b, ...rest] = url.pathname.split('/').map(decodeURIComponent);
        if (b !== bucket) return reply(404);
        const key = rest.join('/');
        if (req.method === 'GET' && key === '' && listBody !== null) {
            const body = listBody;
            listBody = null;
            return reply(200, body);
        }
        if (req.method === 'GET' && key === '') return reply(200, list(objects, url.searchParams, options.pageSize ?? 3));
        const stored = objects.get(key);
        switch (req.method) {
            case 'GET':
                return stored ? reply(200, stored) : reply(404);
            case 'HEAD':
                return reply(stored ? 200 : 404);
            case 'PUT':
                if (holding?.(key)) {
                    held.push([key, body]);
                    return reply(500);
                }
                if (stored && req.headers['if-none-match'] === '*' && !options.ignoreIfNoneMatch) return reply(412);
                objects.set(key, body);
                return reply(200);
            case 'DELETE':
                objects.delete(key);
                return reply(204);
        }
        reply(405);
    });
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    server.unref(); // a failed test that never closes it must not keep the run alive
    return {
        endpoint: `http://127.0.0.1:${(server.address() as AddressInfo).port}`,
        bucket,
        objects,
        requests,
        failNext: (n) => {
            failures = n;
        },
        hold: (match) => {
            holding = match;
        },
        landHeld: () => {
            holding = null;
            for (const [key, body] of held.splice(0)) objects.set(key, body);
        },
        nextListBody: (body) => {
            listBody = body;
        },
        close: () => new Promise((resolve) => server.close(() => resolve())),
    };
}

function list(objects: Map<string, Uint8Array>, query: URLSearchParams, pageSize: number): string {
    const prefix = query.get('prefix') ?? '';
    const keys = [...objects.keys()].filter((k) => k.startsWith(prefix)).sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
    const start = Number(query.get('continuation-token') ?? '0');
    const page = keys.slice(start, start + pageSize);
    const truncated = start + pageSize < keys.length;
    const escape = (k: string): string => k.replace(/&/g, '&amp;').replace(/</g, '&lt;');
    return (
        `<?xml version="1.0" encoding="UTF-8"?><ListBucketResult><IsTruncated>${truncated}</IsTruncated>` +
        page.map((k) => `<Contents><Key>${escape(k)}</Key><Size>1</Size></Contents>`).join('') +
        (truncated ? `<NextContinuationToken>${start + pageSize}</NextContinuationToken>` : '') +
        '</ListBucketResult>'
    );
}

/** Recomputes the signature from the request as received: method, path, query, headers and body. */
function signatureMatches(req: IncomingMessage, url: URL, body: Uint8Array): boolean {
    const auth = req.headers.authorization ?? '';
    const signedNames = /SignedHeaders=([^,]+)/.exec(auth)?.[1]?.split(';') ?? [];
    const date = req.headers['x-amz-date'];
    if (typeof date !== 'string' || !signedNames.includes('host')) return false;
    const headers: Record<string, string> = {};
    for (const name of signedNames) {
        if (!['host', 'x-amz-content-sha256', 'x-amz-date'].includes(name)) headers[name] = String(req.headers[name] ?? '');
    }
    const iso = `${date.slice(0, 4)}-${date.slice(4, 6)}-${date.slice(6, 8)}T${date.slice(9, 11)}:${date.slice(11, 13)}:${date.slice(13, 15)}Z`;
    const expected = signV4({
        method: req.method ?? '',
        host: req.headers.host ?? '',
        path: url.pathname,
        query: Object.fromEntries(url.searchParams),
        headers,
        payload: body,
        date: new Date(iso),
        ...S3_CREDENTIALS,
    });
    return expected.authorization === auth && expected['x-amz-content-sha256'] === req.headers['x-amz-content-sha256'];
}

async function readAll(req: IncomingMessage): Promise<Uint8Array> {
    const chunks: Buffer[] = [];
    for await (const chunk of req) chunks.push(chunk as Buffer);
    return new Uint8Array(Buffer.concat(chunks));
}
