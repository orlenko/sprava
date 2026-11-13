// A stand-in for the Mac's side of companion-v0 (docs/spec/companion-v0.md), for local development and tests only;
// never built into dist/. It claims a relay, pairs one device, publishes invented binders, drains the device's
// requests and publishes their outcomes. Its cryptography is node:crypto, independent of the web app's WebCrypto
// code, so the two check each other. It keeps everything in memory and takes shortcuts the Mac must not (it
// confirms the code by itself and records nothing durably). Every binder, item and label is invented.
import { createCipheriv, createDecipheriv, createHash, createPublicKey, diffieHellman, generateKeyPairSync,
    hkdfSync, randomBytes, sign, type KeyObject } from 'node:crypto';
import { writeJson } from '../../shared/json.ts';
import { decodeB64, encodeB64, joinBytes, utf8 } from '../src/encoding.ts';

export type ItemId = string | number;
export interface Item {
    id: ItemId; title: string; status: 'open' | 'waiting' | 'blocked'; priority: string | null;
    due: string | null; waitingOn: string | null; followUpAt: string | null; notes: string | null;
    tags: string[]; contexts: string[]; changedIn: number;
}
export interface Closed { id: ItemId; title: string; closedAt: string | null; how: 'done' | 'dropped' }
export interface Binder {
    id: string; key: Buffer; name: string; description: string | null; version: number; dirty: boolean;
    items: Item[]; closed: Closed[]; documents: { title: string; date: string | null }[];
}
export type Outcome = 'applied' | 'conflict' | 'rejected';
export interface Decision { requestId: string; seq: number; type: string; outcome: Outcome; decidedAt: string }

const time = (ms = Date.now()) => new Date(Math.floor(ms / 1000) * 1000).toISOString().replace('.000Z', 'Z');
/** The local calendar day `offset` days from `from`, as YYYY-MM-DD. */
export function day(offset = 0, from = new Date()): string {
    const d = new Date(from.getFullYear(), from.getMonth(), from.getDate() + offset);
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}
const raw32 = (key: KeyObject) => new Uint8Array(key.export({ format: 'der', type: 'spki' }).subarray(-32));

function item(id: ItemId, title: string, fields: Partial<Item> = {}): Item {
    return { id, title, status: 'open', priority: null, due: null, waitingOn: null, followUpAt: null, notes: null,
        tags: [], contexts: [], changedIn: 1, ...fields };
}
function binder(name: string, description: string | null, items: Item[], closed: Closed[] = [],
    documents: Binder['documents'] = []): Binder {
    return { id: encodeB64(randomBytes(16)), key: randomBytes(32), name, description, version: 0, dirty: true,
        items, closed, documents };
}

/** Invented binders that fill every bucket: overdue, today, the coming week, later, no deadline, nudge, waiting. */
export function inventedBinders(today = new Date()): Binder[] {
    const d = (offset: number) => day(offset, today), at = (offset: number) => `${d(offset)}T09:30:00Z`;
    return [
        binder('Home', 'Running the flat: bills, repairs and the paperwork that comes with them.', [
            item('renew-library-card', 'Renew the library card', { due: d(-2), notes: 'The branch on Example Street closes at 5.' }),
            item('water-bill', 'Pay the water bill', { due: d(0), priority: 'high', tags: ['bills'] }),
            item('chimney', 'Book a chimney sweep before the cold weather', { due: d(3) }),
            item('shed', 'Repaint the shed', { due: d(24) }),
            item('photos', 'Sort the boxes of old photos into albums by year, and scan the ones that are fading', { contexts: ['home'] }),
            item('plumber', 'Quote for the kitchen tap', { status: 'waiting', waitingOn: 'Example Plumbing', followUpAt: d(4) }),
            item('kettle-refund', 'Refund for the returned kettle', { status: 'waiting', waitingOn: 'Example Shop',
                followUpAt: d(-1), notes: 'Returned on the 3rd; receipt in the drawer.' }),
        ], [
            { id: 'hall-bulb', title: 'Replace the hallway bulb', closedAt: at(-1), how: 'done' },
            { id: 'magazine', title: 'Cancel the old magazine', closedAt: d(-3), how: 'dropped' },
        ], [{ title: 'Water bill, last quarter', date: d(-20) }, { title: 'Tenancy agreement', date: null }]),
        binder('Allotment', null, [
            item(7, 'Order seed potatoes', { due: d(0) }),
            item(8, 'Fix the gate latch', { status: 'blocked', waitingOn: 'A spare hinge from the neighbour' }),
            item('7', 'Turn the compost', { due: d(1) }),
        ]),
        binder('Choir', 'Rehearsals and the spring concert.', [], [
            { id: 'scores', title: 'Return the borrowed scores', closedAt: at(-2), how: 'done' },
        ]),
    ];
}

