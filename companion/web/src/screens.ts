// Binder content remains text. This module never inserts decrypted values as markup or URLs.
import type { DisplayCache } from './display-cache.ts';
import type { OutboxPage } from './outbox.ts';
import type { BinderView, BucketName, ViewItem } from './view-payloads.ts';
import { allowedActions, itemAction } from './item-controls.ts';
import type { ItemActionType } from './item-controls.ts';
import type { RequestAction } from './device-payloads.ts';
import { dayLabel, itemFacts, localDay, pendingLabel, timeLabel } from './format.ts';
import { element } from './dom.ts';
export { element } from './dom.ts';
function button(text: string, action: () => void, kind?: 'secondary' | 'danger' | 'tab'): HTMLButtonElement {
    const node = element('button', text); node.type = 'button'; node.addEventListener('click', action);
    if (kind) node.className = kind;
    return node;
}
function note(text: string, className = 'muted'): HTMLParagraphElement {
    const node = element('p', text); node.className = className; return node;
}
export interface Screens {
    banner: HTMLElement; code: HTMLElement; label: HTMLInputElement; pairButton: HTMLButtonElement;
    cancelButton: HTMLButtonElement; pairing: HTMLElement; paired: HTMLElement;
    draft: HTMLTextAreaElement; saveButton: HTMLButtonElement; refreshButton: HTMLButtonElement; removeButton: HTMLButtonElement;
    recovery: HTMLElement; draftStatus: HTMLElement;
    /** Whether a pairing link was opened: only then can this phone be named and paired. */
    linkPresent(present: boolean): void;
    render(cache: DisplayCache, page: OutboxPage, lastReachedAt?: number, paging?: boolean): void;
}

const bucketTitles: Record<BucketName, string> = { overdue: 'Overdue', today: 'Due today', next_7_days: 'Next 7 days',
    later: 'Later', no_deadline: 'No deadline', nudge: 'Time to follow up', waiting: 'Waiting' };
const actionLabels: Record<ItemActionType, string> = { done: 'Done', drop: 'Drop', arrived: 'Arrived',
    follow_up: 'Follow up…', postpone: 'Postpone…' };
const actionOrder: ItemActionType[] = ['done', 'arrived', 'follow_up', 'postpone', 'drop'];
const STALE = 26 * 3600000;

