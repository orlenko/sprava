// Browser sealed-object codec (companion-v0 §§3, 4.1–4.2, 4.5 and 8).
// Payload schemas, pairing, durable high-water marks and publication are separate layers.
import { isObject, parseStrict, unsignedValue, writeJson } from '../../shared/json.ts';
import type { JsonObject } from '../../shared/json.ts';
import { decodeB64, encodeB64, isId, joinBytes, utf8 } from './encoding.ts';

export class SealedError extends Error {
    constructor() { super('Invalid companion object'); }
}

interface Binding {
    kid: string;
    signed: boolean;
    plaintextLimit: number;
    wireLimit: number;
}

/** Names and epochs come from the requested URL and local state, never from the envelope. */
function binding(name: string, epoch: number): Binding {
    if (!Number.isSafeInteger(epoch) || epoch < 0) throw new SealedError();
    const p = name.split('/');
    const revision = (s: string | undefined) => s !== undefined && /^[1-9][0-9]*$/.test(s) && Number.isSafeInteger(Number(s));
    if (p.length === 2 && p[0] === 'index' && revision(p[1]) && epoch >= 1)
        return { kid: 'account', signed: true, plaintextLimit: 92700, wireLimit: 1048576 };
    if (p.length === 3 && p[0] === 'views' && isId(p[1]!) && revision(p[2]) && epoch >= 1)
        return { kid: p[1]!, signed: true, plaintextLimit: 778240, wireLimit: 1048576 };
    if (p.length === 3 && p[0] === 'pairings' && isId(p[1]!)) {
        if (p[2] === 'hello' && epoch === 0)
            return { kid: 'wrap', signed: false, plaintextLimit: 512, wireLimit: 2048 };
        if (p[2] === 'key' && epoch >= 1)
            return { kid: 'wrap', signed: false, plaintextLimit: 227, wireLimit: 1024 };
    }
    if (p.length === 4 && p[0] === 'devices' && isId(p[1]!) && revision(p[3])) {
        if (p[2] === 'keys' && epoch >= 1 && Number(p[3]) === epoch)
            return { kid: 'device', signed: true, plaintextLimit: 123, wireLimit: 4096 };
        if (p[2] === 'outcomes' && epoch === 0)
            return { kid: 'device', signed: true, plaintextLimit: 256512, wireLimit: 524288 };
    }
    if (p.length === 3 && p[0] === 'devices' && isId(p[1]!) && p[2] === 'revocation' && epoch === 0)
        return { kid: 'device', signed: false, plaintextLimit: 4096, wireLimit: 4096 };
    if (p.length === 3 && p[0] === 'requests' && isId(p[1]!) && isId(p[2]!) && epoch >= 1)
        return { kid: 'device', signed: false, plaintextLimit: 48128, wireLimit: 65536 };
    throw new SealedError();
}

/** §4.1: secret browser keys are non-extractable AES-256-GCM CryptoKeys. */
export async function importKey(bytes: Uint8Array): Promise<CryptoKey> {
    if (bytes.length !== 32) throw new SealedError();
    return crypto.subtle.importKey('raw', new Uint8Array(bytes), 'AES-GCM', false, ['encrypt', 'decrypt']);
}

function checkKey(key: CryptoKey): void {
    if (key.type !== 'secret' || key.extractable || key.algorithm.name !== 'AES-GCM' ||
        (key.algorithm as AesKeyAlgorithm).length !== 256) throw new SealedError();
}

function aad(name: string, kid: string, epoch: number): Uint8Array<ArrayBuffer> {
    return utf8(`sprava-companion/v0|${name}|${kid}|${epoch}`);
}

/** §4.2: devices write only unsigned objects, with a new random nonce on every seal. */
export async function sealObject(name: string, epoch: number, key: CryptoKey, plaintext: Uint8Array): Promise<Uint8Array> {
    const b = binding(name, epoch);
    checkKey(key);
    if (b.signed || !isObject(parseStrict(plaintext, b.plaintextLimit))) throw new SealedError();
    const nonce = crypto.getRandomValues(new Uint8Array(12));
    const cipher = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce,
        additionalData: aad(name, b.kid, epoch), tagLength: 128 }, key, new Uint8Array(plaintext)));
    const bytes = writeJson({ v: 0, kid: b.kid, e: epoch, n: encodeB64(nonce), c: encodeB64(cipher) });
    if (bytes.length > b.wireLimit) throw new SealedError();
    return bytes;
}

/** §§4.2, 4.5: signed owner objects are authenticated BEFORE any attempt to decrypt. */
export async function openObject(name: string, epoch: number, key: CryptoKey, bytes: Uint8Array,
    owner: CryptoKey | null = null): Promise<JsonObject> {
    try {
        const b = binding(name, epoch);
        checkKey(key);
        const envelope = parseStrict(bytes, b.wireLimit);
        if (!isObject(envelope) || unsignedValue(envelope.v) !== 0 || envelope.kid !== b.kid ||
            unsignedValue(envelope.e) !== epoch || typeof envelope.n !== 'string' || typeof envelope.c !== 'string')
            throw new SealedError();
        const nonce = decodeB64(envelope.n);
        const cipher = decodeB64(envelope.c);
        if (nonce?.length !== 12 || cipher === null || cipher.length < 16 || cipher.length > b.plaintextLimit + 16)
            throw new SealedError();
        if (b.signed) {
            const signature = typeof envelope.s === 'string' ? decodeB64(envelope.s) : null;
            if (owner === null || owner.type !== 'public' || owner.algorithm.name !== 'Ed25519' || signature?.length !== 64)
                throw new SealedError();
            const message = joinBytes(utf8(`sprava-companion/v0 signed|${name}|${b.kid}|${epoch}|`), nonce, cipher);
            if (!await crypto.subtle.verify('Ed25519', owner, signature, message)) throw new SealedError();
        } else if (Object.hasOwn(envelope, 's')) {
            throw new SealedError();
        }
        const plain = new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: nonce,
            additionalData: aad(name, b.kid, epoch), tagLength: 128 }, key, cipher));
        const value = parseStrict(plain, b.plaintextLimit);
        if (!isObject(value)) throw new SealedError();
        return value;
    } catch {
        // Never include decrypted content, tokens, keys or crypto-provider errors in a user-visible error.
        throw new SealedError();
    }
}
