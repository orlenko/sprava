// End to end on one machine: a relay on localhost, the built web app in a disposable headless Chrome, and the
// Mac's side. Pair, publish, act on the phone, read the outcome on the Mac. Development only; never in dist/.
//
//   npm run e2e [-- --mac stand-in|dev-phone] [--chrome <path>]
//
// `--mac stand-in` (the default) plays the Mac with dev/stand-in-owner.ts. `--mac dev-phone` is the swap for a
// development build of the Mac (DevPhoneMac below): not wired yet; see the notes there.
// Every binder, item, label and note is invented. Nothing is installed, deployed or kept: the relay's folder,
// the Chrome profile and the servers go when the script ends.
import { spawn, type ChildProcess } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
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
 * The swap for a development build of the Mac. Its pairing requests come with `sprava dev-phone '<request>'`
 * (Track A, `mac-pairing`): run `swift run sprava dev-phone …` from the repository root with SPRAVA_SUPPORT_DIR
 * set to a fresh temporary folder, as scripts/test.sh isolates state, for `configure` (the relay's origin, its
 * setup code and this web app's address), `claim`, `pairing_start`, `pairing_poll`, `pairing_confirm` and
 * `devices`. Publishing, adding a to-do and draining need the companion job (Track B, `mac-sync`) and a way to
 * reach it from a development build. Until both are on main, this side refuses to run.
 */
class DevPhoneMac implements MacSide {
    private refuse(): never {
        throw new Error('--mac dev-phone needs `sprava dev-phone` (Track A) and the companion job (Track B) on main.');
    }
    async start(): Promise<void> { this.refuse(); }
    async pairingLink(): Promise<string> { this.refuse(); }
    async joined(): Promise<{ code: string; label: string }> { this.refuse(); }
    async confirm(): Promise<void> { this.refuse(); }
    async addToDo(): Promise<void> { this.refuse(); }
    async drain(): Promise<Decision[]> { this.refuse(); }
    closed(): boolean { this.refuse(); }
    noted(): boolean { this.refuse(); }
    async close() {}
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
        if (this.child && this.child.exitCode === null) { const exited = once(this.child, 'exit'); this.child.kill('SIGTERM'); await exited; }
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
let web: ChildProcess | undefined, relay: LocalRelay | undefined, phone: Phone | undefined;
try {
    const served = await serveWebApp(new URL('..', import.meta.url)); web = served.child;
    relay = await startLocalRelay({ webOrigin: served.origin });
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
    await phone.command('Page.enable');
    await phone.navigate(link);
    await phone.wait(`location.hash === '' && !!document.querySelector('#device-label') && !document.querySelector('#device-label').closest('div').hidden`,
        'the name field for a pairing link');
    await phone.type('#device-label', 'Invented e2e phone');
    await phone.click('Pair this phone');
    const joined = await mac.joined();
    await phone.wait(`/^\\d{3} \\d{3}$/.test(document.querySelector('#pairing-code').textContent)`, 'the confirmation code');
    const shown = await phone.text('#pairing-code');
    if (shown !== joined.code || joined.label !== 'Invented e2e phone') throw new Error('The two sides show different codes or labels.');
    step(`codes match (${shown}); the Mac confirms`);
    await mac.confirm();
    await phone.wait(`document.querySelector('#status').textContent === 'Paired.'`, 'that it is paired');
    await phone.wait(`document.querySelector('#binder-view').textContent.includes('Pay the water bill')`, 'Today with the published to-dos');
    step('paired; Today shows the published to-dos');

    await phone.click('Done', '#binder-view', 'Pay the water bill');
    await phone.wait(`document.querySelector('#pending').textContent.includes('Done #1 · Sent')`, 'the Done action sent');
    const decided = await mac.drain();
    if (decided[0]?.outcome !== 'applied' || !mac.closed('Pay the water bill')) throw new Error('The Mac did not apply Done.');
    await phone.click('Refresh');
    await phone.wait(`document.querySelector('#pending').textContent === '' &&
        !document.querySelector('#binder-view').textContent.includes('Pay the water bill')`, 'the outcome, and the item gone');
    step('Done on the phone closed the to-do on the Mac; the phone read the outcome');

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
    console.log('e2e: PASS');
} catch (error) {
    console.error(`e2e: FAIL: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
} finally {
    await phone?.close().catch(() => {});
    await mac.close().catch(() => {});
    await relay?.close().catch(() => {});
    web?.kill('SIGTERM');
}
