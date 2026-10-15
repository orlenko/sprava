// Item actions retain the exact typed id and published view version the person saw.
import { validateAction } from './device-payloads.ts';
import type { RequestAction, RequestType } from './device-payloads.ts';
import type { ViewItem } from './view-payloads.ts';
import { BrowserStore } from './browser-store.ts';
import type { Draft, DraftProof } from './drafts.ts';
import { encodeB64 } from './encoding.ts';
import { element } from './dom.ts';

export type ItemActionType = Exclude<RequestType, 'note'>;
export function allowedActions(item: ViewItem): ItemActionType[] {
    return ['done', 'drop', ...(item.status === 'open' ? (item.due ? ['postpone'] as const : []) :
        ['arrived', 'follow_up'] as const)];
}
export function itemAction(type: ItemActionType, binder: string, item: ViewItem, version: number, date?: string): RequestAction {
    if (!allowedActions(item).includes(type)) throw new Error('This action is unavailable for this item.');
    const waitingForDate = (type === 'follow_up' || type === 'postpone') && date === undefined;
    const action = validateAction({ type, binder, item: item.id, seenVersion: version, date: waitingForDate ? '2000-01-01' : date });
    // Validate the target now, but leave the editor's date empty; enqueue validates its final value again.
    return waitingForDate ? { ...action, date: null } : action;
}
const now = () => new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
interface Selection { generation: string; action: RequestAction }

/** One mounted date editor survives view refreshes; its protected draft also survives process termination. */
export class ItemControls {
    private readonly store: BrowserStore;
    private readonly permitted: (generation: string) => boolean;
    private readonly changed: () => void;
    private readonly message: (text: string) => void;
    private readonly panel = element('section');
    private readonly heading = element('h2');
    private readonly date = element('input');
    private readonly status = element('p');
    private readonly submit = element('button', 'Save date action');
    private readonly cancel = element('button', 'Cancel date action');
    private selection?: Selection;
    private editorId = encodeB64(crypto.getRandomValues(new Uint8Array(16)));
    private revision = 0;
    private durableRevision = 0;
    private proof?: DraftProof;
    private pending: Promise<void> = Promise.resolve();
    private readonly pendingActions = new Map<string, Promise<boolean>>();
    private readonly itemQueues = new Map<string, Promise<boolean>>();

