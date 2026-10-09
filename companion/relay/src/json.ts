// Strict JSON of companion-v0 §3.1. JSON.parse keeps the last of two duplicate members and accepts lone
// surrogates, so the relay reads with this parser instead.

/** A number as written, so a reader can apply §3's integer rules to its exact text. */
export class JsonNumber {
    readonly raw: string;
    constructor(raw: string) {
        this.raw = raw;
    }
}

export type Json = null | boolean | string | JsonNumber | Json[] | JsonObject;
export type JsonObject = { [name: string]: Json };

export class JsonError extends Error {}

const MAX_DEPTH = 16;
const NUMBER = /-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/y;
const ESCAPES: Record<string, string> = { '"': '"', '\\': '\\', '/': '/', b: '\b', f: '\f', n: '\n', r: '\r', t: '\t' };
const decoder = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true });

/** §3.1: reads a whole text strictly; throws JsonError on every rejected form. */
export function parseStrict(bytes: Uint8Array, limit: number): Json {
    if (bytes.length > limit) throw new JsonError('too long');
    if (bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) throw new JsonError('byte order mark');
    let text: string;
    try {
        text = decoder.decode(bytes);
    } catch {
        throw new JsonError('not UTF-8');
    }
    const parser = new Parser(text);
    parser.space();
    const value = parser.value(0);
    parser.space();
    if (parser.at < text.length) throw new JsonError('trailing text');
    return value;
}

class Parser {
    readonly text: string;
    at = 0;
    constructor(text: string) {
        this.text = text;
    }

    space(): void {
        while (this.at < this.text.length && ' \t\n\r'.includes(this.text[this.at]!)) this.at++;
    }

    value(depth: number): Json {
        const c = this.text[this.at];
        if (c === '{' || c === '[') {
            if (depth + 1 > MAX_DEPTH) throw new JsonError('nested too deep');
            return c === '{' ? this.object(depth + 1) : this.array(depth + 1);
        }
        if (c === '"') return this.string();
        for (const [word, value] of [['true', true], ['false', false], ['null', null]] as const) {
            if (this.text.startsWith(word, this.at)) {
                this.at += word.length;
                return value;
            }
        }
        NUMBER.lastIndex = this.at;
        const number = NUMBER.exec(this.text);
        if (number === null) throw new JsonError('unexpected character');
        this.at += number[0].length;
        return new JsonNumber(number[0]);
    }

    object(depth: number): JsonObject {
        const result: JsonObject = Object.create(null);
        const seen = new Set<string>();
        this.at++;
        this.space();
        if (this.text[this.at] === '}') {
            this.at++;
            return result;
        }
        for (;;) {
            if (this.text[this.at] !== '"') throw new JsonError('expected a member name');
            const name = this.string();
            if (seen.has(name)) throw new JsonError('duplicate member');
            seen.add(name);
            this.space();
            this.expect(':');
            this.space();
            result[name] = this.value(depth);
            this.space();
            if (this.text[this.at] === '}') {
                this.at++;
                return result;
            }
            this.expect(',');
            this.space();
        }
    }

    array(depth: number): Json[] {
        const result: Json[] = [];
        this.at++;
        this.space();
        if (this.text[this.at] === ']') {
            this.at++;
            return result;
        }
        for (;;) {
            result.push(this.value(depth));
            this.space();
            if (this.text[this.at] === ']') {
                this.at++;
                return result;
            }
            this.expect(',');
            this.space();
        }
    }

    string(): string {
        this.at++;
        let out = '';
        for (;;) {
            const c = this.text[this.at];
            if (c === undefined) throw new JsonError('unterminated string');
            this.at++;
            if (c === '"') return out;
            if (c < ' ') throw new JsonError('control character in a string');
            if (c !== '\\') {
                out += c;
                continue;
            }
            const e = this.text[this.at++];
            if (e !== undefined && Object.hasOwn(ESCAPES, e)) {
                out += ESCAPES[e];
                continue;
            }
            if (e !== 'u') throw new JsonError('bad escape');
            const unit = this.hex4();
            if (unit >= 0xdc00 && unit <= 0xdfff) throw new JsonError('lone surrogate');
            if (unit >= 0xd800 && unit <= 0xdbff) {
                if (this.text[this.at] !== '\\' || this.text[this.at + 1] !== 'u') throw new JsonError('lone surrogate');
                this.at += 2;
                const low = this.hex4();
                if (low < 0xdc00 || low > 0xdfff) throw new JsonError('lone surrogate');
                out += String.fromCharCode(unit, low);
            } else {
                out += String.fromCharCode(unit);
            }
        }
    }

    hex4(): number {
        const digits = this.text.slice(this.at, this.at + 4);
        if (!/^[0-9a-fA-F]{4}$/.test(digits)) throw new JsonError('bad escape');
        this.at += 4;
        return parseInt(digits, 16);
    }

    expect(c: string): void {
        if (this.text[this.at] !== c) throw new JsonError(`expected ${c}`);
        this.at++;
    }
}

const MAX_SAFE = 2 ** 53 - 1;

/** §3: an unsigned integer (counters, epochs, sequence numbers): digits only, 0 to 2^53 − 1. */
export function unsignedValue(value: Json | undefined): number | null {
    if (!(value instanceof JsonNumber) || !/^(0|[1-9][0-9]*)$/.test(value.raw)) return null;
    const n = Number(value.raw);
    return n <= MAX_SAFE ? n : null;
}

/** §3: an item id that is a number: a non-zero signed safe integer. */
export function itemIdValue(value: Json | undefined): number | null {
    if (!(value instanceof JsonNumber) || !/^-?[1-9][0-9]*$/.test(value.raw)) return null;
    const n = Number(value.raw);
    return Math.abs(n) <= MAX_SAFE ? n : null;
}

export function isObject(value: Json | undefined): value is JsonObject {
    return typeof value === 'object' && value !== null && !Array.isArray(value) && !(value instanceof JsonNumber);
}

/** §3.1 writing: compact JSON, which JSON.stringify produces for well-formed strings. */
export function writeJson(value: unknown): Uint8Array {
    return Buffer.from(JSON.stringify(value), 'utf8');
}
