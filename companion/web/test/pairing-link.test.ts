import assert from 'node:assert/strict';
import { test } from 'node:test';
import { encodeB64, utf8 } from '../src/encoding.ts';
import { consumePairingLink, parsePairingLink, PairingLinkError } from '../src/pairing-link.ts';
import { id, otherId, raw } from './owner-fixture.ts';

const link = (origin = 'https://relay.example:8443') =>
    `#pair=v0.${encodeB64(utf8(origin))}.${id}.${otherId}.${encodeB64(raw)}.${id}`;

test('pairing reads the relay, owner key and device exclusively from the canonical fragment', () => {
    for (const origin of ['https://relay.example', 'https://relay.example:8443', 'http://localhost', 'http://localhost:8080']) {
        const result = parsePairingLink(link(origin));
        assert.equal(result.relayOrigin, origin); assert.equal(result.deviceId, id);
        assert.equal(result.pairingId, id); assert.equal(result.secret, otherId); assert.deepEqual(result.ownerPublicKey, raw);
    }
});

test('paths, credentials, noncanonical origins, malformed UTF-8, wrong ids/keys and extra parts are refused', () => {
    for (const origin of ['http://relay.example', 'https://relay.example/', 'https://relay.example/path',
        'https://relay.example?x=1', 'https://relay.example#x', 'https://user:secret@relay.example',
        'https://relay.example:443', 'HTTPS://RELAY.EXAMPLE', 'http://127.0.0.1', 'file:///tmp/fixture'])
        assert.throws(() => parsePairingLink(link(origin)), PairingLinkError);
    for (const fragment of [link() + '.extra', link().replace('#pair=v0.', '#pair=v1.'),
        link().replace(encodeB64(raw), id), link().replace(otherId, otherId + '='),
        link().replace(encodeB64(utf8('https://relay.example:8443')), encodeB64(new Uint8Array([0xff]))),
        '#pair=v0.' + 'A'.repeat(5000), '#pair=v0.%00'])
        assert.throws(() => parsePairingLink(fragment), PairingLinkError);
});

test('valid and invalid fragments are erased before parsing, with no secret in the replacement history state', () => {
    for (const fragment of [link(), '#pair=v0.invalid']) {
        const replacements: unknown[][] = [];
        const history = { replaceState(...args: unknown[]) { replacements.push(args); } };
        const location = { hash: fragment, pathname: '/companion/', search: '?release=invented' };
        if (fragment === link()) assert.ok(consumePairingLink(location, history));
        else assert.throws(() => consumePairingLink(location, history), PairingLinkError);
        assert.deepEqual(replacements, [[null, '', '/companion/?release=invented']]);
    }
    assert.equal(consumePairingLink({ hash: '', pathname: '/', search: '' },
        { replaceState() { assert.fail('no fragment to remove'); } }), null);
});
