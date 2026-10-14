// Local encrypted editor drafts, separate from numbered protocol requests.
import type { BrowserState, Pairing } from './browser-store.ts';
import { isId, utf8 } from './encoding.ts';
import { isTime } from './payload.ts';

export class DraftError extends Error { constructor() { super('The draft could not be saved on this device.'); } }
export interface DraftProof { editorId: string; revision: number }
export type DraftKind = 'note' | 'item-action';
export interface Draft extends DraftProof { generation: string; updatedAt: string; text: string; kind: DraftKind }
export interface DraftPage { drafts: Draft[]; next?: string }
interface StoredDraft extends DraftProof { generation: string; updatedAt: string; nonce: Uint8Array; bytes: Uint8Array; kind?: DraftKind }
const aad = (generation: string, editorId: string, kind: DraftKind) =>
    utf8(`sprava-companion/local-draft/v1|${generation}|${editorId}${kind === 'note' ? '' : '|item-action'}`);
async function pairing(db: IDBDatabase): Promise<Pairing | undefined> {
    return new Promise((resolve, reject) => {
        let tx: IDBTransaction;
        try { tx = db.transaction('state', 'readonly'); } catch { reject(new DraftError()); return; }
        const request = tx.objectStore('state').get('current');
        tx.oncomplete = () => resolve((request.result as BrowserState | undefined)?.pairing);
        tx.onabort = tx.onerror = () => reject(new DraftError());
    });
}
/** Every window owns a fresh editor id. Its increasing revisions prevent late encryption from overwriting newer text. */
export async function saveDraft(db: IDBDatabase, generation: string, editorId: string, revision: number,
    text: string, updatedAt: string, recovered?: DraftProof, kind: DraftKind = 'note'): Promise<boolean> {
    if (!isId(generation) || !isId(editorId) || !Number.isSafeInteger(revision) || revision < 1 ||
        text.length > 20000 || !isTime(updatedAt) || !['note', 'item-action'].includes(kind) || (recovered !== undefined && (!isId(recovered.editorId) ||
        !Number.isSafeInteger(recovered.revision) || recovered.revision < 1 || recovered.editorId === editorId))) throw new DraftError();
    recovered = recovered ? { ...recovered } : undefined;
    const p = await pairing(db); if (!p || p.generation !== generation) return false;
    // Preserve every UTF-16 code unit, including temporarily incomplete input and invalid note controls.
    const plain = new Uint8Array(text.length * 2);
    for (let i = 0; i < text.length; i++) { const value = text.charCodeAt(i); plain[i * 2] = value >>> 8; plain[i * 2 + 1] = value & 255; }
    const nonce = crypto.getRandomValues(new Uint8Array(12));
    let bytes: Uint8Array;
    try { bytes = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce,
        additionalData: aad(generation, editorId, kind) }, p.deviceKey, plain)); }
    catch { throw new DraftError(); } finally { plain.fill(0); }
    return new Promise((resolve, reject) => {
        let tx: IDBTransaction;
        try {
            tx = db.transaction(['state', 'drafts'], 'readwrite', { durability: 'strict' });
            if (tx.durability !== 'strict') { tx.abort(); throw new DraftError(); }
        } catch { reject(new DraftError()); return; }
        let saved = false;
        tx.oncomplete = () => resolve(saved); tx.onabort = tx.onerror = () => reject(new DraftError());
        const state = tx.objectStore('state').get('current'), store = tx.objectStore('drafts');
        state.onsuccess = () => {
            try {
                const current = (state.result as BrowserState | undefined)?.pairing;
                if (current?.generation !== generation || current.deviceId !== p.deviceId) return;
                const old = store.get([generation, editorId]);
                old.onsuccess = () => {
                    try {
                        if (old.result && old.result.revision >= revision) return;
                        store.put({ generation, editorId, revision, updatedAt, nonce, bytes, kind } satisfies StoredDraft, [generation, editorId]);
                        saved = true;
                        if (recovered) {
                            const source = store.get([generation, recovered.editorId]);
                            source.onsuccess = () => {
                                try { if (source.result?.revision === recovered!.revision) store.delete([generation, recovered!.editorId]); }
                                catch { tx.abort(); }
                            };
                        }
                    } catch { tx.abort(); }
                };
            } catch { tx.abort(); }
        };
    });
}

/** Bounded pages, decrypted only in memory. A changed pairing cannot reveal a retired draft. */
export async function readDrafts(db: IDBDatabase, limit = 50, after?: string): Promise<DraftPage> {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 50 || (after !== undefined && !isId(after))) throw new DraftError();
    const p = await pairing(db); if (!p) return { drafts: [] };
    const page = await new Promise<{ rows: StoredDraft[]; next?: string }>((resolve, reject) => {
        let tx: IDBTransaction;
        try { tx = db.transaction('drafts', 'readonly'); } catch { reject(new DraftError()); return; }
        const rows: StoredDraft[] = []; let next: string | undefined;
        const range = IDBKeyRange.bound(after ? [p.generation, after] : [p.generation], [p.generation, []], after !== undefined);
        const request = tx.objectStore('drafts').openCursor(range);
        request.onsuccess = () => {
            const cursor = request.result; if (!cursor) return;
            if (rows.length === limit) { next = rows.at(-1)!.editorId; return; }
            rows.push(cursor.value); cursor.continue();
        };
        tx.oncomplete = () => resolve({ rows, next }); tx.onabort = tx.onerror = () => reject(new DraftError());
    });
    const drafts: Draft[] = [];
    for (const row of page.rows) {
        try {
            const kind = row.kind ?? 'note';
            if (kind !== 'note' && kind !== 'item-action') throw new DraftError();
            if (row.nonce.length !== 12 || row.bytes.length > 40016) throw new DraftError();
            const plain = new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: new Uint8Array(row.nonce),
                additionalData: aad(p.generation, row.editorId, kind) }, p.deviceKey, new Uint8Array(row.bytes)));
            try {
                if (plain.length % 2 !== 0 || plain.length > 40000) throw new DraftError();
                let text = ''; for (let i = 0; i < plain.length; i += 2) text += String.fromCharCode(plain[i]! * 256 + plain[i + 1]!);
                drafts.push({ generation: p.generation, editorId: row.editorId, revision: row.revision, updatedAt: row.updatedAt, text, kind });
            } finally { plain.fill(0); }
        } catch { throw new DraftError(); }
    }
    return (await pairing(db))?.generation === p.generation ? { drafts, next: page.next } : { drafts: [] };
}
