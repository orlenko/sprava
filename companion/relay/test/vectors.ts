// The shared test vectors of companion-v0 §14, in companion/testdata.
import { readFileSync } from 'node:fs';

const path = new URL('../../testdata/companion-v0-vectors.json', import.meta.url);

// The vectors file is ours and trusted; JSON.parse is fine here.
export const vectors: any = JSON.parse(readFileSync(path, 'utf8'));

/** The bytes of a vector text: `text` as UTF-8, `hex`, or `fill` (before + repeat… + after, `length` bytes). */
export function vectorBytes(entry: { text?: string; hex?: string; fill?: { before: string; repeat: string; after: string; length: number } }): Uint8Array {
    if (entry.text !== undefined) return new Uint8Array(Buffer.from(entry.text, 'utf8'));
    if (entry.hex !== undefined) return new Uint8Array(Buffer.from(entry.hex, 'hex'));
    const { before, repeat, after, length } = entry.fill!;
    const middle = repeat.repeat(length - before.length - after.length);
    return new Uint8Array(Buffer.from(before + middle + after, 'utf8'));
}
