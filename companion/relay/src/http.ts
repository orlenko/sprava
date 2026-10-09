// The HTTP core (companion-v0 §7): routing, cross-origin rules (§7.7), tokens and roles (§7.1), body limits
// (§3.2, §7), strict JSON bodies (§3.1), plain-sentence errors and logs (§12).
import type { IncomingMessage, ServerResponse } from 'node:http';
import { isToken } from './encoding.ts';
import { isObject, JsonError, parseStrict, writeJson, type JsonObject } from './json.ts';
import type { Log } from './log.ts';

export type Access = 'public' | 'owner' | 'active' | 'pending';

export type Principal = { kind: 'owner' } | { kind: 'device'; id: string; active: boolean; pairing: string };

export interface Call {
    params: Record<string, string>;
    query: URLSearchParams;
    principal: Principal | null;
    /** The request body: the bytes, or empty for a route without one. */
    body: Uint8Array;
    /** The body read as a strict JSON object, for a route whose body is JSON. */
    json: JsonObject;
    /** The client address the host reports for the connection (§6, step 4). */
    address: string;
}

export interface Reply {
    status: number;
    json?: unknown;
    bytes?: Uint8Array;
    headers?: Record<string, string>;
}

export interface Route {
    method: 'GET' | 'POST' | 'PUT' | 'DELETE';
    /** Segments; `:name` takes one segment, a final `*name` takes the rest. Also the pattern that is logged. */
    path: string;
    access: Access[];
    /** §7.7: whether a browser may call it. Claim and owner endpoints refuse any request with an Origin header. */
    browser: boolean;
    /** Served while the relay is unclaimed (§6: only health and claim). */
    unclaimed?: boolean;
    body?: { kind: 'json' | 'bytes'; limit: number };
    handle(call: Call): Promise<Reply>;
}

export class HttpError extends Error {
    readonly status: number;
    readonly headers: Record<string, string>;
    constructor(status: number, sentence: string, headers: Record<string, string> = {}) {
        super(sentence);
        this.status = status;
        this.headers = headers;
    }
}

export interface HttpOptions {
    routes: Route[];
    webOrigin: string;
    log: Log;
    authenticate(token: string): Promise<Principal | null>;
    isClaimed(): boolean;
    /** §7: a body that has not fully arrived within this time is dropped. */
    bodyTimeoutMs?: number;
}

/** §7: any JSON body without a smaller limit of its own, and any other response. */
export const JSON_LIMIT = 4096;

class Dropped extends Error {}

export function createHandler(options: HttpOptions): (req: IncomingMessage, res: ServerResponse) => Promise<void> {
    const timeoutMs = options.bodyTimeoutMs ?? 60_000;
    return async (req, res) => {
        const started = performance.now();
        const origin = req.headers.origin;
        const cors = origin !== undefined && origin === options.webOrigin;
        const matched = { pattern: 'unmatched' };
        let reply: Reply;
        try {
            reply = await route(req, options, timeoutMs, matched);
        } catch (error) {
            if (error instanceof Dropped) {
                options.log.request(req.method ?? '', matched.pattern, 408, Math.round(performance.now() - started));
                return;
            }
            if (error instanceof HttpError) {
                reply = { status: error.status, json: { error: error.message }, headers: error.headers };
            } else {
                options.log.event('error', { kind: error instanceof Error ? error.name : 'unknown' });
                reply = { status: 500, json: { error: 'The relay could not complete this request.' } };
            }
        }
        send(res, reply, cors ? options.webOrigin : null);
        options.log.request(req.method ?? '', matched.pattern, reply.status, Math.round(performance.now() - started));
    };
}

async function route(req: IncomingMessage, options: HttpOptions, timeoutMs: number, matched: { pattern: string }): Promise<Reply> {
    const origin = req.headers.origin;
    // §7.7: a foreign Origin is refused before anything else.
    if (origin !== undefined && origin !== options.webOrigin) throw new HttpError(403, 'This origin may not call the relay.');
    const url = new URL(req.url ?? '/', 'http://relay.invalid');
    // §13: `/` and any path outside `/v0/` are 404.
    // The path as sent, before URL normalization removes dot segments (`/x/../v0/health` stays outside /v0/).
    const raw = (req.url ?? '').split('?')[0]!;
    if (!raw.startsWith('/v0/') || /(^|\/)(\.|%2e){1,2}(\/|$)/i.test(raw) || !url.pathname.startsWith('/v0/')) {
        throw new HttpError(404, 'There is nothing here.');
    }
    if (req.method === 'OPTIONS') {
        if (origin === undefined) throw new HttpError(404, 'There is nothing here.');
        matched.pattern = 'OPTIONS';
        return preflight(url.pathname);
    }
    const segments = url.pathname.split('/');
    let found: { route: Route; params: Record<string, string> } | null = null;
    for (const candidate of options.routes) {
        const params = candidate.method === req.method ? match(candidate.path, segments) : null;
        if (params !== null) {
            found = { route: candidate, params };
            break;
        }
    }
    if (found === null) throw new HttpError(404, 'There is nothing here.');
    matched.pattern = found.route.path;
    return run(req, found.route, found.params, url, options, timeoutMs);
}

