// Encodings of companion-v0 §3: b64, ids, tokens and their hashes, times.
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';

const B64_ALPHABET = /^[A-Za-z0-9_-]*$/;

/** §3: base64url without padding, canonical only (no padding, no other characters, zero trailing bits). */
export function decodeB64(text: string): Uint8Array | null {
    if (!B64_ALPHABET.test(text) || text.length % 4 === 1) return null;
    const bytes = Buffer.from(text, 'base64url');
    // Re-encoding gives back the input only when the unused trailing bits were zero.
    return bytes.toString('base64url') === text ? new Uint8Array(bytes) : null;
}

export function encodeB64(bytes: Uint8Array): string {
    return Buffer.from(bytes).toString('base64url');
}

/** §3: an id is 16 random bytes in b64, 22 characters. */
export function isId(text: unknown): text is string {
    return typeof text === 'string' && text.length === 22 && decodeB64(text)?.length === 16;
}

/** §3: a token is 32 random bytes in b64, 43 characters. */
export function isToken(text: string): boolean {
    return text.length === 43 && decodeB64(text)?.length === 32;
}

export function newId(): string {
    return encodeB64(randomBytes(16));
}

export function newToken(): string {
    return encodeB64(randomBytes(32));
}

/** §3: SHA-256 over the 43 ASCII bytes of the token as written, in lowercase hex. */
export function tokenHash(token: string): string {
    return sha256Hex(Buffer.from(token, 'ascii'));
}

export function sha256Hex(bytes: Uint8Array | string): string {
    return createHash('sha256').update(bytes).digest('hex');
}

/** §3: a token hash as the owner sends it: 64 lowercase hex characters. */
export function isHashHex(text: unknown): text is string {
    return typeof text === 'string' && /^[0-9a-f]{64}$/.test(text);
}

/** Constant-time equality of two strings of hex or b64; unequal lengths are simply unequal. */
export function sameSecret(a: string, b: string): boolean {
    const x = Buffer.from(a, 'utf8');
    const y = Buffer.from(b, 'utf8');
    return x.length === y.length && timingSafeEqual(x, y);
}

export function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
    return a.length === b.length && timingSafeEqual(a, b);
}

/** §3: RFC 3339 in UTC, exactly `YYYY-MM-DDTHH:MM:SSZ`. */
export function formatTime(ms: number): string {
    return new Date(Math.floor(ms / 1000) * 1000).toISOString().replace('.000Z', 'Z');
}

/** §3: unsigned integers of names and queries, in decimal without leading zeros, at most 2^53 − 1. */
export function parseUnsigned(text: string): number | null {
    if (!/^(0|[1-9][0-9]{0,15})$/.test(text)) return null;
    const value = Number(text);
    return Number.isSafeInteger(value) ? value : null;
}
