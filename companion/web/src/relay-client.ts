// Browser-only relay HTTP boundary (companion-v0 §§3.1–3.2, 5.2, 7.1–7.7).
import { parseStrict, unsignedValue, writeJson } from '../../shared/json.ts';
import { decodeB64, encodeB64, isId } from './encoding.ts';
import { integer, isTime, object } from './payload.ts';
import { isRelayOrigin } from './pairing-link.ts';
import type { SendAttempt } from './outbox-state.ts';

export class RelayError extends Error {
    constructor() { super('The relay could not complete the request.'); }
}
export interface RelayReply<T> { status: number; value?: T }
const revision = (value: string) => /^[1-9][0-9]*$/.test(value) && Number.isSafeInteger(Number(value));
function token(value: string): boolean { return value.length === 43 && decodeB64(value)?.length === 32; }

export class RelayClient {
    readonly origin: string;
    readonly deviceId: string;
    private readonly fetcher: typeof fetch;
    constructor(origin: string, deviceId: string, fetcher: typeof fetch = fetch) {
        if (!isRelayOrigin(origin) || !isId(deviceId)) throw new RelayError();
        this.origin = origin; this.deviceId = deviceId; this.fetcher = fetcher;
    }

    // Caller paths are constructed below; no arbitrary URL or path can receive the bearer token.
    private async call(path: string, limit: number, bearer?: string, body?: Uint8Array,
        method = 'GET', signal?: AbortSignal, contentType = 'application/octet-stream'): Promise<RelayReply<Uint8Array>> {
        if (bearer !== undefined && !token(bearer)) throw new RelayError();
        const controller = new AbortController(), cancel = () => controller.abort();
        signal?.addEventListener('abort', cancel, { once: true });
        if (signal?.aborted) cancel();
        const timeout = setTimeout(cancel, 30000);
        let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
        try {
            const stopped = new Promise<never>((_, reject) => {
                controller.signal.addEventListener('abort', () => reject(new RelayError()), { once: true });
                if (controller.signal.aborted) reject(new RelayError());
            });
            const operation = async (): Promise<RelayReply<Uint8Array>> => {
                const headers: Record<string, string> = {};
                if (bearer !== undefined) headers.Authorization = `Bearer ${bearer}`;
                if (body !== undefined) headers['Content-Type'] = contentType;
                if (controller.signal.aborted) throw new RelayError();
                const fetcher = this.fetcher;
                const response = await fetcher(this.origin + path, { method, headers,
                    body: body === undefined ? undefined : new Uint8Array(body), signal: controller.signal,
                    redirect: 'error', credentials: 'omit', cache: 'no-store', referrerPolicy: 'no-referrer', mode: 'cors' });
                if (controller.signal.aborted) { void response.body?.cancel().catch(() => {}); throw new RelayError(); }
                // Error bodies have their own smaller bound and are never surfaced to the person.
                const maximum = response.status >= 200 && response.status < 300 ? limit : 4096;
                const length = response.headers.get('Content-Length');
                if (length !== null && /^\d+$/.test(length) && Number(length) > maximum) throw new RelayError();
                const parts: Uint8Array[] = []; let size = 0;
                reader = response.body?.getReader();
                if (reader) for (;;) {
                    const chunk = await reader.read(); if (chunk.done) break;
                    size += chunk.value.length;
                    if (size > maximum) throw new RelayError();
                    parts.push(chunk.value);
                }
                const bytes = new Uint8Array(size); let offset = 0;
                for (const part of parts) { bytes.set(part, offset); offset += part.length; }
                return response.status >= 200 && response.status < 300 ? { status: response.status, value: bytes } : { status: response.status };
            };
            return await Promise.race([stopped, operation()]);
        } catch { controller.abort(); throw new RelayError(); }
        finally {
            clearTimeout(timeout); signal?.removeEventListener('abort', cancel);
            // Never wait on cancellation of an untrusted/stalled stream.
            if (reader) void reader.cancel().catch(() => {});
        }
    }

    async health(signal?: AbortSignal): Promise<RelayReply<{ instance: string; claimed: boolean }>> {
        const reply = await this.call('/v0/health', 4096, undefined, undefined, 'GET', signal);
        if (reply.status !== 200) return { status: reply.status };
        try {
            const v = object(parseStrict(reply.value!, 4096));
            if (unsignedValue(v.protocol) !== 0 || typeof v.claimed !== 'boolean' ||
                typeof v.instance !== 'string' || !/^[0-9a-f]{32}$/.test(v.instance)) throw new RelayError();
            return { status: 200, value: { instance: v.instance, claimed: v.claimed } };
        } catch { throw new RelayError(); }
    }