async function run(req: IncomingMessage, r: Route, params: Record<string, string>, url: URL, options: HttpOptions, timeoutMs: number): Promise<Reply> {
    if (req.headers.origin !== undefined && !r.browser) throw new HttpError(403, 'This endpoint may not be called from a browser.');
    const isPublic = r.access.includes('public');
    if (!options.isClaimed() && !r.unclaimed) {
        throw isPublic ? new HttpError(404, 'This relay has not been claimed yet.') : new HttpError(401, 'This relay has not been claimed yet.');
    }
    let principal: Principal | null = null;
    if (!isPublic) {
        const bearer = /^Bearer (\S+)$/.exec(req.headers.authorization ?? '')?.[1];
        // §3: a bearer value that is not 43 canonical b64 characters is 401, without hashing.
        if (bearer === undefined || !isToken(bearer)) throw new HttpError(401, 'A valid token is required.');
        principal = await options.authenticate(bearer);
        if (principal === null) throw new HttpError(401, 'A valid token is required.');
        const role: Access = principal.kind === 'owner' ? 'owner' : principal.active ? 'active' : 'pending';
        if (!r.access.includes(role)) throw new HttpError(403, 'This token may not call this endpoint.');
        if (principal.kind === 'device') options.log.device(principal.id);
    }
    const limit = r.body?.limit ?? JSON_LIMIT;
    const body = await readBody(req, limit, timeoutMs);
    let json: JsonObject = Object.create(null);
    if (r.body?.kind === 'json') {
        try {
            const value = parseStrict(body, limit);
            if (!isObject(value)) throw new JsonError('not an object');
            json = value;
        } catch (error) {
            if (error instanceof JsonError) throw new HttpError(400, 'The request body is not valid JSON for this endpoint.');
            throw error;
        }
    }
    return r.handle({ params, query: url.searchParams, principal, body, json, address: req.socket.remoteAddress ?? '' });
}

/** Matches `/v0/a/:x/*rest` against the split path; null when it does not match. */
function match(path: string, segments: string[]): Record<string, string> | null {
    const parts = path.split('/');
    const params: Record<string, string> = {};
    for (let i = 0; i < parts.length; i++) {
        const part = parts[i]!;
        if (part.startsWith('*')) {
            const rest = segments.slice(i).join('/');
            if (rest === '') return null;
            params[part.slice(1)] = rest;
            return params;
        }
        const segment = segments[i];
        if (segment === undefined) return null;
        if (part.startsWith(':')) {
            if (segment === '') return null;
            params[part.slice(1)] = segment;
        } else if (part !== segment) {
            return null;
        }
    }
    return segments.length === parts.length ? params : null;
}

/** §7.7: the preflight answer. DELETE is offered only for a device's self-revocation. */
function preflight(path: string): Reply {
    return {
        status: 204,
        headers: {
            'Access-Control-Allow-Methods': path === '/v0/devices/self' ? 'GET, POST, DELETE' : 'GET, POST',
            'Access-Control-Allow-Headers': 'Authorization, Content-Type, If-None-Match',
            'Access-Control-Max-Age': '600',
        },
    };
}

/** §3.2, §7: reads the body as a stream, refusing it with 413 as soon as it passes its limit. */
function readBody(req: IncomingMessage, limit: number, timeoutMs: number): Promise<Uint8Array> {
    const declared = req.headers['content-length'];
    if (declared !== undefined && Number(declared) > limit) {
        return Promise.reject(new HttpError(413, 'The request body is too large.', { Connection: 'close' }));
    }
    return new Promise((resolve, reject) => {
        const chunks: Buffer[] = [];
        let size = 0;
        let done = false;
        const finish = (error: Error | null): void => {
            if (done) return;
            done = true;
            clearTimeout(timer);
            req.off('data', onData);
            if (error) reject(error);
            else resolve(new Uint8Array(Buffer.concat(chunks)));
        };
        // §7: a body that has not fully arrived within the time is dropped, and nothing is stored for it.
        const timer = setTimeout(() => {
            finish(new Dropped());
            req.destroy();
        }, timeoutMs);
        const onData = (chunk: Buffer): void => {
            size += chunk.length;
            if (size > limit) {
                req.pause();
                finish(new HttpError(413, 'The request body is too large.', { Connection: 'close' }));
            } else {
                chunks.push(chunk);
            }
        };
        req.on('data', onData);
        req.once('end', () => finish(null));
        req.once('error', () => finish(new Dropped()));
        req.once('aborted', () => finish(new Dropped()));
    });
}

function send(res: ServerResponse, reply: Reply, corsOrigin: string | null): void {
    let body: Uint8Array = new Uint8Array();
    const headers: Record<string, string> = { 'Cache-Control': 'no-store', Vary: 'Origin', ...reply.headers };
    if (reply.json !== undefined) {
        body = writeJson(reply.json);
        headers['Content-Type'] = 'application/json';
    } else if (reply.bytes !== undefined) {
        body = reply.bytes;
        headers['Content-Type'] = 'application/octet-stream';
    }
    if (corsOrigin !== null) {
        // §7.7: never Access-Control-Allow-Credentials; the web app uses bearer tokens, not cookies.
        headers['Access-Control-Allow-Origin'] = corsOrigin;
        headers['Access-Control-Expose-Headers'] = 'ETag';
    }
    headers['Content-Length'] = String(body.length);
    res.writeHead(reply.status, headers);
    res.end(body);
}
