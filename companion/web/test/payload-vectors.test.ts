// Shared §14 case 8 corpus: future Mac validators must agree with these public inputs.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { openPairingDelivery, openDeviceKeys, openIndex } from '../src/owner-payloads.ts';
import { openView } from '../src/view-payloads.ts';
import { PayloadError } from '../src/payload.ts';
import { id, key, owner, sealed } from './owner-fixture.ts';

const corpus = JSON.parse(readFileSync(new URL('../../testdata/companion-v0-vectors.json', import.meta.url), 'utf8'))['payload-validation'];
async function read(entry: { kind: string; text: string }) {
    const secret = await key(), signing = await owner();
    switch (entry.kind) {
        case 'key': return openPairingDelivery(id, id, secret, sealed(`pairings/${id}/key`, 'wrap', 1, null, false, entry.text));
        case 'device-keys': return openDeviceKeys(id, 1, secret, signing, sealed(`devices/${id}/keys/1`, 'device', 1, null, true, entry.text));
        case 'index': return openIndex(7, 1, secret, signing, sealed('index/7', 'account', 1, null, true, entry.text));
        case 'view': return openView(id, 7, 1, secret, signing, sealed(`views/${id}/7`, id, 1, null, true, entry.text));
        default: throw new Error('unimplemented vector kind');
    }
}

test('shared payload-validation vectors accept each implemented owner payload', async () => {
    for (const entry of corpus.valid) await assert.doesNotReject(read(entry), entry.why);
});
test('shared payload-validation vectors reject malformed authenticated payloads as a whole', async () => {
    for (const entry of corpus.refuse) await assert.rejects(read(entry), PayloadError, entry.why);
});
