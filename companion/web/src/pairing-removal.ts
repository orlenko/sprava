// Explicit removal of one captured pairing generation (companion-v0 §9.8 step 4).
import { BrowserStore, StorageError } from './browser-store.ts';
import { sealRevocation } from './device-payloads.ts';
import { RelayClient } from './relay-client.ts';

export interface RemovalCounts { notSent: number; unresolved: number }
export interface RemovalResult { removed: boolean; revokeConfirmed: boolean; counts?: RemovalCounts }
export interface RemovalEnvironment {
    fetcher?: typeof fetch; clock?: () => number; locks?: Pick<LockManager, 'request'>;
    notify?: (generation: string) => void;
}

/** Called only after the person asks; never infer removal from authentication or network errors. */
export async function removePairing(store: BrowserStore, generation: string,
    environment: RemovalEnvironment = {}): Promise<RemovalResult> {
    const p = (await store.read()).pairing;
    if (!p || p.generation !== generation) return { removed: false, revokeConfirmed: false };
    const locks = environment.locks ?? navigator.locks;
    if (!locks || typeof locks.request !== 'function') throw new StorageError();
    let revokeConfirmed = false;
    const controller = new AbortController(), timeout = setTimeout(() => controller.abort(), 30000);
    try {
        const stopped = new Promise<never>((_, reject) => {
            controller.signal.addEventListener('abort', () => reject(new StorageError()), { once: true });
        });
        const status = await Promise.race([stopped, (async () => {
            const bytes = await sealRevocation(p.deviceId, p.deviceKey, p.instanceId, generation,
                new Date((environment.clock ?? Date.now)()).toISOString().replace(/\.\d{3}Z$/, 'Z'));
            if (controller.signal.aborted) throw new StorageError();
            return new RelayClient(p.relayOrigin, p.deviceId, environment.fetcher).revoke(p.token, bytes, controller.signal);
        })()]);
        revokeConfirmed = status === 204;
    } catch { /* Local removal still proceeds; tell the person to remove the phone on the Mac too. */ }
    finally { clearTimeout(timeout); }
    environment.notify?.(generation);
    const counts = await locks.request('sprava-companion-send', { mode: 'exclusive' },
        () => store.removePairing(generation));
    return { removed: counts !== null, revokeConfirmed, counts: counts ?? undefined };
}
