// Device pairing orchestration and acknowledgement recovery (companion-v0 §5.2).
import type { BrowserStore, Reservation } from './browser-store.ts';
import { isId } from './encoding.ts';
import { helloPayload, sealHello } from './device-payloads.ts';
import { devicePairingKeys, newPairingKeyPair } from './pairing-keys.ts';
import type { PairingLink } from './pairing-link.ts';
import { RelayClient } from './relay-client.ts';

export class PairingFlowError extends Error {
    constructor(message = 'Pairing did not finish. Ask your Mac for a new pairing link.') { super(message); }
}
export interface PairingEnvironment {
    fetcher?: typeof fetch; clock?: () => number;
    wait?: (milliseconds: number, signal: AbortSignal) => Promise<void>;
    signal?: AbortSignal; onCode?: (code: string) => void;
}
export type Acknowledgement = 'acknowledged' | 'expired' | 'pending' | 'stale';
function expiry(value: string): number {
    // The protocol allows a leap second; Date.parse does not. Map it to the next POSIX second.
    return value.endsWith(':60Z') ? Date.parse(value.replace(':60Z', ':59Z')) + 1000 : Date.parse(value);
}
function pause(milliseconds: number, signal: AbortSignal): Promise<void> {
    return new Promise((resolve, reject) => {
        if (signal.aborted) { reject(new PairingFlowError()); return; }
        const cancel = () => { clearTimeout(timer); reject(new PairingFlowError()); };
        const timer = setTimeout(() => { signal.removeEventListener('abort', cancel); resolve(); }, milliseconds);
        signal.addEventListener('abort', cancel, { once: true });
    });
}
async function current(store: BrowserStore, reservation: Reservation): Promise<void> {
    const state = await store.read();
    if (state.pairing || state.reservation?.generation !== reservation.generation ||
        state.reservation.pairingId !== reservation.pairingId)
        throw new PairingFlowError('This pairing was cancelled. Use the current pairing link.');
}

/** One bounded flow owns G forever; errors never replace an installed pairing or retry an ambiguous join. */
export async function pairDevice(store: BrowserStore, input: PairingLink, label: string,
    environment: PairingEnvironment = {}): Promise<{ generation: string; acknowledgement: Acknowledgement }> {
    const clock = environment.clock ?? Date.now, wait = environment.wait ?? pause;
    let reservation: Reservation | null = null;
    const controller = new AbortController(), cancel = () => {
        controller.abort();
        if (reservation) void store.cancelReservation(reservation.generation).catch(() => {});
    };
    environment.signal?.addEventListener('abort', cancel, { once: true });
    if (environment.signal?.aborted) cancel();
    const timeout = setTimeout(cancel, 600000);
    try {
        const link = { ...input, ownerPublicKey: input.ownerPublicKey.slice() };
        if (!isId(link.pairingId) || !isId(link.secret)) throw new PairingFlowError();
        helloPayload(label); // Validate before cancelling any older reservation or using a number.
        if (controller.signal.aborted) throw new PairingFlowError();
        const client = new RelayClient(link.relayOrigin, link.deviceId, environment.fetcher);
        reservation = await store.reserve(link.pairingId);
        if (!reservation) throw new PairingFlowError('Remove this browser’s current pairing before using a new link.');
        const health = await client.health(controller.signal);
        if (health.status !== 200 || !health.value?.claimed) throw new PairingFlowError('Finish relay setup on your Mac, then pair again.');
        const keys = await devicePairingKeys(link.pairingId, link.deviceId, link.ownerPublicKey, await newPairingKeyPair());
        const hello = await sealHello(link.pairingId, keys.wrap, label);
        const start = clock(); let backoff = 5000;
        let joined;
        for (;;) {
            await current(store, reservation);
            if (controller.signal.aborted || clock() >= start + 600000) throw new PairingFlowError();
            // Only an explicit 503 is retried. A lost response may have joined and cannot be retried.
            joined = await client.join(link.pairingId, link.secret, keys.publicKey, hello, controller.signal);
            if (joined.status !== 503) break;
            await wait(backoff, controller.signal); backoff = Math.min(30000, backoff * 2);
        }
        if (joined.status !== 200 || !joined.value) {
            if (joined.status === 507) throw new PairingFlowError('The relay already holds 20 devices. Remove one on your Mac and use a new link.');
            throw new PairingFlowError();
        }
        const expiresAt = joined.value.expiresAt, deadline = Math.min(expiry(expiresAt), start + 600000);
        environment.onCode?.(keys.code);
        for (;;) {
            await current(store, reservation);
            if (controller.signal.aborted || clock() >= deadline) throw new PairingFlowError();
            const delivery = await client.pairingKey(link.pairingId, joined.value.token, controller.signal);
            if (delivery.status === 200 && delivery.value) {
                if (controller.signal.aborted || clock() >= deadline) throw new PairingFlowError();
                const installed = await store.install(reservation, { deviceId: link.deviceId, relayOrigin: link.relayOrigin,
                    instanceId: health.value.instance, token: joined.value.token, expiresAt,
                    deviceKey: keys.device, wrapKey: keys.wrap, delivery: delivery.value });
                if (!installed) throw new PairingFlowError('This pairing was cancelled. Use the current pairing link.');
                // Installation resolved only after strict completion; only now can any acknowledgement leave.
                const acknowledgement = await resumeAcknowledgement(store, environment, reservation.generation);
                return { generation: reservation.generation, acknowledgement };
            }
            if (delivery.status !== 404 && delivery.status !== 503 && delivery.status < 500) throw new PairingFlowError();
            await wait(2000, controller.signal);
        }
    } catch (error) {
        if (reservation) {
            try { await store.cancelReservation(reservation.generation); } catch { /* Leave unreadable storage unchanged. */ }
        }
        if (error instanceof PairingFlowError) throw error;
        throw new PairingFlowError();
    } finally {
        clearTimeout(timeout); environment.signal?.removeEventListener('abort', cancel);
    }
}

/** Startup/refresh retries pending acknowledgements; stale replies cannot clear a new pairing's flag. */
export async function resumeAcknowledgement(store: BrowserStore,
    environment: Pick<PairingEnvironment, 'fetcher' | 'clock' | 'signal'> = {}, expectedGeneration?: string): Promise<Acknowledgement> {
    try {
        const p = (await store.read()).pairing;
        if (!p || !p.acknowledgementPending || (expectedGeneration !== undefined && p.generation !== expectedGeneration)) return 'stale';
        const status = await new RelayClient(p.relayOrigin, p.deviceId, environment.fetcher)
            .acknowledge(p.pairingId, p.token, environment.signal);
        const result = status === 204 ? 'acknowledged' :
            status === 404 && (environment.clock ?? Date.now)() >= expiry(p.expiresAt) ? 'expired' : 'pending';
        if (result === 'pending') return result;
        return await store.acknowledged(p.generation, p.pairingId) ? result : 'stale';
    } catch { return 'pending'; }
}
