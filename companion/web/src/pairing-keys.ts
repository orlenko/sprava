// Device-side X25519 / HKDF-SHA256 agreement (companion-v0 §4.3).
// Derived keys are provisional: confirming the code and installing pairing state are separate steps.
import { decodeB64, isId, joinBytes, utf8 } from './encoding.ts';

export class PairingKeyError extends Error {
    constructor() { super('Could not establish companion pairing keys'); }
}

export interface PairingKeys {
    wrap: CryptoKey;
    device: CryptoKey;
    code: string;
    publicKey: Uint8Array<ArrayBuffer>;
}

/** §4.1: a device's private key never becomes exportable, including while a pairing is pending. */
export async function newPairingKeyPair(): Promise<CryptoKeyPair> {
    try {
        return await crypto.subtle.generateKey('X25519', false, ['deriveBits']) as CryptoKeyPair;
    } catch { throw new PairingKeyError(); }
}

/** §4.3: unsigned big-endian 32-bit value modulo one million, six digits with leading zeros. */
export function confirmationCode(bytes: Uint8Array): string {
    if (bytes.length !== 4) throw new PairingKeyError();
    const value = new DataView(new Uint8Array(bytes).buffer).getUint32(0, false);
    return String(value % 1000000).padStart(6, '0');
}

export async function devicePairingKeys(pairingId: string, deviceId: string, ownerPublic: Uint8Array,
    local: CryptoKeyPair): Promise<PairingKeys> {
    let shared: Uint8Array<ArrayBuffer> | undefined;
    try {
        if (!isId(pairingId) || !isId(deviceId) || ownerPublic.length !== 32 ||
            local.privateKey.type !== 'private' || local.privateKey.extractable ||
            local.privateKey.algorithm.name !== 'X25519' || local.publicKey.type !== 'public' ||
            local.publicKey.algorithm.name !== 'X25519') throw new PairingKeyError();
        const a = new Uint8Array(ownerPublic);
        const b = new Uint8Array(await crypto.subtle.exportKey('raw', local.publicKey));
        const peer = await crypto.subtle.importKey('raw', a, 'X25519', false, []);
        shared = new Uint8Array(await crypto.subtle.deriveBits({ name: 'X25519', public: peer }, local.privateKey, 256));
        // Some providers throw for low-order keys; others may return all zero bytes. Refuse both.
        if (shared.length !== 32 || shared.every(byte => byte === 0)) throw new PairingKeyError();
        const ikm = await crypto.subtle.importKey('raw', shared, 'HKDF', false, ['deriveBits', 'deriveKey']);
        const salt = utf8(pairingId);
        const d = decodeB64(deviceId)!;
        const algorithm = (kind: string) => ({ name: 'HKDF', hash: 'SHA-256', salt,
            info: joinBytes(utf8(`sprava-companion/v0 ${kind}`), a, b, d) });
        const wrap = await crypto.subtle.deriveKey(algorithm('wrap'), ikm,
            { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
        const device = await crypto.subtle.deriveKey(algorithm('device'), ikm,
            { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
        const codeBytes = new Uint8Array(await crypto.subtle.deriveBits(algorithm('confirm'), ikm, 32));
        return { wrap, device, code: confirmationCode(codeBytes), publicKey: b };
    } catch {
        throw new PairingKeyError();
    } finally {
        shared?.fill(0);
    }
}