    constructor(root: HTMLElement, store: BrowserStore, permitted: (generation: string) => boolean,
        changed: () => void, message: (text: string) => void) {
        this.store = store; this.permitted = permitted; this.changed = changed; this.message = message;
        this.panel.id = 'item-action'; this.panel.hidden = true; this.date.type = 'date'; this.date.id = 'item-action-date';
        const label = element('label', 'Date'); label.htmlFor = this.date.id;
        this.submit.type = this.cancel.type = 'button'; this.status.setAttribute('role', 'status');
        this.panel.append(this.heading, label, this.date, this.submit, this.cancel, this.status); root.append(this.panel);
        this.date.addEventListener('input', () => this.persist());
        this.submit.addEventListener('click', () => { void this.saveDate(); });
        this.cancel.addEventListener('click', () => { void this.discard(); });
    }
    open(generation: string, action: RequestAction, title: string): void {
        if (!this.permitted(generation)) { this.message('This pairing changed. Refresh before acting.'); return; }
        if (action.type !== 'follow_up' && action.type !== 'postpone') { void this.queue(generation, action); return; }
        if (this.selection) { this.message('Finish or cancel the current date action before choosing another.'); return; }
        this.selection = { generation, action: { ...action } }; this.editorId = encodeB64(crypto.getRandomValues(new Uint8Array(16)));
        this.revision = this.durableRevision = 0; this.proof = undefined; this.date.value = '';
        this.heading.textContent = `${action.type === 'follow_up' ? 'Follow up' : 'Postpone'}: ${title}`;
        this.panel.hidden = false; this.date.focus(); this.persist();
    }
    pairingChanged(): void {
        if (this.selection && !this.permitted(this.selection.generation)) {
            this.heading.textContent = 'Date action from an earlier pairing';
            this.status.textContent = 'Keep a copy of the date before closing. This action cannot be sent under another pairing.';
        }
    }
    hasUnsavedChanges(): boolean {
        return this.pendingActions.size > 0 || (this.selection !== undefined && (this.submit.disabled ||
            this.revision > this.durableRevision || (!this.permitted(this.selection.generation) && this.date.value !== '')));
    }
    restore(draft: Draft): void {
        if (this.selection || !this.permitted(draft.generation)) { this.message('Finish the current date action before recovering another.'); return; }
        try {
            const action = JSON.parse(draft.text) as RequestAction;
            if (action.type !== 'follow_up' && action.type !== 'postpone' || typeof action.date !== 'string') throw new Error();
            // Empty dates are valid editor state, never valid outbound actions. Restore only defined fields.
            const valid = validateAction({ ...action, date: action.date || '2000-01-01' });
            this.selection = { generation: draft.generation, action: { ...valid, date: action.date } };
            this.editorId = encodeB64(crypto.getRandomValues(new Uint8Array(16))); this.revision = this.durableRevision = 0; this.proof = undefined;
            this.date.value = action.date; this.heading.textContent = valid.type === 'follow_up' ? 'Recovered follow-up' : 'Recovered postponement';
            this.panel.hidden = false; this.persist({ editorId: draft.editorId, revision: draft.revision });
        } catch { this.message('This saved date action could not be opened. Its encrypted draft remains on this device.'); }
    }
    private persist(recovered?: DraftProof): void {
        const selection = this.selection; if (!selection) return;
        const action = { ...selection.action, date: this.date.value }, revision = ++this.revision, editorId = this.editorId;
        this.status.textContent = 'Saving encrypted date draft…';
        this.pending = this.pending.catch(() => {}).then(async () => {
            if (!await this.store.saveDraft(selection.generation, editorId, revision, JSON.stringify(action), now(), recovered, 'item-action'))
                throw new Error();
            this.proof = { editorId, revision };
            this.durableRevision = revision;
            if (revision === this.revision) this.status.textContent = action.date === '' ?
                'Action saved on this device; choose a date to finish.' : 'Encrypted date draft saved on this device.';
        });
        void this.pending.catch(() => { this.status.textContent = 'Date draft is not saved. Keep this window open and copy the date.'; });
    }
    private async saveDate(): Promise<void> {
        const selected = this.selection; if (!selected || this.submit.disabled) return;
        this.submit.disabled = this.cancel.disabled = this.date.disabled = true;
        try {
            await this.pending;
            if (await this.queue(selected.generation, { ...selected.action, date: this.date.value }, this.proof)) {
                this.selection = undefined; this.panel.hidden = true;
            }
        } catch { this.status.textContent = 'The action could not be saved. Keep the date and retry.'; }
        finally { this.submit.disabled = this.cancel.disabled = this.date.disabled = false; }
    }
    private async discard(): Promise<void> {
        const selected = this.selection; if (!selected || this.cancel.disabled) return;
        if (!this.permitted(selected.generation)) { this.selection = undefined; this.panel.hidden = true; return; }
        this.submit.disabled = this.cancel.disabled = this.date.disabled = true;
        try {
            await this.pending.catch(() => {});
            if (!await this.store.saveDraft(selected.generation, this.editorId, ++this.revision, '', now(), undefined, 'item-action')) throw new Error();
            this.selection = undefined; this.panel.hidden = true;
        } catch { this.status.textContent = 'The draft could not be discarded. Keep the date and retry.'; }
        finally { this.submit.disabled = this.cancel.disabled = this.date.disabled = false; }
    }
    private async queue(generation: string, action: RequestAction, proof?: DraftProof): Promise<boolean> {
        const item = JSON.stringify([generation, action.binder, action.item]);
        const key = JSON.stringify([generation, action.type, action.binder, action.item, action.seenVersion, action.date]);
        if (!this.permitted(generation)) { this.message('The pairing changed. This action was not queued; keep a copy of its date.'); return false; }
        const duplicate = this.pendingActions.get(key); if (duplicate) return duplicate;
        this.message('Saving action on this device…');
        const work = (this.itemQueues.get(item) ?? Promise.resolve(true)).then(async () => {
            if (!this.permitted(generation)) { this.message('The pairing changed. This action was not queued; keep a copy of its date.'); return false; }
            try {
                const entry = await this.store.enqueue(action, now(), generation, proof ? [proof] : []);
                if (entry.state !== 'queued') throw new Error();
                this.message('Action saved on this device. Your Mac will confirm the result.'); this.changed(); return true;
            } catch { this.message('The action could not be saved. Your date draft stays available; retry when ready.'); return false; }
        });
        this.pendingActions.set(key, work); this.itemQueues.set(item, work);
        try { return await work; }
        finally {
            if (this.pendingActions.get(key) === work) this.pendingActions.delete(key);
            if (this.itemQueues.get(item) === work) this.itemQueues.delete(item);
        }
    }
}
