// End to end on one machine: a relay on localhost, the built web app in a disposable headless Chrome, and the
// Mac's side. Pair, publish, act on the phone, read the outcome on the Mac. Development only; never in dist/.
//
//   npm run e2e [-- --mac stand-in|dev-phone] [--chrome <path>]
//
// `--mac stand-in` (the default) plays the Mac with dev/stand-in-owner.ts. `--mac dev-phone` uses a development
// build of the Mac instead (DevPhoneMac below), and also checks that a stale Done becomes a card.
// Every binder, item, label and note is invented. Nothing is installed, deployed or kept: the relay's folder,
// the Chrome profile and the servers go when the script ends.
import { spawn, type ChildProcess } from 'node:child_process';
import { once } from 'node:events';
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { parseArgs } from 'node:util';
import { startLocalRelay, type LocalRelay } from './local-relay.ts';
import { day, StandInOwner, type Decision } from './stand-in-owner.ts';

/** What the script needs from the Mac. Each step names the Mac request that will carry it. */
interface MacSide {
    /** `configure` and `claim`, then a first publish. */
    start(relay: LocalRelay, webApp: string): Promise<void>;
    /** `pairing_start`: the link the Mac shows as a QR code. */
    pairingLink(): Promise<string>;
    /** `pairing_poll` until the phone has joined: the code and label the Mac shows. */
    joined(): Promise<{ code: string; label: string }>;
    /** `pairing_confirm`, as when the person says the codes match, then `pairing_poll` until acknowledged. */
    confirm(): Promise<void>;
    /** A new to-do due today in a shown binder, published (Track B: the companion job). */
    addToDo(title: string): Promise<void>;
    /** One drain of the phone's requests (Track B). */
    drain(): Promise<Decision[]>;
    /** Whether a to-do with this title is closed on the Mac, and whether a note with this text reached its inbox. */
    closed(title: string): boolean;
    noted(text: string): boolean;
    /** Only a real Mac: change a to-do without publishing, then the cards waiting in its binder (companion-v0 §9.5). */
    changeBeforePublishing?(title: string): Promise<void>;
    /** Only a real Mac: Undo, as the app offers it, of the change a phone's Done made; whether the to-do is open again. */
    undoPhoneDone?(title: string): Promise<boolean>;
    /** Only a real Mac: Remove the paired phone, then one job run; the account epoch the Mac is at. */
    removePhone?(which: number): Promise<void>;
    epoch?(): Promise<number>;
    /** Only a real Mac: the newest keys object recorded for the `which`-th phone paired, and whether it is on the relay. */
    keys?(which: number): Promise<{ epoch: number; state: string } | undefined>;
    /** Only a real Mac: whether the relay has yet to confirm deleting the `which`-th phone paired. */
    deletionPending?(which: number): Promise<boolean>;
    cards?(): string[];
    close(): Promise<void>;
}

class StandInMac implements MacSide {
    private owner?: StandInOwner;
    async start(relay: LocalRelay, webApp: string) {
        this.owner = new StandInOwner(relay.origin, webApp);
        await this.owner.claim(relay.setupCode);
        await this.owner.publish();
    }
    pairingLink() { return this.owner!.startPairing(); }
    joined() { return this.owner!.waitForJoin(undefined, 250); }
    async confirm() { await this.owner!.confirm(); await this.owner!.waitForAcknowledgement(undefined, 250); }
    async addToDo(title: string) {
        const home = this.owner!.binders[0]!;
        home.items.push({ id: `e2e-${Date.now()}`, title, status: 'open', priority: null, due: day(0), waitingOn: null,
            followUpAt: null, notes: null, tags: [], contexts: [], changedIn: home.version + 1 });
        home.dirty = true;
        await this.owner!.publish();
    }
    drain() { return this.owner!.drain(); }
    closed(title: string) { return this.owner!.binders.some(b => b.closed.some(c => c.title === title)); }
    noted(text: string) { return this.owner!.notes.includes(text); }
    async close() {}
}

/**
 * A development build of the Mac: the `sprava` command line built from this checkout, on its own state in a fresh
 * temporary folder (SPRAVA_SUPPORT_DIR; the development state is that folder plus "-dev"), with file credentials,
 * never the Keychain, and an invented binder it adopts and shows on the phone. `sprava dev-phone '<request>'` sends
 * the Phone actions as Settings › Phone does; `sprava dev-phone run` runs the companion job once, as the runtime's
 * timer would: publish, drain the phone's requests, publish its outcomes.
 */
