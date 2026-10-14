// Browser encodings of companion-v0 §3. No Node imports or runtime dependencies.
const alphabet = /^[A-Za-z0-9_-]*$/;

export function encodeB64(bytes: Uint8Array): string {
    let binary = '';
    // Avoid spreading a whole ciphertext into a call (which exceeds browser argument limits).
    for (const byte of bytes) binary += String.fromCharCode(byte);
    return btoa(binary).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
}

export function decodeB64(text: string): Uint8Array<ArrayBuffer> | null {
    if (!alphabet.test(text) || text.length % 4 === 1) return null;
    const binary = atob(text.replaceAll('-', '+').replaceAll('_', '/'));
    const bytes = Uint8Array.from(binary, c => c.charCodeAt(0));
    return encodeB64(bytes) === text ? bytes : null;
}

export function isId(text: string): boolean {
    return text.length === 22 && decodeB64(text)?.length === 16;
}

export function utf8(text: string): Uint8Array<ArrayBuffer> {
    return new TextEncoder().encode(text);
}

export function joinBytes(...parts: Uint8Array[]): Uint8Array<ArrayBuffer> {
    const result = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
    let at = 0;
    for (const part of parts) { result.set(part, at); at += part.length; }
    return result;
}
