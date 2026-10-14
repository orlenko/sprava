import { BrowserStore } from './browser-store.ts';
import { consumePairingLink } from './pairing-link.ts';
import { pairDevice } from './pairing-flow.ts';
import { refresh } from './refresh.ts';
import { readDisplayCache } from './display-cache.ts';
import { RelayClient } from './relay-client.ts';
import { sendOne } from './sender.ts';
import { mount, element } from './screens.ts';
import { removePairing } from './pairing-removal.ts';

const root = document.getElementById('app')!;
// Refuse a frame before reading a pairing fragment, opening storage, or accessing keys.
if (window.top !== window.self) root.replaceChildren(element('p', 'Open Sprava in its own window.'));
else if (!isSecureContext || !crypto.subtle || !navigator.locks || !indexedDB)
    root.replaceChildren(element('p', 'Sprava needs a secure browser with WebCrypto, IndexedDB and Web Locks.'));
else void start().catch(() => root.replaceChildren(element('p', 'Sprava could not open browser storage. Reload to try again.')));

async function start(): Promise<void> {
    let link: ReturnType<typeof consumePairingLink> = null;
    let invalidLink = false;
    try { link = consumePairingLink(location, history); } catch { invalidLink = true; }
    const store = await BrowserStore.open();
    let selected: string | undefined, generation: string | undefined, draftGeneration: string | undefined;
    let pageAfter: IDBValidKey | undefined, lastReachedAt: number | undefined;
    let pairing: AbortController | undefined, busy = false, queued = false, saving = false;
    let sendTimer: ReturnType<typeof setTimeout> | undefined;
    const retiring = new Set<string>();
    let activeSend: { generation: string; controller: AbortController } | undefined;
    const channel = typeof BroadcastChannel === 'function' ? new BroadcastChannel('sprava-companion') : undefined;
    const screen = mount(root, {
        pair: label => { void connect(label).catch(failed); }, cancel: () => { pairing?.abort(); },
        select: id => { selected = id; void draw().then(cycle).catch(failed); },
        save: () => { void save().catch(failed); }, refresh: () => { void cycle(); },
        remove: () => { void disconnect().catch(failed); },
        next: key => { pageAfter = key; void draw().catch(failed); },
        first: () => { pageAfter = undefined; void draw().catch(failed); },
    });
    const tell = (message: string) => { screen.banner.textContent = message; };
    const failed = () => tell('The operation could not finish. Your note stays in the editor; retry when ready.');
    screen.draft.addEventListener('input', () => {
        if (screen.draft.value === '') draftGeneration = undefined;
        else draftGeneration ??= generation;
    });
    if (invalidLink) tell('This pairing link is invalid. Ask your Mac for a new link.');
    if (!link) screen.pairButton.disabled = true;

    async function draw(): Promise<void> {
        const cache = await readDisplayCache(store, selected);
        generation = cache.generation;
        if (selected && cache.index && !cache.index.binders.some(b => b.id === selected)) selected = undefined;
        screen.render(cache, await store.readOutbox(50, pageAfter), lastReachedAt);
        screen.saveButton.disabled = saving || !generation;
        if (screen.draft.value && draftGeneration !== generation)
            tell('This draft belongs to an earlier pairing. Keep a copy, then clear it before writing for this pairing.');
        if (generation && link) tell('This browser is already paired. A new link cannot replace its pairing.');
    }
    async function connect(label: string): Promise<void> {
        if (!link || pairing) return;
        const controller = new AbortController(); pairing = controller;
        screen.pairButton.disabled = true; screen.label.disabled = true; screen.cancelButton.hidden = false;
        tell('Connecting. Compare the code on your Mac before approving.');
        try {
            await pairDevice(store, link, label, { signal: controller.signal,
                onCode: code => { screen.code.textContent = `Confirmation code: ${code}`; } });
            link = null; screen.code.textContent = ''; tell('Paired. Waiting for your Mac to publish.');
            channel?.postMessage('changed'); await draw(); await cycle();
        } catch { link = null; tell('Pairing did not finish. Ask your Mac for a new pairing link.'); await draw(); }
        finally { pairing = undefined; screen.label.disabled = false; screen.cancelButton.hidden = true; }
    }
    async function save(): Promise<void> {
        if (saving || !generation || retiring.has(generation) || !screen.draft.value) return;
        saving = true; screen.saveButton.disabled = true; screen.draft.disabled = true;
        const text = screen.draft.value, expected = draftGeneration ?? generation;
        try {
            const entry = await store.enqueue({ type: 'note', text }, new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'), expected);
            if (entry.state !== 'queued') { tell('The pairing changed. Your note has not been sent; keep your draft.'); return; }
            screen.draft.value = ''; draftGeneration = undefined;
            tell('Note saved on this device. It will be sent when the relay is reachable.');
            channel?.postMessage('changed');
        } catch { failed(); }
        finally { saving = false; screen.draft.disabled = false; await draw(); void cycle(); }
    }
    function stop(generation: string): void {
        retiring.add(generation);
        if (activeSend?.generation === generation) activeSend.controller.abort();
    }
    async function disconnect(): Promise<void> {
        const original = generation;
        if (!original || retiring.has(original) || !window.confirm(
            'Remove this device’s pairing and its saved binder data? Unconfirmed actions remain visible. Keep a copy of any unsaved note first.')) return;
        stop(original); screen.removeButton.disabled = true; screen.saveButton.disabled = true;
        try {
            const result = await removePairing(store, original, { notify: value => {
                stop(value); channel?.postMessage({ type: 'remove', generation: value });
            } });
            if (result.removed) {
                selected = undefined; pageAfter = undefined; lastReachedAt = undefined;
                tell(`Pairing removed. ${result.counts!.notSent} actions not sent; ${result.counts!.unresolved} unresolved (may have reached your Mac).` +
                    (result.revokeConfirmed ? '' : ' Also remove this phone on your Mac; the relay did not confirm revocation.'));
            } else tell('This pairing was already changed by another window.');
            channel?.postMessage('changed'); await draw();
        } catch {
            retiring.delete(original); channel?.postMessage({ type: 'resume', generation: original });
            tell('Browser storage could not remove this pairing. Its saved data remains; retry removal.');
            await draw();
        } finally { screen.removeButton.disabled = false; }
    }
    async function cycle(): Promise<void> {
        if (busy) { queued = true; return; }
        busy = true; screen.refreshButton.disabled = true; clearTimeout(sendTimer);
        try {
            const result = await refresh(store, selected);
            if (result.lastReachedAt !== undefined) lastReachedAt = result.lastReachedAt;
            if (result.status === 'offline') tell('Relay unavailable. Showing admitted data saved on this device.');
            if (result.status === 'refused') tell('The relay refused this device. Saved data and keys remain on this device.');
            let after: IDBValidKey | null = null;
            // Expiry is paged, with no whole-queue ciphertext read.
            do { after = await store.expireOutbox(Date.now(), 100, after ?? undefined); } while (after !== null);
            await draw();
            if (result.status !== 'refused') {
                for (let count = 0; count < 20; count++) {
                    const p = (await store.read()).pairing;
                    if (!p || retiring.has(p.generation)) break;
                    const controller = new AbortController(); activeSend = { generation: p.generation, controller };
                    const sent = await sendOne(store, (attempt, signal) => {
                        activeSend = { generation: attempt.generation, controller };
                        if (retiring.has(attempt.generation)) throw new Error('Pairing is being removed.');
                        return new RelayClient(attempt.relayOrigin, attempt.deviceId).send(attempt, signal);
                    }, navigator.locks, Date.now, controller.signal);
                    activeSend = undefined;
                    if (sent !== 'recorded') break;
                    channel?.postMessage('changed');
                }
            }
            await draw();
        } catch { failed(); }
        finally {
            busy = false;
            // Backoff deadlines are rechecked in IDB; all waiting is outside the shared send lock.
            sendTimer = setTimeout(() => { void cycle(); }, queued ? 0 : 10000); queued = false;
        }
    }
    channel?.addEventListener('message', event => {
        const message = event.data;
        if (message?.type === 'remove' && typeof message.generation === 'string') stop(message.generation);
        if (message?.type === 'resume' && typeof message.generation === 'string') retiring.delete(message.generation);
        void draw().then(cycle).catch(failed);
    });
    window.addEventListener('online', () => { void cycle(); });
    window.addEventListener('beforeunload', event => {
        if (screen.draft.value) { event.preventDefault(); event.returnValue = ''; }
    });
    document.addEventListener('visibilitychange', () => { if (!document.hidden) void cycle(); });
    await draw(); void cycle();
    if ('serviceWorker' in navigator) void navigator.serviceWorker.register('./sw.js').catch(() => {
        tell('Offline app loading is unavailable in this browser.');
    });
    void fetch('./release.json', { cache: 'no-cache' }).then(r => r.json()).then((v: unknown) => {
        if (typeof v !== 'object' || v === null) return;
        const release = v as { version?: unknown; commit?: unknown };
        if (typeof release.version === 'string' && typeof release.commit === 'string')
            root.append(element('footer', `Sprava ${release.version} · ${release.commit}`));
    }).catch(() => {});
}
