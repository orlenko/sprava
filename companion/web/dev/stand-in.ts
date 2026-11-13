// Plays the Mac against a local relay so the web app can be used by hand: `npm run stand-in`, beside `npm run dev`.
// Starts a relay on localhost (files in a temporary folder), claims it, publishes invented binders, prints a
// pairing link, confirms the pairing, then decides the phone's requests every two seconds. Ctrl-C stops it and
// deletes the folder. Development only; never built into dist/.
import { parseArgs } from 'node:util';
import { startLocalRelay } from './local-relay.ts';
import { StandInOwner } from './stand-in-owner.ts';

const { values } = parseArgs({ options: {
    port: { type: 'string', default: '8787' },
    web: { type: 'string', default: 'http://localhost:5173/' },
    hold: { type: 'string', default: '0' },
} });
const web = new URL(values.web), hold = Number(values.hold) * 1000;
if (!['localhost', '127.0.0.1'].includes(web.hostname) || !Number.isFinite(hold) || hold < 0) {
    process.stderr.write('Usage: node dev/stand-in.ts [--port 8787] [--web http://localhost:5173/] [--hold <seconds>]\n');
    process.exit(2);
}
const relay = await startLocalRelay({ webOrigin: web.origin, port: Number(values.port) });
const stop = () => { void relay.close().then(() => process.exit(0)); };
process.on('SIGINT', stop); process.on('SIGTERM', stop);
const owner = new StandInOwner(relay.origin, web.href);
await owner.claim(relay.setupCode);
await owner.publish();
console.log(`Relay ${relay.origin}, accepting the web app at ${web.origin}.`);
console.log(`Open this pairing link within 10 minutes:\n${await owner.startPairing()}`);
const { code, label } = await owner.waitForJoin();
console.log(`"${label}" joined; confirmation code ${code}. The stand-in confirms it.`);
await owner.confirm();
await owner.waitForAcknowledgement();
console.log(`Paired. Deciding requests every 2 seconds${hold ? `, each after ${hold / 1000} s` : ''}. Ctrl-C stops.`);
for (;;) {
    try {
        for (const d of await owner.drain(hold)) console.log(`${d.decidedAt} #${d.seq} ${d.type}: ${d.outcome}`);
    } catch (error) { console.log(`Drain failed: ${error instanceof Error ? error.message : 'unknown error'}`); }
    await new Promise(resolve => setTimeout(resolve, 2000));
}