/** Buckets as binder-v0 §5.2 computes them for `today`. */
export function buckets(items: Item[], today: string): Record<string, ItemId[]> {
    const b: Record<string, ItemId[]> = { overdue: [], today: [], next_7_days: [], later: [], no_deadline: [],
        nudge: [], waiting: [] };
    const week = day(7, new Date(`${today}T12:00:00`));
    for (const i of items) {
        if (i.status !== 'open') (i.followUpAt !== null && i.followUpAt <= today ? b.nudge! : b.waiting!).push(i.id);
        else if (i.due === null) b.no_deadline!.push(i.id);
        else if (i.due < today) b.overdue!.push(i.id);
        else if (i.due === today) b.today!.push(i.id);
        else (i.due <= week ? b.next_7_days! : b.later!).push(i.id);
    }
    return b;
}

export class OwnerError extends Error {}

export class StandInOwner {
    readonly relay: string;
    readonly webApp: string;
    readonly binders: Binder[];
    readonly notes: string[] = [];
    private readonly token = encodeB64(randomBytes(32));
    private readonly signing = generateKeyPairSync('ed25519');
    private readonly accountKey = randomBytes(32);
    private indexRevision = 0;
    private outcomesRevision = 0;
    private readonly outcomes: Decision[] = [];
    private readonly firstSeen = new Map<string, number>();
    private pairing?: { id: string; device: string; agreement: KeyObject; publicKey: Uint8Array };
    private device?: { id: string; key: Buffer; wrap: Buffer; label: string; highestSeq: number };

    constructor(relayOrigin: string, webApp: string, binders: Binder[] = inventedBinders()) {
        this.relay = relayOrigin; this.webApp = webApp; this.binders = binders;
    }
    get deviceId(): string | undefined { return this.device?.id; }

    private async call(method: string, path: string, body?: Uint8Array, expect: number[] = [200, 204]): Promise<Response> {
        const response = await fetch(this.relay + path, { method, body: body === undefined ? undefined : new Uint8Array(body),
            headers: { Authorization: `Bearer ${this.token}`,
                ...(body === undefined ? {} : { 'Content-Type': path.startsWith('/v0/pairings') && !path.endsWith('/key') ?
                    'application/json' : 'application/octet-stream' }) } });
        if (!expect.includes(response.status)) {
            await response.body?.cancel();
            throw new OwnerError(`${method} ${path.replace(/\/[A-Za-z0-9_-]{22}/g, '/…')} answered ${response.status}`);
        }
        return response;
    }
    private seal(name: string, kid: string, epoch: number, key: Uint8Array, plaintext: Uint8Array, signed: boolean): Uint8Array {
        const nonce = randomBytes(12), cipher = createCipheriv('aes-256-gcm', key, nonce);
        cipher.setAAD(utf8(`sprava-companion/v0|${name}|${kid}|${epoch}`));
        const c = Buffer.concat([cipher.update(plaintext), cipher.final(), cipher.getAuthTag()]);
        const envelope: Record<string, unknown> = { v: 0, kid, e: epoch, n: encodeB64(nonce), c: encodeB64(c) };
        if (signed) envelope.s = encodeB64(sign(null,
            joinBytes(utf8(`sprava-companion/v0 signed|${name}|${kid}|${epoch}|`), nonce, c), this.signing.privateKey));
        return writeJson(envelope);
    }
    private open(name: string, kid: string, key: Uint8Array, bytes: Uint8Array, epochs: number[]): { epoch: number; value: any; length: number } {
        const envelope = JSON.parse(Buffer.from(bytes).toString('utf8'));
        const nonce = decodeB64(String(envelope.n)), c = decodeB64(String(envelope.c));
        if (envelope.v !== 0 || envelope.kid !== kid || !epochs.includes(envelope.e) || 's' in envelope ||
            nonce?.length !== 12 || !c || c.length < 16) throw new OwnerError('A sealed object was malformed.');
        const decipher = createDecipheriv('aes-256-gcm', key, nonce);
        decipher.setAAD(utf8(`sprava-companion/v0|${name}|${kid}|${envelope.e}`));
        decipher.setAuthTag(c.subarray(-16));
        const plain = Buffer.concat([decipher.update(c.subarray(0, -16)), decipher.final()]);
        return { epoch: envelope.e, value: JSON.parse(plain.toString('utf8')), length: plain.length };
    }
    private put(name: string, bytes: Uint8Array): Promise<Response> {
        return this.call('PUT', `/v0/objects/${name}`, bytes);
    }