class DevPhoneMac implements MacSide {
    private root = '';
    private binder = '';
    private device = '';
    /** Every phone this Mac started pairing, in order. */
    private readonly paired: string[] = [];
    private confirmation = '';
    private readonly repository = new URL('../../../', import.meta.url).pathname;
    private get sprava() { return join(this.repository, '.build/debug/sprava'); }
    private env(): NodeJS.ProcessEnv {
        // An empty registry path: the development guard then reads no lifeproj registry at all.
        return { ...process.env, SPRAVA_SUPPORT_DIR: join(this.root, 'support'), SPRAVA_CAPTURE_ROOT: join(this.root, 'captures'),
            CMIRROR_CONFIG: join(this.root, 'no-registry.toml') };
    }
    private async run(args: string[]): Promise<string> {
        const child = spawn(this.sprava, args, { cwd: this.repository, env: this.env(), stdio: ['ignore', 'pipe', 'pipe'] });
        let out = '', err = '';
        child.stdout!.on('data', bytes => { out += String(bytes); }); child.stderr!.on('data', bytes => { err += String(bytes); });
        const [code] = await once(child, 'exit');
        // Named by its command only: a request can carry the relay's setup code.
        const what = args[1]!.startsWith('{') ? JSON.parse(args[1]!).command : args[1];
        if (code !== 0) throw new Error(`sprava ${args[0]} ${what} failed: ${(out + err).trim().slice(0, 400)}`);
        return out;
    }
    private async phone(request: object): Promise<any> { return JSON.parse(await this.run(['dev-phone', JSON.stringify(request)])); }
    private catalog(): any { return JSON.parse(readFileSync(join(this.binder, 'catalog.json'), 'utf8')); }

