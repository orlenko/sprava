// Binder content remains text. This module never inserts decrypted values as markup or URLs.
import type { DisplayCache } from './display-cache.ts';
import type { OutboxPage } from './outbox.ts';
import { bucketNames } from './view-payloads.ts';

export function element<K extends keyof HTMLElementTagNameMap>(tag: K, text?: string): HTMLElementTagNameMap[K] {
    const node = document.createElement(tag);
    if (text !== undefined) node.textContent = text;
    return node;
}
function button(text: string, action: () => void): HTMLButtonElement {
    const node = element('button', text); node.type = 'button'; node.addEventListener('click', action); return node;
}
export interface Screens {
    banner: HTMLElement; code: HTMLElement; label: HTMLInputElement; pairButton: HTMLButtonElement;
    cancelButton: HTMLButtonElement; pairing: HTMLElement; paired: HTMLElement;
    draft: HTMLTextAreaElement; saveButton: HTMLButtonElement; refreshButton: HTMLButtonElement; removeButton: HTMLButtonElement;
    recovery: HTMLElement; draftStatus: HTMLElement;
    render(cache: DisplayCache, page: OutboxPage, lastReachedAt?: number): void;
}

/** Keep the editor mounted across refreshes, so incoming data never destroys an unsaved draft. */
export function mount(root: HTMLElement, actions: {
    pair: (label: string) => void; cancel: () => void; select: (id: string) => void;
    save: () => void; refresh: () => void; remove: () => void; next: (key: IDBValidKey) => void; first: () => void;
}): Screens {
    const banner = element('p'); banner.setAttribute('role', 'status'); banner.id = 'status';
    const heading = element('header'); heading.append(element('h1', 'Sprava'));
    const refreshButton = button('Refresh', actions.refresh); heading.append(refreshButton);
    const pairing = element('section'), paired = element('main'); paired.hidden = true;
    const label = element('input'); label.id = 'device-label'; label.maxLength = 80; label.autocomplete = 'off';
    const labelText = element('label', 'A name for this device'); labelText.htmlFor = label.id;
    const pairButton = button('Pair this device', () => actions.pair(label.value));
    const cancelButton = button('Cancel pairing', actions.cancel); cancelButton.hidden = true;
    const code = element('p'); code.id = 'pairing-code'; code.setAttribute('aria-live', 'polite');
    pairing.append(element('h2', 'Connect to your Mac'), element('p',
        'Open a pairing link from Sprava on your Mac. Keep the Mac open to compare the confirmation code.'),
        labelText, label, pairButton, cancelButton, code);
    const freshness = element('section'), binders = element('nav'), view = element('section');
    binders.setAttribute('aria-label', 'Binders'); view.id = 'binder-view';
    const composer = element('section'), draft = element('textarea'); draft.id = 'note'; draft.rows = 5; draft.maxLength = 20000;
    const recovery = element('section'), draftStatus = element('p'); draftStatus.setAttribute('role', 'status');
    const draftLabel = element('label', 'Note'); draftLabel.htmlFor = draft.id;
    const saveButton = button('Send note', actions.save);
    composer.append(element('h2', 'Send a note to Sprava'), recovery, draftLabel, draft, saveButton, draftStatus,
        element('p', 'Notes are saved on this device before sending. Your Mac applies them when it reconnects.'));
    const pending = element('section'); pending.id = 'pending';
    const removeButton = button('Remove this device’s pairing', actions.remove);
    paired.append(freshness, binders, view, composer, pending, removeButton); root.append(heading, banner, pairing, paired);
    return { banner, code, label, pairButton, cancelButton, pairing, paired, draft, saveButton, refreshButton, removeButton, recovery, draftStatus,
        render(cache, page, lastReachedAt) {
            const connected = cache.generation !== undefined;
            pairing.hidden = connected; paired.hidden = !connected; refreshButton.disabled = !connected;
            freshness.replaceChildren(); binders.replaceChildren(element('h2', 'Binders'));
            view.replaceChildren(); pending.replaceChildren(element('h2', 'Pending actions'));
            const pendingEntries = () => {
                for (const entry of page.entries) pending.append(element('p', `${entry.type} #${entry.seq}: ${entry.state} · ${entry.madeAt}`));
                if (!page.entries.length) pending.append(element('p', 'No pending actions on this page.'));
                pending.append(element('p', 'Sent means the relay received it. The action remains here until your Mac confirms the result.'));
                pending.append(button('First page', actions.first));
                if (page.next) pending.append(button('More actions', () => actions.next(page.next!)));
            };
            // Retired actions remain visible even without any pairing.
            if (!connected) { paired.hidden = false; composer.hidden = draft.value === ''; removeButton.hidden = true; pendingEntries(); return; }
            composer.hidden = false; removeButton.hidden = false;
            freshness.append(element('p', lastReachedAt === undefined ? 'Relay has not been reached in this session.' :
                `Last reached relay: ${new Date(lastReachedAt).toLocaleString()}`));
            const age = (title: string, value: string) => {
                const old = Date.now() - Date.parse(value.replace(':60Z', ':59Z')) > 26 * 3600000;
                freshness.append(element('p', `${title}: ${value}${old ? ' — over 26 hours old. Your Mac may need to publish again.' : ''}`));
            };
            if (cache.index) {
                age('Mac last published', cache.index.generatedAt);
                if (cache.index.binders.length === 0) binders.append(element('p', 'No binders shared with this device.'));
                for (const binder of cache.index.binders) {
                    const choice = button(binder.name, () => actions.select(binder.id));
                    if (binder.id === cache.binderId) choice.setAttribute('aria-current', 'true');
                    binders.append(choice);
                }
            } else binders.append(element('p', 'Waiting for a published index from your Mac.'));
            if (cache.view) {
                const v = cache.view; age('Binder last published', v.generatedAt);
                view.append(element('h2', v.binder.name));
                if (v.binder.description !== null) view.append(element('p', v.binder.description));
                if (v.notesOmitted) view.append(element('p', 'Item notes were omitted from this published view.'));
                const items = new Map(v.items.map(item => [item.id, item]));
                for (const bucket of bucketNames) {
                    const section = element('section'); section.append(element('h3', bucket.replaceAll('_', ' ')));
                    const list = element('ul');
                    for (const id of v.buckets[bucket]) {
                        const item = items.get(id)!;
                        const row = element('li'); row.append(element('strong', item.title), element('p', item.status));
                        if (item.due) row.append(element('p', `Due: ${item.due}`));
                        if (item.waitingOn) row.append(element('p', `Waiting on: ${item.waitingOn}`));
                        if (item.followUpAt) row.append(element('p', `Follow up: ${item.followUpAt}`));
                        if (item.notes !== null) row.append(element('p', item.notes));
                        list.append(row);
                    }
                    if (!list.childElementCount) section.append(element('p', 'Nothing here.'));
                    else section.append(list);
                    view.append(section);
                }
                view.append(element('h3', 'Recently closed'));
                for (const item of v.closed) view.append(element('p', `${item.title} — ${item.how}${item.closedAt ? ` · ${item.closedAt}` : ''}`));
                view.append(element('h3', 'Documents'));
                for (const document of v.documents) view.append(element('p', `${document.title}${document.date ? ` · ${document.date}` : ''}`));
            } else if (cache.binderId) view.append(element('p', 'Updating this binder. Its view must match the current index.'));
            else view.append(element('p', 'Choose a binder.'));
            pendingEntries();
        } };
}
