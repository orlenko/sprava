// Signed device outcomes and exact padding validation (companion-v0 §8.7).
import { isId } from './encoding.ts';
import { integer, isTime, object, PayloadError } from './payload.ts';
import { openPayload } from './sealed.ts';

export type Outcome = 'applied' | 'conflict' | 'rejected' | 'unknown';
export interface DeviceOutcome { requestId: string; seq: number; outcome: Outcome; decidedAt: string }
export interface DeviceOutcomes { revision: number; generatedAt: string; outcomes: DeviceOutcome[] }

/** Results remain provisional until revision and matching outbox changes commit together (§§9.8, 10.2). */
export async function openOutcomes(deviceId: string, revision: number, deviceKey: CryptoKey,
    ownerKey: CryptoKey, bytes: Uint8Array): Promise<DeviceOutcomes> {
    try {
        if (!isId(deviceId) || !Number.isSafeInteger(revision) || revision < 1) throw new PayloadError();
        const { value, plaintextLength } = await openPayload(`devices/${deviceId}/outcomes/${revision}`,
            0, deviceKey, bytes, ownerKey);
        if (value.device_id !== deviceId || integer(value.revision, 1) !== revision || !isTime(value.generated_at) ||
            !Array.isArray(value.outcomes) || value.outcomes.length > 2000 || typeof value.pad !== 'string' ||
            /[^ ]/.test(value.pad) || plaintextLength !== 512 + 128 * value.outcomes.length) throw new PayloadError();
        const ids = new Set<string>();
        const outcomes = value.outcomes.map(entry => {
            const item = object(entry);
            if (typeof item.request_id !== 'string' || !isId(item.request_id) || ids.has(item.request_id) ||
                !isTime(item.decided_at) || typeof item.outcome !== 'string' ||
                !['applied', 'conflict', 'rejected', 'unknown'].includes(item.outcome))
                throw new PayloadError();
            ids.add(item.request_id);
            return { requestId: item.request_id, seq: integer(item.seq, 1), outcome: item.outcome as Outcome,
                decidedAt: item.decided_at };
        });
        return { revision, generatedAt: value.generated_at, outcomes };
    } catch { throw new PayloadError(); }
}