/** Keep the editor mounted across refreshes, so incoming data never destroys an unsaved draft. */
export function mount(root: HTMLElement, actions: {
    pair: (label: string) => void; cancel: () => void; select: (id?: string) => void;
    save: () => void; refresh: () => void; remove: () => void; next: (key: IDBValidKey) => void; first: () => void;
    item: (generation: string, action: RequestAction, title: string) => void;
}): Screens {
    const banner = element('p'); banner.setAttribute('role', 'status'); banner.id = 'status';
    const heading = element('header'); heading.append(element('h1', 'Sprava'));
    const refreshButton = button('Refresh', actions.refresh, 'secondary'); heading.append(refreshButton);

    const pairing = element('section'), paired = element('main'); pairing.id = 'pairing'; paired.hidden = true;
    const label = element('input'); label.id = 'device-label'; label.maxLength = 40; label.autocomplete = 'off';
    label.placeholder = 'For example, Pixel';
    const labelText = element('label', 'Name this phone, to tell it apart on your Mac'); labelText.htmlFor = label.id;
    const pairButton = button('Pair this phone', () => actions.pair(label.value.trim()));
    const cancelButton = button('Cancel', actions.cancel, 'secondary'); cancelButton.hidden = true;
    const code = element('p'); code.id = 'pairing-code'; code.setAttribute('aria-live', 'polite');
    const withoutLink = note('On your Mac, open Sprava, then Settings › Phone, and scan its pairing code with this phone’s camera. ' +
        'The link it opens brings you back here.', '');
    const withLink = element('div'); withLink.append(labelText, label, pairButton, cancelButton);
    pairing.append(element('h2', 'Connect to your Mac'), withoutLink, withLink, code);

    const freshness = element('p'); freshness.className = 'muted'; freshness.id = 'freshness';
    const binders = element('nav'), view = element('section');
    binders.setAttribute('aria-label', 'Binders'); view.id = 'binder-view';
    const composer = element('section'), draft = element('textarea'); draft.id = 'note'; draft.rows = 4; draft.maxLength = 20000;
    composer.id = 'composer';
    const recovery = element('section'), draftStatus = element('p'); draftStatus.setAttribute('role', 'status');
    draftStatus.className = 'muted';
    const draftLabel = element('label', 'A note for your Mac’s inbox'); draftLabel.htmlFor = draft.id;
    const saveButton = button('Send note', actions.save);
    composer.append(element('h2', 'Note'), recovery, draftLabel, draft, saveButton, draftStatus,
        note('Saved on this phone first, and sent when the relay can be reached. Your Mac files it.'));
    const pending = element('section'); pending.id = 'pending';
    const device = element('section'); device.id = 'device';
    const removeButton = button('Remove this phone’s pairing', actions.remove, 'danger');
    device.append(element('h2', 'This phone'), note('Removing the pairing deletes the keys and saved binders on this phone.'),
        removeButton);
    paired.append(freshness, binders, view, composer, pending, device); root.append(heading, banner, pairing, paired);

    let hasLink = false;
    // Pairing needs a link and a name: an empty name would otherwise spend the link on a local failure.
    const pairable = () => { pairButton.disabled = !hasLink || label.disabled || label.value.trim() === ''; };
    label.addEventListener('input', pairable);
    const linkPresent = (present: boolean) => {
        hasLink = present; withLink.hidden = !present; withoutLink.hidden = present; pairable();
    };
    linkPresent(false);

    function itemRow(generation: string, binderId: string, v: BinderView, item: ViewItem, today: string, binderName?: string) {
        const row = element('li');
        if (binderName !== undefined) row.append(note(binderName, 'binder-name'));
        row.append(element('strong', item.title));
        for (const fact of itemFacts(item, today))
            row.append(note(fact, fact.startsWith('Overdue') || fact.startsWith('Follow up: due') ? 'fact urgent' : 'fact'));
        if (item.notes !== null) row.append(note(item.notes, 'notes'));
        const labels = [...item.tags.map(t => `#${t}`), ...item.contexts.map(c => `@${c}`)];
        if (labels.length) row.append(note(labels.join(' '), 'tags'));
        const controls = element('div'); controls.className = 'actions';
        const allowed = allowedActions(item);
        for (const type of actionOrder.filter(t => allowed.includes(t)))
            controls.append(button(actionLabels[type], () => actions.item(generation, itemAction(type, binderId, item, v.version), item.title),
                type === 'done' ? undefined : 'secondary'));
        row.append(controls);
        return row;
    }
    function group(title: string, rows: HTMLLIElement[]): HTMLElement {
        const section = element('section'); section.className = 'bucket';
        const list = element('ul'); list.append(...rows);
        section.append(element('h3', `${title} (${rows.length})`), list);
        return section;
    }

    return { banner, code, label, pairButton, cancelButton, pairing, paired, draft, saveButton, refreshButton, removeButton, recovery, draftStatus,
        linkPresent,
        render(cache, page, lastReachedAt, paging = false) {
            const connected = cache.generation !== undefined, now = new Date(), today = localDay(now);
            pairing.hidden = connected; paired.hidden = !connected;
            refreshButton.hidden = !connected; refreshButton.disabled = !connected;
            binders.replaceChildren(); view.replaceChildren(); pending.replaceChildren(); freshness.replaceChildren();
            if (!connected) pairable();
            if (page.entries.length || paging) {
                pending.append(element('h2', 'Waiting for your Mac'));
                const list = element('ul');
                for (const entry of page.entries) list.append(element('li', pendingLabel(entry, now)));
                pending.append(list, note('“Sent” means the relay has it. Each action stays here until your Mac says what it did.'));
                if (paging) pending.append(button('Back to the newest', actions.first, 'secondary'));
                if (page.next) pending.append(button('Older actions', () => actions.next(page.next!), 'secondary'));
            }
            // Retired actions and an unsent note remain visible even without any pairing.
            if (!connected) {
                paired.hidden = draft.value === '' && !pending.childElementCount;
                composer.hidden = draft.value === ''; device.hidden = true; freshness.hidden = true; binders.hidden = true;
                return;
            }
            composer.hidden = false; device.hidden = false; freshness.hidden = false; binders.hidden = false;
            const published = [cache.index?.generatedAt, cache.view?.generatedAt].filter((t): t is string => t !== undefined)
                .sort()[0];
            const reached = lastReachedAt === undefined ? 'Not connected to the relay yet.' :
                `Last checked: ${timeLabel(new Date(lastReachedAt).toISOString(), now)}.`;
            freshness.append(published === undefined ? reached : `Updated by your Mac: ${timeLabel(published, now)}. ${reached}`);
            if (published !== undefined && now.getTime() - Date.parse(published.replace(':60Z', ':59Z')) > STALE) {
                freshness.className = 'warning';
                freshness.append(' This is over a day old: your Mac may be asleep or offline.');
            } else freshness.className = 'muted';

            if (!cache.index) {
                view.append(note('Waiting for your Mac to publish your binders. Keep Sprava open on the Mac.', ''));
                return;
            }
            const tab = (text: string, id?: string) => {
                const choice = button(text, () => actions.select(id), 'tab');
                if (id === cache.binderId) choice.setAttribute('aria-current', 'page');
                binders.append(choice);
            };
            tab('Today');
            for (const binder of cache.index.binders) tab(binder.name, binder.id);
            if (cache.index.binders.length === 0) {
                view.append(note('No binders are shown on this phone yet. On your Mac, turn on “Show on my phone” in a binder’s settings.', ''));
                return;
            }
            const generation = cache.generation!, views = cache.views ?? new Map<string, BinderView>();
            if (cache.binderId === undefined) {
                view.append(element('h2', 'Today'));
                let any = false;
                for (const bucket of ['overdue', 'today', 'nudge'] as const) {
                    const rows: HTMLLIElement[] = [];
                    for (const binder of cache.index.binders) {
                        const v = views.get(binder.id); if (!v) continue;
                        const items = new Map(v.items.map(item => [item.id, item]));
                        for (const id of v.buckets[bucket]) rows.push(itemRow(generation, binder.id, v, items.get(id)!, today, binder.name));
                    }
                    if (rows.length) { any = true; view.append(group(bucketTitles[bucket], rows)); }
                }
                const missing = cache.index.binders.filter(b => !views.has(b.id)).length;
                if (!any) view.append(note(missing ? 'Nothing due today in the binders loaded so far.' :
                    'Nothing overdue, due today or to follow up. Choose a binder above to see the rest.', 'all-clear'));
                if (missing) view.append(note(`${missing === 1 ? 'One binder is' : `${missing} binders are`} still loading.`));
                return;
            }
            const v = cache.view;
            if (!v) { view.append(note('Loading this binder from the relay…', '')); return; }
            view.append(element('h2', v.binder.name));
            if (v.binder.description !== null) view.append(note(v.binder.description, 'description'));
            if (v.notesOmitted) view.append(note('Item notes are left out: this binder is too large to publish them.'));
            const items = new Map(v.items.map(item => [item.id, item]));
            for (const bucket of ['overdue', 'today', 'nudge', 'next_7_days', 'later', 'no_deadline', 'waiting'] as const) {
                const rows = v.buckets[bucket].map(id => itemRow(generation, cache.binderId!, v, items.get(id)!, today));
                if (rows.length) view.append(group(bucketTitles[bucket], rows));
            }
            if (!v.items.length) view.append(note('No open to-dos in this binder.', 'all-clear'));
            if (v.closed.length) {
                const closed = element('details'), list = element('ul'); closed.className = 'closed';
                closed.append(element('summary', `Recently closed (${v.closed.length})`));
                for (const item of v.closed) list.append(element('li', `${item.title} · ${item.how === 'done' ? 'done' : 'dropped'}` +
                    (item.closedAt ? ` ${item.closedAt.length === 10 ? dayLabel(item.closedAt, today) : timeLabel(item.closedAt, now)}` : '')));
                closed.append(list); view.append(closed);
            }
            if (v.documents.length) {
                const documents = element('details'), list = element('ul'); documents.className = 'documents';
                documents.append(element('summary', `Documents (${v.documents.length})`));
                for (const d of v.documents) list.append(element('li', d.date ? `${d.title} · ${dayLabel(d.date, today)}` : d.title));
                documents.append(list); view.append(documents);
            }
        } };
}
