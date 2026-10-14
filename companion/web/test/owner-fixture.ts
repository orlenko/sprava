// Invented public fixture keys; Node crypto independently models the owner's wire output.
import { createCipheriv, createPrivateKey, createPublicKey, sign } from 'node:crypto';
import { encodeB64, joinBytes, utf8 } from '../src/encoding.ts';
import { importKey } from '../src/sealed.ts';
import { writeJson } from '../../shared/json.ts';

export const raw = Uint8Array.from({ length: 32 }, (_, i) => i);
export const id = 'AAAAAAAAAAAAAAAAAAAAAA';
export const otherId = encodeB64(new Uint8Array(16).fill(1));
const nonce = new Uint8Array(12);
const signing = createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), Buffer.from(raw)]),
    format: 'der', type: 'pkcs8' });
export const publicBytes = new Uint8Array(createPublicKey(signing).export({ format: 'der', type: 'spki' }).subarray(-32));
export const key = () => importKey(raw);
export const owner = () => crypto.subtle.importKey('raw', publicBytes, 'Ed25519', false, ['verify']);

export function sealed(name: string, kid: string, epoch: number, value: unknown, signed = true,
    plaintext?: string, encryptionKey: Uint8Array = raw): Uint8Array {
    const cipher = createCipheriv('aes-256-gcm', encryptionKey, nonce);
    cipher.setAAD(utf8(`sprava-companion/v0|${name}|${kid}|${epoch}`));
    const body = plaintext === undefined ? writeJson(value) : utf8(plaintext);
    const ciphertext = Buffer.concat([cipher.update(body), cipher.final(), cipher.getAuthTag()]);
    const e: Record<string, unknown> = { v: 0, kid, e: epoch, n: encodeB64(nonce), c: encodeB64(ciphertext) };
    if (signed) e.s = encodeB64(sign(null,
        joinBytes(utf8(`sprava-companion/v0 signed|${name}|${kid}|${epoch}|`), nonce, ciphertext), signing));
    return writeJson(e);
}