    /** §6: claims the relay with its setup code. */
    async claim(setupCode: string): Promise<void> {
        const hash = createHash('sha256').update(this.token, 'ascii').digest('hex');
        const response = await fetch(`${this.relay}/v0/claim`, { method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ setup_code: setupCode, owner_token_sha256: hash }) });
        await response.body?.cancel();
        if (response.status !== 204) throw new OwnerError(`The claim was answered ${response.status}.`);
    }

    /** §5.2 step 1: opens a pairing and returns the link the Mac would show as a QR code. */
    async startPairing(): Promise<string> {
        const agreement = generateKeyPairSync('x25519'), publicKey = raw32(agreement.publicKey);
        const device = encodeB64(randomBytes(16));
        const reply = await (await this.call('POST', '/v0/pairings',
            writeJson({ owner_public_key: encodeB64(publicKey), device_id: device }), [200])).json() as
            { pairing_id: string; secret: string };
        this.pairing = { id: reply.pairing_id, device, agreement: agreement.privateKey, publicKey };
        return `${this.webApp}#pair=v0.${encodeB64(utf8(this.relay))}.${reply.pairing_id}.${reply.secret}.` +
            `${encodeB64(publicKey)}.${device}`;
    }

    /** §5.2 step 3: waits for the join, derives the keys and returns the code and the device's label. */
    async waitForJoin(signal?: AbortSignal, everyMs = 1000): Promise<{ code: string; label: string }> {
        const p = this.pairing; if (!p) throw new OwnerError('No pairing is open.');
        for (;;) {
            signal?.throwIfAborted();
            const state = await (await this.call('GET', `/v0/pairings/${p.id}`, undefined, [200])).json() as
                { state: string; device_id: string | null; device_public_key: string | null; hello: string | null };
            if (state.state !== 'open') {
                if (state.device_id !== p.device || !state.device_public_key || !state.hello)
                    throw new OwnerError('The join named another device.');
                const B = decodeB64(state.device_public_key);
                if (B?.length !== 32) throw new OwnerError('The device key was malformed.');
                const peer = createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b656e032100', 'hex'), B]),
                    format: 'der', type: 'spki' });
                const Z = diffieHellman({ privateKey: p.agreement, publicKey: peer });
                if (Z.every(byte => byte === 0)) throw new OwnerError('The device key was of low order.');
                const info = (kind: string) => joinBytes(utf8(`sprava-companion/v0 ${kind}`), p.publicKey, B, decodeB64(p.device)!);
                const derive = (kind: string, length: number) => Buffer.from(hkdfSync('sha256', Z, utf8(p.id), info(kind), length));
                const wrap = derive('wrap', 32), key = derive('device', 32);
                const code = String(derive('confirm', 4).readUInt32BE(0) % 1_000_000).padStart(6, '0');
                const hello = this.open(`pairings/${p.id}/hello`, 'wrap', wrap, decodeB64(state.hello)!, [0]);
                if (hello.length !== 512 || typeof hello.value.label !== 'string') throw new OwnerError('The hello was invalid.');
                this.device = { id: p.device, key, wrap, label: hello.value.label, highestSeq: 0 };
                return { code: `${code.slice(0, 3)} ${code.slice(3)}`, label: hello.value.label };
            }
            await new Promise(resolve => setTimeout(resolve, everyMs));
        }
    }

    /** §5.2 step 4, as if the person said the codes match: uploads the device's keys and the sealed key. */
    async confirm(): Promise<void> {
        const p = this.pairing, d = this.device; if (!p || !d) throw new OwnerError('No pairing has joined.');
        const keys = this.seal(`devices/${d.id}/keys/1`, 'device', 1, d.key,
            writeJson({ account_key: encodeB64(this.accountKey), epoch: 1, device_id: d.id }), true);
        const delivery = this.seal(`pairings/${p.id}/key`, 'wrap', 1, d.wrap, writeJson({ account_key: encodeB64(this.accountKey),
            epoch: 1, device_id: d.id, min_index_revision: this.indexRevision,
            owner_signing_key: encodeB64(raw32(this.signing.publicKey)) }), false);
        await this.put(`devices/${d.id}/keys/1`, keys);
        await this.call('PUT', `/v0/pairings/${p.id}/key`, delivery);
    }

    /** §5.2 step 6: waits until the device has acknowledged its key. */
    async waitForAcknowledgement(signal?: AbortSignal, everyMs = 1000): Promise<void> {
        const p = this.pairing; if (!p) throw new OwnerError('No pairing is open.');
        for (;;) {
            signal?.throwIfAborted();
            const state = await (await this.call('GET', `/v0/pairings/${p.id}`, undefined, [200])).json() as { state: string };
            if (state.state === 'acknowledged') { this.pairing = undefined; return; }
            await new Promise(resolve => setTimeout(resolve, everyMs));
        }
    }

    /** §9.7: uploads a new version of every changed binder's view, then a new index naming them. */
    async publish(now = new Date()): Promise<void> {
        const today = day(0, now);
        for (const b of this.binders.filter(b => b.dirty)) {
            const version = b.version + 1, name = `views/${b.id}/${version}`;
            const view = { version, generated_at: time(now.getTime()), today,
                binder: { name: b.name, description: b.description }, notes_omitted: false, buckets: buckets(b.items, today),
                items: b.items.map(i => ({ id: i.id, changed_in: i.changedIn, title: i.title, status: i.status,
                    priority: i.priority, due: i.due, waiting_on: i.waitingOn, follow_up_at: i.followUpAt, notes: i.notes,
                    tags: i.tags, contexts: i.contexts })),
                closed: b.closed.map(c => ({ id: c.id, title: c.title, closed_at: c.closedAt, how: c.how })),
                documents: b.documents };
            await this.put(name, this.seal(name, b.id, 1, b.key, writeJson(view), true));
            b.version = version; b.dirty = false;
        }
        const revision = this.indexRevision + 1, name = `index/${revision}`;
        await this.put(name, this.seal(name, 'account', 1, this.accountKey, writeJson({ revision,
            generated_at: time(now.getTime()), binders: this.binders.map(b => ({ id: b.id, name: b.name,
                view_version: b.version, key: encodeB64(b.key) })) }), true));
        this.indexRevision = revision;
    }

    /**
     * §9.2: opens the device's requests, decides each, republishes what changed and the outcomes, then deletes
     * the requests. A request is decided only once it has waited `holdMs` since this owner first saw it, so the
     * web app's pending state can be looked at.
     */
    async drain(holdMs = 0, now = Date.now()): Promise<Decision[]> {
        const d = this.device; if (!d) return [];
        const listing = await (await this.call('GET', `/v0/requests/${d.id}?limit=100`, undefined, [200])).json() as
            { requests: { request_id: string }[] };
        const decided: Decision[] = [], done: string[] = [];
        for (const { request_id: id } of listing.requests) {
            const seen = this.firstSeen.get(id) ?? now; this.firstSeen.set(id, seen);
            if (now - seen < holdMs) break; // in order: a later request never overtakes a held one
            const response = await this.call('GET', `/v0/requests/${d.id}/${id}`, undefined, [200, 404]);
            if (response.status === 404) { await response.body?.cancel(); continue; }
            const bytes = new Uint8Array(await response.arrayBuffer());
            let request: any;
            try { request = this.open(`requests/${d.id}/${id}`, 'device', d.key, bytes, [1]).value; }
            catch { done.push(id); continue; } // §9.3: one that does not open gets no outcome
            done.push(id);
            if (!Number.isSafeInteger(request.seq) || request.seq <= d.highestSeq) continue; // a replay or duplicate
            d.highestSeq = request.seq;
            const decision = { requestId: id, seq: request.seq, type: String(request.type),
                outcome: this.decide(request), decidedAt: time(now) };
            decided.push(decision); this.outcomes.push(decision);
        }
        if (decided.length) {
            if (this.binders.some(b => b.dirty)) await this.publish(new Date(now));
            await this.publishOutcomes(now);
        }
        for (const id of done) { await this.call('DELETE', `/v0/requests/${d.id}/${id}`); this.firstSeen.delete(id); }
        return decided;
    }

    /** §9.5, simplified: the item must exist, allow the action, and be unchanged since the version the phone saw. */
    private decide(request: any): Outcome {
        if (request.type === 'note') {
            if (typeof request.text !== 'string' || request.text === '') return 'rejected';
            this.notes.push(request.text); return 'applied';
        }
        const b = this.binders.find(b => b.id === request.binder);
        const index = b ? b.items.findIndex(i => i.id === request.item) : -1;
        const i = b?.items[index];
        if (!b || !i || !Number.isSafeInteger(request.seen_version) || i.changedIn > request.seen_version) return 'conflict';
        const waiting = i.status === 'waiting' || i.status === 'blocked', next = b.version + 1;
        switch (request.type) {
            case 'done': case 'drop':
                b.items.splice(index, 1);
                b.closed.unshift({ id: i.id, title: i.title, closedAt: time(), how: request.type === 'done' ? 'done' : 'dropped' });
                break;
            case 'arrived':
                if (!waiting) return 'conflict';
                Object.assign(i, { status: 'open', waitingOn: null, followUpAt: null, changedIn: next }); break;
            case 'follow_up':
                if (!waiting || typeof request.date !== 'string') return 'conflict';
                Object.assign(i, { followUpAt: request.date, changedIn: next }); break;
            case 'postpone':
                if (waiting || i.due === null || typeof request.date !== 'string') return 'conflict';
                Object.assign(i, { due: request.date, changedIn: next }); break;
            default: return 'rejected';
        }
        b.dirty = true; return 'applied';
    }

    /** §8.7: every outcome so far, padded to 512 + 128 bytes an entry, signed. */
    private async publishOutcomes(now: number): Promise<void> {
        const d = this.device!, revision = this.outcomesRevision + 1, name = `devices/${d.id}/outcomes/${revision}`;
        const recent = this.outcomes.slice(-2000), value = { device_id: d.id, revision, generated_at: time(now),
            outcomes: recent.map(o => ({ request_id: o.requestId, seq: o.seq, outcome: o.outcome, decided_at: o.decidedAt })) };
        const bare = writeJson({ ...value, pad: '' }), target = 512 + 128 * recent.length;
        if (bare.length > target) throw new OwnerError('The outcomes did not fit their padding.');
        await this.put(name, this.seal(name, 'device', 0, d.key, writeJson({ ...value, pad: ' '.repeat(target - bare.length) }), true));
        this.outcomesRevision = revision;
    }
}