    async join(pairingId: string, secret: string, publicKey: Uint8Array, hello: Uint8Array,
        signal?: AbortSignal): Promise<RelayReply<{ token: string; expiresAt: string }>> {
        if (!isId(pairingId) || !isId(secret) || publicKey.length !== 32 || hello.length > 2048) throw new RelayError();
        const body = writeJson({ secret, device_public_key: encodeB64(publicKey), hello: encodeB64(hello) });
        const reply = await this.call(`/v0/pairings/${pairingId}/join`, 4096, undefined, body, 'POST', signal, 'application/json');
        if (reply.status !== 200) return { status: reply.status };
        try {
            const v = object(parseStrict(reply.value!, 4096));
            if (v.device_id !== this.deviceId || typeof v.device_token !== 'string' || !token(v.device_token) ||
                !isTime(v.expires_at)) throw new RelayError();
            return { status: 200, value: { token: v.device_token, expiresAt: v.expires_at } };
        } catch { throw new RelayError(); }
    }

    pairingKey(pairingId: string, bearer: string, signal?: AbortSignal): Promise<RelayReply<Uint8Array>> {
        if (!isId(pairingId)) throw new RelayError();
        return this.call(`/v0/pairings/${pairingId}/key`, 4096, bearer, undefined, 'GET', signal);
    }
    async acknowledge(pairingId: string, bearer: string, signal?: AbortSignal): Promise<number> {
        if (!isId(pairingId)) throw new RelayError();
        return (await this.call(`/v0/pairings/${pairingId}/ack`, 4096, bearer, undefined, 'POST', signal)).status;
    }

    private objectLimit(name: string): number {
        const p = name.split('/');
        if (p.length === 2 && p[0] === 'index' && revision(p[1]!)) return 1048576;
        if (p.length === 3 && p[0] === 'views' && isId(p[1]!) && revision(p[2]!)) return 1048576;
        if (p.length === 4 && p[0] === 'devices' && p[1] === this.deviceId && revision(p[3]!)) {
            if (p[2] === 'keys') return 4096;
            if (p[2] === 'outcomes') return 524288;
        }
        throw new RelayError();
    }
    getObject(name: string, bearer: string, signal?: AbortSignal): Promise<RelayReply<Uint8Array>> {
        return this.call(`/v0/objects/${name}`, this.objectLimit(name), bearer, undefined, 'GET', signal);
    }
    async list(kind: 'index' | 'keys' | 'outcomes', bearer: string, below?: number,
        signal?: AbortSignal): Promise<RelayReply<{ names: string[]; next: number | null }>> {
        if (!['index', 'keys', 'outcomes'].includes(kind) ||
            (below !== undefined && (!Number.isSafeInteger(below) || below < 1))) throw new RelayError();
        const prefix = kind === 'index' ? 'index/' : `devices/${this.deviceId}/${kind}/`;
        const query = new URLSearchParams({ prefix, limit: '5' });
        if (below !== undefined) query.set('below', String(below));
        const reply = await this.call(`/v0/objects?${query}`, 16384, bearer, undefined, 'GET', signal);
        if (reply.status !== 200) return { status: reply.status };
        try {
            const v = object(parseStrict(reply.value!, 16384));
            if (!Array.isArray(v.names) || v.names.length > 5) throw new RelayError();
            let previous = below ?? Number.MAX_SAFE_INTEGER + 1;
            const names = v.names.map(name => {
                if (typeof name !== 'string' || !name.startsWith(prefix)) throw new RelayError();
                const tail = name.slice(prefix.length);
                if (!revision(tail) || Number(tail) >= previous) throw new RelayError();
                previous = Number(tail); return name;
            });
            const next = v.next === null ? null : integer(v.next, 1);
            if (next !== null && (names.length === 0 || next > previous)) throw new RelayError();
            return { status: 200, value: { names, next } };
        } catch { throw new RelayError(); }
    }

    async send(attempt: SendAttempt, signal: AbortSignal): Promise<number> {
        if (attempt.deviceId !== this.deviceId || attempt.relayOrigin !== this.origin ||
            !isId(attempt.entry.requestId) || !attempt.entry.bytes || attempt.entry.bytes.length > 65536) throw new RelayError();
        return (await this.call(`/v0/requests/${attempt.entry.requestId}`, 4096, attempt.token,
            attempt.entry.bytes, 'POST', signal)).status;
    }
    async revoke(bearer: string, bytes: Uint8Array, signal?: AbortSignal): Promise<number> {
        if (bytes.length > 4096) throw new RelayError();
        return (await this.call('/v0/devices/self', 4096, bearer, bytes, 'DELETE', signal)).status;
    }
}