    async start(relay: LocalRelay, webApp: string) {
        const build = spawn('swift', ['build', '--product', 'sprava'], { cwd: this.repository, stdio: ['ignore', 'ignore', 'inherit'] });
        const [code] = await once(build, 'exit'); if (code !== 0) throw new Error('sprava did not build.');
        this.root = await mkdtemp(join(tmpdir(), 'sprava-e2e-mac-'));
        this.binder = join(this.root, 'binders', 'invented-home');
        mkdirSync(this.binder, { recursive: true });
        writeFileSync(join(this.binder, 'catalog.json'), JSON.stringify({
            meta: { schema_version: 2, name: 'invented-home', format: 'teka', format_version: '0', disclosure: 'none',
                id_scheme: 'teka-year-seq', domain: 'home', lifecycle: 'ongoing', created: day(-30), next_doc_id: 1, next_item_id: 2 },
            documents: [], processing_log: [],
            open_items: [{ id: 'invented-home-2026-001', title: 'Pay the water bill', status: 'open', priority: 'normal', due: day(0), kind: 'payment' }],
        }, null, 2));
        await this.run(['dev', 'adopt', this.binder]);
        await this.run(['dev', 'shelve', this.binder]);
        await this.phone({ command: 'companion_configure', relay_origin: relay.origin, setup_code: relay.setupCode, web_origin: new URL(webApp).origin });
        const claimed = await this.phone({ command: 'companion_claim' });
        if (claimed.state !== 'claimed') throw new Error(`The relay was not claimed: ${claimed.state}`);
        await this.phone({ command: 'companion_binder_show', binder: this.binder });
        await this.run(['dev-phone', 'run']);
    }
    async pairingLink() {
        const started = await this.phone({ command: 'companion_pairing_start' });
        this.device = started.device_id;
        this.paired.push(this.device);
        return started.link as string;
    }
    private async poll(until: string[], ms = 30000): Promise<any> {
        const end = Date.now() + ms;
        while (Date.now() < end) {
            const reply = await this.phone({ command: 'companion_pairing_poll', device_id: this.device });
            if (until.includes(reply.state)) return reply;
            await new Promise(resolve => setTimeout(resolve, 500));
        }
        throw new Error(`The pairing did not reach ${until.join(' or ')}.`);
    }
    async joined() {
        const reply = await this.poll(['confirm']);
        this.confirmation = reply.confirmation;
        // The Mac shows its six digits in two groups, as the phone does.
        return { code: String(reply.confirmation).replace(/^(\d{3})(\d{3})$/, '$1 $2'), label: reply.label as string };
    }
    async confirm() {
        await this.phone({ command: 'companion_pairing_confirm', device_id: this.device, confirmation: this.confirmation });
        await this.poll(['paired']);
        await this.run(['dev-phone', 'run']);
    }
    async addToDo(title: string) {
        await this.run(['dev', 'add', this.binder, title]);
        await this.run(['dev-phone', 'run']);
    }
    async drain(): Promise<Decision[]> { await this.run(['dev-phone', 'run']); return []; }
    closed(title: string) { return (this.catalog().processing_log ?? []).some((e: any) => e.title === title && e.action === 'done'); }
    noted(text: string) {
        const root = join(this.root, 'captures');
        if (!existsSync(root)) return false;
        return readdirSync(root).some(device => readdirSync(join(root, device)).filter(n => n.endsWith('.json'))
            .some(name => { try { return JSON.parse(readFileSync(join(root, device, name), 'utf8')).text === text; } catch { return false; } }));
    }
    /** An edit made on the Mac after the phone's view was published, without a publish in between. */
    async changeBeforePublishing(title: string) {
        const catalog = this.catalog();
        const item = catalog.open_items.find((i: any) => i.title === title);
        if (!item) throw new Error(`No to-do ${title} on the Mac.`);
        item.priority = item.priority === 'high' ? 'normal' : 'high';
        writeFileSync(join(this.binder, 'catalog.json'), JSON.stringify(catalog, null, 2));
    }
    async undoPhoneDone(title: string) {
        const closure = (this.catalog().processing_log ?? []).find((e: any) => e.title === title && e.action === 'done');
        const ops = readFileSync(join(this.binder, '.sprava', 'ops.ndjson'), 'utf8').split('\n').filter(Boolean).map(l => JSON.parse(l));
        const op = ops.find((o: any) => o.op === 'complete' && String(o.note ?? '').startsWith('companion:') && o.args?.id === closure?.id);
        if (!op) throw new Error(`No phone Done for ${title} in the op log.`);
        await this.run(['dev', 'undo', this.binder, op.id]);
        return this.catalog().open_items.some((i: any) => i.title === title);
    }
    async removePhone(which: number) {
        const reply = await this.phone({ command: 'companion_device_remove', device_id: this.paired[which] });
        if (reply.state !== 'removed') throw new Error(`The Mac did not remove the phone: ${reply.state}`);
    }
    private query<Row>(sql: string, ...values: string[]): Row | undefined {
        const database = new DatabaseSync(join(this.root, 'support-dev', 'companion', 'state.sqlite'), { readOnly: true });
        try { return database.prepare(sql).get(...values) as Row | undefined; } finally { database.close(); }
    }
    async epoch() { return Number(this.query<{ epoch: number }>('SELECT epoch FROM profile')!.epoch); }
    async deletionPending(which: number) {
        return this.query<{ n: number }>('SELECT COUNT(*) AS n FROM device_removals WHERE device = ? AND relay_delete = 1', this.paired[which]!)!.n > 0;
    }
    async keys(which: number) {
        return this.query<{ epoch: number; state: string }>('SELECT epoch, state FROM rotation_keys WHERE device = ? ORDER BY epoch DESC LIMIT 1',
            this.paired[which]!);
    }
    /** The cards waiting in the binder, by title. */
    cards(): string[] {
        const folder = join(this.binder, '.sprava', 'proposals');
        if (!existsSync(folder)) return [];
        return readdirSync(folder).filter(n => n.endsWith('.json')).map(n => JSON.parse(readFileSync(join(folder, n), 'utf8')))
            .filter(p => p.state === 'proposed').map(p => String(p.title));
    }
    async close() { if (this.root) await rm(this.root, { recursive: true, force: true }); }
}

/** A disposable headless Chrome driven over the DevTools protocol, on its own fresh profile. */
class Phone {
    private child?: ChildProcess;
    private socket?: WebSocket;
    private sequence = 0;
    private readonly pending = new Map<number, { resolve: (value: any) => void; reject: (error: Error) => void }>();
    readonly profile: string;
    private constructor(profile: string) { this.profile = profile; }

