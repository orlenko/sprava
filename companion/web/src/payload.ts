// Field rules of companion-v0 §§3 and 8. Unknown members never leave a validated payload.
import { isObject, unsignedValue } from '../../shared/json.ts';
import type { Json, JsonObject } from '../../shared/json.ts';
import { decodeB64, utf8 } from './encoding.ts';

export class PayloadError extends Error {
    constructor() { super('Invalid companion payload'); }
}

export function object(value: Json | undefined): JsonObject {
    if (!isObject(value)) throw new PayloadError();
    return value;
}

export function integer(value: Json | undefined, minimum = 0): number {
    const n = unsignedValue(value);
    if (n === null || n < minimum) throw new PayloadError();
    return n;
}

export function keyBytes(value: Json | undefined): Uint8Array<ArrayBuffer> {
    const bytes = typeof value === 'string' && value.length === 43 ? decodeB64(value) : null;
    if (bytes?.length !== 32) throw new PayloadError();
    return bytes;
}

/** Both Unicode-scalar and encoded-byte limits apply; quotes around JSON strings are excluded. */
export function text(value: Json | undefined, minimum: number, maximum: number, encodedMaximum: number): string {
    if (typeof value !== 'string') throw new PayloadError();
    const length = [...value].length;
    if (length < minimum || length > maximum || utf8(JSON.stringify(value).slice(1, -1)).length > encodedMaximum)
        throw new PayloadError();
    return value;
}

/** The Mac's proleptic Gregorian calendar uses common-era years 1 through 9999. */
export function isDate(value: unknown): value is string {
    if (typeof value !== 'string' || value.length !== 10 || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
    const year = Number(value.slice(0, 4)), month = Number(value.slice(5, 7)), day = Number(value.slice(8));
    if (year < 1 || month < 1 || month > 12) return false;
    const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
    const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]!;
    return day >= 1 && day <= days;
}

/** §3: UTC to whole seconds, with RFC3339 §5.7 leap-second positions at a month's end. */
export function isTime(value: unknown): value is string {
    if (typeof value !== 'string' || value.length !== 20 || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(value) ||
        !isDate(value.slice(0, 10))) return false;
    const hour = Number(value.slice(11, 13)), minute = Number(value.slice(14, 16)), second = Number(value.slice(17, 19));
    if (hour > 23 || minute > 59) return false;
    if (second < 60) return true;
    if (second !== 60 || hour !== 23 || minute !== 59) return false;
    const year = Number(value.slice(0, 4)), month = Number(value.slice(5, 7)), day = Number(value.slice(8, 10));
    const nextDay = `${String(year).padStart(4, '0')}-${String(month).padStart(2, '0')}-${String(day + 1).padStart(2, '0')}`;
    return !isDate(nextDay);
}
