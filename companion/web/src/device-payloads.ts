// Device-written payloads: validate before numbering or sending (companion-v0 §§8.1, 8.6, 8.8, 9.8).
import { parseStrict, writeJson } from '../../shared/json.ts';
import { isId } from './encoding.ts';
import { isDate, isTime, PayloadError, text } from './payload.ts';
import { sealObject } from './sealed.ts';
import type { ItemId } from './view-payloads.ts';

export type RequestType = 'done' | 'drop' | 'follow_up' | 'arrived' | 'postpone' | 'note';
export interface RequestAction {
    type: RequestType; binder?: string | null; item?: ItemId | null; seenVersion?: number | null;
    date?: string | null; text?: string | null;
}
const positive = (n: unknown): n is number => typeof n === 'number' && Number.isSafeInteger(n) && n >= 1;
const absent = (v: unknown) => v === undefined || v === null;
function itemId(value: unknown): value is ItemId {
    if (typeof value === 'number') return Number.isSafeInteger(value) && value !== 0;
    try { return typeof value === 'string' && text(value, 1, 200, 800) === value; }
    catch { return false; }
}

/** §8.6: errors leave the person's draft untouched; invalid actions never consume a sequence number. */
export function validateAction(action: RequestAction): RequestAction {
    try {
        if (!action || !['done', 'drop', 'follow_up', 'arrived', 'postpone', 'note'].includes(action.type))
            throw new PayloadError();
        if (!absent(action.binder) && (typeof action.binder !== 'string' || !isId(action.binder))) throw new PayloadError();
        if (action.type === 'note') {
            if (!absent(action.item) || !absent(action.seenVersion) || !absent(action.date)) throw new PayloadError();
            const note = text(action.text, 1, 10000, 40000);
            for (const c of note) {
                const n = c.codePointAt(0)!;
                if (n < 32 && n !== 9 && n !== 10) throw new PayloadError();
            }
        } else {
            if (absent(action.binder) || !itemId(action.item) || !positive(action.seenVersion) || !absent(action.text))
                throw new PayloadError();
            if (action.type === 'follow_up' || action.type === 'postpone') {
                if (!isDate(action.date)) throw new PayloadError();
            } else if (!absent(action.date)) throw new PayloadError();
        }
        const result = { type: action.type, binder: action.binder ?? null, item: action.item ?? null,
            seenVersion: action.seenVersion ?? null, date: action.date ?? null, text: action.text ?? null };
        // §3.1 scalar validation also applies to device-entered strings, before any numbering happens.
        parseStrict(writeJson(result), 48128);
        return result;
    } catch { throw new PayloadError(); }
}

function padded(value: Record<string, unknown>, target?: number): Uint8Array {
    const base = { ...value, pad: '' }, length = writeJson(base).length;
    const size = target ?? Math.ceil(length / 1024) * 1024;
    if (length > size) throw new PayloadError();
    return writeJson({ ...base, pad: ' '.repeat(size - length) });
}

/** §8.6: serialize known fields in wire order and pad to the smallest whole KiB. */
export function requestPayload(action: RequestAction, seq: number, madeAt: string): Uint8Array {
    const valid = validateAction(action);
    if (!positive(seq) || !isTime(madeAt)) throw new PayloadError();
    return padded({ seq, type: valid.type, made_at: madeAt, binder: valid.binder, item: valid.item,
        seen_version: valid.seenVersion, date: valid.date, text: valid.text });
}
export async function sealRequest(deviceId: string, requestId: string, epoch: number, deviceKey: CryptoKey,
    action: RequestAction, seq: number, madeAt: string): Promise<Uint8Array> {
    return sealObject(`requests/${deviceId}/${requestId}`, epoch, deviceKey, requestPayload(action, seq, madeAt));
}

/** §8.1: labels are private to the owner; hello is always exactly 512 plaintext bytes. */
export function helloPayload(label: string): Uint8Array {
    try {
        const value = text(label, 1, 40, 160);
        for (const c of value) if (c.codePointAt(0)! < 32 || c === '\x7f') throw new PayloadError();
        const bytes = padded({ label: value }, 512); parseStrict(bytes, 512); return bytes;
    } catch { throw new PayloadError(); }
}
export async function sealHello(pairingId: string, wrapKey: CryptoKey, label: string): Promise<Uint8Array> {
    return sealObject(`pairings/${pairingId}/hello`, 0, wrapKey, helloPayload(label));
}

/** §8.8: revocation is separated from ordinary requests and bound to the installed relay instance. */
export async function sealRevocation(deviceId: string, deviceKey: CryptoKey, instance: string,
    generation: string, madeAt: string): Promise<Uint8Array> {
    if (!isId(deviceId) || !isId(generation) || !/^[0-9a-f]{32}$/.test(instance) || !isTime(madeAt)) throw new PayloadError();
    return sealObject(`devices/${deviceId}/revocation`, 0, deviceKey, writeJson({ type: 'revoke-self',
        device_id: deviceId, instance, pairing_generation: generation, made_at: madeAt }));
}