    static async open(chrome: string, width = 390, height = 844): Promise<Phone> {
        const phone = new Phone(await mkdtemp(join(tmpdir(), 'sprava-e2e-chrome-')));
        try { return await phone.start(chrome, width, height); }
        catch (error) { await phone.close().catch(() => {}); throw error; } // no profile left behind
    }
    private async start(chrome: string, width: number, height: number): Promise<Phone> {
        const phone = this;
        phone.child = spawn(chrome, ['--headless', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
            '--disable-extensions', '--disable-background-networking', `--user-data-dir=${phone.profile}`,
            '--remote-debugging-address=127.0.0.1', '--remote-debugging-port=0', `--window-size=${width},${height}`],
            { stdio: ['ignore', 'ignore', 'pipe'] });
        const endpoint = await new Promise<string>((resolve, reject) => {
            let stderr = '';
            phone.child!.stderr!.on('data', bytes => {
                stderr += String(bytes);
                const match = /DevTools listening on (ws:\/\/\S+)/.exec(stderr); if (match) resolve(match[1]!);
            });
            phone.child!.once('error', reject);
            phone.child!.once('exit', () => reject(new Error('Chrome exited before it was ready.')));
        });
        const target = await fetch(`http://127.0.0.1:${new URL(endpoint).port}/json/new?about:blank`, { method: 'PUT' })
            .then(r => r.json()) as { webSocketDebuggerUrl: string };
        phone.socket = new WebSocket(target.webSocketDebuggerUrl); await once(phone.socket, 'open');
        phone.socket.addEventListener('message', event => {
            const message = JSON.parse(String(event.data)), entry = phone.pending.get(message.id);
            if (!entry) return; phone.pending.delete(message.id);
            if (message.error || message.result?.exceptionDetails) entry.reject(new Error(JSON.stringify(message.error ??
                message.result.exceptionDetails.exception?.description ?? 'evaluation failed')));
            else entry.resolve(message.result);
        });
        await phone.command('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 2, mobile: true });
        return phone;
    }
    command(method: string, params: object = {}): Promise<any> {
        return new Promise((resolve, reject) => {
            const id = ++this.sequence; this.pending.set(id, { resolve, reject });
            this.socket!.send(JSON.stringify({ id, method, params }));
        });
    }
    async evaluate(expression: string): Promise<any> {
        return (await this.command('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true })).result.value;
    }
    async wait(condition: string, what: string, ms = 20000): Promise<void> {
        const until = Date.now() + ms;
        while (Date.now() < until) {
            try { if (await this.evaluate(condition)) return; } catch { /* a navigation replaces the context */ }
            await new Promise(resolve => setTimeout(resolve, 100));
        }
        throw new Error(`The phone did not show: ${what}`);
    }
    navigate(url: string) { return this.command('Page.navigate', { url }); }
    /** Clicks the button with this exact text, inside `scope` (a CSS selector), optionally in the item titled `item`. */
    click(text: string, scope = 'body', item?: string) {
        return this.evaluate(`(() => {
            const rows = ${item === undefined} ? [document.querySelector(${JSON.stringify(scope)})] :
                Array.from(document.querySelectorAll(${JSON.stringify(scope + ' li')}))
                    .filter(r => r.querySelector('strong')?.textContent === ${JSON.stringify(item ?? '')});
            const button = rows.flatMap(r => r ? Array.from(r.querySelectorAll('button')) : [])
                .find(b => b.textContent === ${JSON.stringify(text)} && !b.disabled);
            if (!button) throw new Error('No button ' + ${JSON.stringify(text)});
            button.click();
        })()`);
    }
    type(selector: string, text: string) {
        return this.evaluate(`(() => { const field = document.querySelector(${JSON.stringify(selector)});
            field.value = ${JSON.stringify(text)}; field.dispatchEvent(new Event('input')); })()`);
    }
    text(selector: string): Promise<string> {
        return this.evaluate(`document.querySelector(${JSON.stringify(selector)})?.textContent ?? ''`);
    }
    async close() {
        this.socket?.close();
        if (this.child?.pid !== undefined && this.child.exitCode === null && this.child.signalCode === null) {
            const exited = once(this.child, 'exit'); this.child.kill('SIGTERM'); await exited;
        }
        await rm(this.profile, { recursive: true, force: true });
    }
}

/** The built web app, served by its own preview server on a free localhost port. */
async function serveWebApp(directory: URL): Promise<{ origin: string; child: ChildProcess }> {
    const build = spawn('npm', ['run', 'build'], { cwd: directory, stdio: ['ignore', 'ignore', 'inherit'] });
    const [code] = await once(build, 'exit'); if (code !== 0) throw new Error('The web app did not build.');
    const child = spawn(process.execPath, ['serve.mjs'], { cwd: directory, env: { ...process.env, SPRAVA_WEB_PORT: '0' },
        stdio: ['ignore', 'pipe', 'inherit'] });
    const origin = await new Promise<string>((resolve, reject) => {
        child.stdout!.on('data', bytes => { const match = /(http:\/\/localhost:\d+)/.exec(String(bytes)); if (match) resolve(match[1]!); });
        child.once('exit', () => reject(new Error('The preview server stopped.')));
    });
    return { origin, child };
}

const { values } = parseArgs({ options: {
    mac: { type: 'string', default: 'stand-in' },
    chrome: { type: 'string', default: process.env.SPRAVA_TEST_CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' },
} });
const mac: MacSide = values.mac === 'dev-phone' ? new DevPhoneMac() : values.mac === 'stand-in' ? new StandInMac() :
    (() => { throw new Error('--mac is stand-in or dev-phone.'); })();
const step = (text: string) => console.log(`e2e: ${text}`);
let web: ChildProcess | undefined, relay: (LocalRelay & { instance: string }) | undefined, relayFolder = '';
let phone: Phone | undefined, second: Phone | undefined;

/** Opens the pairing link on `device`, names it, compares the codes both sides show, and has the Mac confirm. */
async function pair(device: Phone, link: string, label: string): Promise<void> {
    await device.command('Page.enable');
    await device.navigate(link);
    await device.wait(`location.hash === '' && !!document.querySelector('#device-label') && !document.querySelector('#device-label').closest('div').hidden`,
        'the name field for a pairing link');
    await device.type('#device-label', label);
    await device.click('Pair this phone');
    const joined = await mac.joined();
    await device.wait(`/^\\d{3} \\d{3}$/.test(document.querySelector('#pairing-code').textContent)`, 'the confirmation code');
    const shown = await device.text('#pairing-code');
    if (shown !== joined.code || joined.label !== label) {
        throw new Error(`The two sides show different codes or labels: "${shown}" and "${joined.code}", "${joined.label}".`);
    }
    step(`codes match (${shown}); the Mac confirms`);
    await mac.confirm();
    await device.wait(`document.querySelector('#status').textContent === 'Paired.'`, 'that it is paired');
}
try {
    const served = await serveWebApp(new URL('..', import.meta.url)); web = served.child;
    relayFolder = await mkdtemp(join(tmpdir(), 'sprava-e2e-relay-')); // kept across a restart, removed at the end
    relay = await startLocalRelay({ webOrigin: served.origin, folder: relayFolder });
    for (let tries = 0; ; tries++) { // a relay process answers only health while it warms up (§7.9)
        const health = await fetch(`${relay.origin}/v0/health`).catch(() => undefined);
        if (health?.ok) break;
        if (tries > 120) throw new Error('The relay did not become ready.');
        await new Promise(resolve => setTimeout(resolve, 1000));
    }
    step(`relay ${relay.origin}, web app ${served.origin}`);
    await mac.start(relay, `${served.origin}/`);
    const link = await mac.pairingLink();

    phone = await Phone.open(values.chrome);
    await pair(phone, link, 'Invented e2e phone');
    await phone.wait(`document.querySelector('#binder-view').textContent.includes('Pay the water bill')`, 'Today with the published to-dos');
    step('paired; Today shows the published to-dos');

    await phone.click('Done', '#binder-view', 'Pay the water bill');
    await phone.wait(`document.querySelector('#pending').textContent.includes('Done #1 · Sent')`, 'the Done action sent');
    const decided = await mac.drain(); // the stand-in reports its decisions; a real Mac shows them in the binder
    if ((decided.length > 0 && decided[0]?.outcome !== 'applied') || !mac.closed('Pay the water bill')) throw new Error('The Mac did not apply Done.');
    await phone.click('Refresh');
    await phone.wait(`document.querySelector('#pending').textContent === '' &&
        !document.querySelector('#binder-view').textContent.includes('Pay the water bill')`, 'the outcome, and the item gone');
    step('Done on the phone closed the to-do on the Mac; the phone read the outcome');
    if (mac.undoPhoneDone) {
        if (!await mac.undoPhoneDone('Pay the water bill')) throw new Error('Undo on the Mac did not reopen the to-do.');
        step('Undo on the Mac reopened it');
    }

    await mac.addToDo('Invented to-do added on the Mac');
    await phone.click('Refresh');
    await phone.wait(`document.querySelector('#binder-view').textContent.includes('Invented to-do added on the Mac')`, 'the new to-do');
    step('a to-do added on the Mac reached the phone');

    await phone.type('#note', 'Invented note from the e2e phone');
    await phone.click('Send note');
    await phone.wait(`document.querySelector('#pending').textContent.includes('Note #2 · Sent')`, 'the note sent');
    await mac.drain();
    if (!mac.noted('Invented note from the e2e phone')) throw new Error('The note did not reach the Mac.');
    step('a note from the phone reached the Mac');

    if (mac.changeBeforePublishing && mac.cards) {
        // The person changes the to-do on the Mac while the phone still shows the older version, and the phone marks it done.
        await mac.changeBeforePublishing('Invented to-do added on the Mac');
        await phone.click('Done', '#binder-view', 'Invented to-do added on the Mac');
        await phone.wait(`document.querySelector('#pending').textContent.includes('Done #3 · Sent')`, 'the stale Done sent');
        await mac.drain();
        if (mac.closed('Invented to-do added on the Mac')) throw new Error('The Mac applied a stale Done.');
        if (!mac.cards().some(title => title.includes('changed since your phone saw it'))) throw new Error('The stale Done did not become a card.');
        await phone.click('Refresh');
        await phone.wait(`document.querySelector('#pending').textContent.includes('changed on your Mac since')`, 'the conflict outcome');
        step('a stale Done became a card on the Mac, and the phone says so');
    }

    if (mac.removePhone && mac.keys && mac.epoch && mac.deletionPending) {
        second = await Phone.open(values.chrome);
        await pair(second, await mac.pairingLink(), 'Invented second phone');
        await second.wait(`document.querySelector('#binder-view').textContent.includes('Pay the water bill')`, 'the to-dos on the second phone');
        const before = await mac.epoch();
        step(`a second phone paired at epoch ${before}`);
        // Settings › Phone › Remove for the first phone, while the relay is down: the Remove action reaches nothing,
        // so the second phone's keys for the new epoch can only come from the companion job.
        const restart = { webOrigin: served.origin, port: Number(new URL(relay.origin).port), folder: relayFolder,
            instance: relay.instance, setupCode: relay.setupCode };
        await relay.close(); relay = undefined;
        await mac.removePhone(0);
        const recorded = await mac.keys(1);
        if (recorded?.epoch !== before + 1 || recorded.state !== 'pending') {
            throw new Error(`The second phone's keys were not left to the job: ${JSON.stringify(recorded)}.`);
        }
        relay = await startLocalRelay(restart);
        await mac.drain();
        const delivered = await mac.keys(1);
        if (delivered?.epoch !== before + 1 || delivered.state !== 'uploaded') {
            throw new Error(`The job did not deliver the second phone's keys: ${JSON.stringify(delivered)}.`);
        }
        step(`the job, not the Remove action, delivered the second phone's keys for epoch ${delivered.epoch}`);
        if (await mac.deletionPending!(0)) {
            // The relay deletion is paced on its own (2 s after the attempt the outage failed), and the new keys never
            // wait for it; the next run deletes the removed phone.
            step('the relay deletion of the removed phone waits for its pace; the next run makes it');
            await new Promise(resolve => setTimeout(resolve, 3000));
            await mac.drain();
            if (await mac.deletionPending!(0)) throw new Error('The next run did not delete the removed phone on the relay.');
        }
        await phone.click('Refresh');
        await phone.wait(`document.querySelector('#status').textContent.includes('The relay refused this phone')`, 'that the relay refuses it');
        step('the removed phone is refused by the relay');
        // A to-do published only at the new epoch: the second phone can show it only with its new keys.
        await mac.addToDo('Invented to-do after the removal');
        await second.click('Refresh');
        await second.wait(`document.querySelector('#binder-view').textContent.includes('Invented to-do after the removal')`,
            'the to-do published at the new epoch, on the second phone');
        step(`the second phone reads the to-dos at epoch ${await mac.epoch()}`);
    }
    console.log('e2e: PASS');
} catch (error) {
    console.error(`e2e: FAIL: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
} finally {
    await phone?.close().catch(() => {});
    await second?.close().catch(() => {});
    await mac.close().catch(() => {});
    await relay?.close().catch(() => {});
    if (relayFolder) await rm(relayFolder, { recursive: true, force: true }).catch(() => {});
    web?.kill('SIGTERM');
}
