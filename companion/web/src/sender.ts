// One bounded attempt under the shared send lock; backoff waits happen elsewhere (§9.8 step 2).
import type { BrowserStore } from './browser-store.ts';
import type { SendAttempt } from './outbox-state.ts';
import { OutboxError } from './outbox.ts';
export type SendTransport = (attempt: SendAttempt, signal: AbortSignal) => Promise<number>;
export type SendResult = 'idle' | 'recorded' | 'stale';

/** The transport must honor AbortSignal; an HTTP implementation must also refuse redirects/credential forwarding. */
export async function sendOne(store: BrowserStore, transport: SendTransport,
    locks: Pick<LockManager, 'request'> = navigator.locks, clock: () => number = Date.now,
    signal?: AbortSignal): Promise<SendResult> {
    if (!locks || typeof locks.request !== 'function') throw new OutboxError();
    if (signal?.aborted) return 'idle';
    return locks.request('sprava-companion-send', { mode: 'exclusive', signal }, async () => {
        if (signal?.aborted) return 'idle';
        const attempt = await store.beginAttempt(clock());
        if (!attempt) return 'idle';
        const controller = new AbortController(), cancel = () => controller.abort();
        signal?.addEventListener('abort', cancel, { once: true });
        let timeout: ReturnType<typeof setTimeout> | undefined;
        let status: number | null = null;
        try {
            if (signal?.aborted) cancel();
            const stopped = new Promise<never>((_, reject) => {
                controller.signal.addEventListener('abort', () => reject(new OutboxError()), { once: true });
                if (controller.signal.aborted) reject(new OutboxError());
            });
            timeout = setTimeout(cancel, 30000);
            status = await Promise.race([stopped, Promise.resolve().then(() => {
                if (controller.signal.aborted) throw new OutboxError();
                return transport(attempt, controller.signal);
            })]);
        } catch { /* A network failure is ambiguous: retain immutable bytes and retry. */ }
        finally { clearTimeout(timeout); signal?.removeEventListener('abort', cancel); }
        return await store.recordAttempt(attempt, status, clock()) ? 'recorded' : 'stale';
    });
}
