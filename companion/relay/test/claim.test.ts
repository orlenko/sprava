import assert from 'node:assert/strict';
import { test } from 'node:test';
import { CLAIM_TIMING } from '../src/claim.ts';
import { newToken, tokenHash } from '../src/encoding.ts';
import { bearer, SETUP_CODE, startTestRelay, WEB_ORIGIN, type TestRelay } from './harness.ts';
import { vectors } from './vectors.ts';

const OTHER_CODE = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';
const fast = { ...CLAIM_TIMING, intervalMs: 1, failureDelayMs: 50 };

function post(t: TestRelay, body: unknown, headers: Record<string, string> = {}): Promise<Response> {
    return fetch(`${t.url}/v0/claim`, { method: 'POST', body: typeof body === 'string' ? body : JSON.stringify(body), headers });
}

test('claiming: the owner record is exactly the derived bytes, and a retry is 204 (§6)', async () => {
    const t = await startTestRelay({ claimTiming: fast });
    const token = newToken();
    const body = { setup_code: SETUP_CODE, owner_token_sha256: tokenHash(token) };
    assert.equal((await post(t, body)).status, 204);
    const stored = await t.relay.store.get('owner.json');
    assert.equal(Buffer.from(stored!).toString(), `{"owner_token_sha256":"${tokenHash(token)}"}`);
    assert.equal((await post(t, body)).status, 204, 'a retry of the claim that won');
    assert.deepEqual(await (await fetch(`${t.url}/v0/health`)).json(), { protocol: 0, claimed: true, instance: t.relay.config.instance });
    assert.equal((await fetch(`${t.url}/v0/devices`, { headers: bearer(token) })).status, 200, 'the owner token works');
    await t.close();
});

test('after the claim every other claim is 409, whatever the code, even after a restart (§6)', async () => {
    const t = await startTestRelay({ claimTiming: fast });
    assert.equal((await post(t, { setup_code: SETUP_CODE, owner_token_sha256: tokenHash(newToken()) })).status, 204);
    for (const code of [SETUP_CODE, OTHER_CODE]) {
        assert.equal((await post(t, { setup_code: code, owner_token_sha256: tokenHash(newToken()) })).status, 409);
    }
    await t.close();
    const again = await startTestRelay({ raw: t.raw, env: { SPRAVA_SETUP_CODE: '' } });
    assert.equal((await post(again, { setup_code: SETUP_CODE, owner_token_sha256: tokenHash(newToken()) })).status, 409);
    await again.close();
});

test('the token-hash vector: an uppercase hash is refused as owner_token_sha256 (§14 case 9)', async () => {
    const t = await startTestRelay({ claimTiming: fast });
    const v = vectors['token-hash'];
    assert.equal((await post(t, { setup_code: SETUP_CODE, owner_token_sha256: v.refused_owner_token_sha256 })).status, 400);
    assert.equal((await post(t, { setup_code: SETUP_CODE, owner_token_sha256: v.sha256 })).status, 204);
    assert.equal((await fetch(`${t.url}/v0/devices`, { headers: bearer(v.token) })).status, 200);
    assert.equal((await fetch(`${t.url}/v0/devices`, { headers: bearer(v.refused_bearer) })).status, 401, 'the padded token as a bearer value');
    await t.close();
});

test('malformed claims are 400, and a claim with an Origin header is 403 (§6, §7.7)', async () => {
    const t = await startTestRelay({ claimTiming: fast });
    const hash = tokenHash(newToken());
    assert.equal((await post(t, { setup_code: SETUP_CODE })).status, 400);
    assert.equal((await post(t, `{"setup_code":"${SETUP_CODE}","setup_code":"x","owner_token_sha256":"${hash}"}`)).status, 400);
    assert.equal((await post(t, { setup_code: 'x'.repeat(1100), owner_token_sha256: hash })).status, 413);
    assert.equal((await post(t, { setup_code: SETUP_CODE, owner_token_sha256: hash }, { Origin: WEB_ORIGIN })).status, 403);
    assert.equal(await t.relay.store.get('owner.json'), null);
    await t.close();
});

test('wrong codes: 403 five times per address, then 429 after a delay; a correct code still claims (§6)', async () => {
    const t = await startTestRelay({ claimTiming: fast });
    const wrong = { setup_code: OTHER_CODE, owner_token_sha256: tokenHash(newToken()) };
    for (let i = 0; i < 5; i++) assert.equal((await post(t, wrong)).status, 403);
    const started = performance.now();
    assert.equal((await post(t, wrong)).status, 429);
    assert.ok(performance.now() - started >= 45);
    assert.equal((await post(t, { setup_code: SETUP_CODE, owner_token_sha256: tokenHash(newToken()) })).status, 204);
    await t.close();
});

test('claims are paced; one that waits too long is 503 with Retry-After (§6 step 1)', async () => {
    const t = await startTestRelay({ claimTiming: { ...CLAIM_TIMING, intervalMs: 40, maxWaitMs: 100, failureDelayMs: 1 } });
    const wrong = { setup_code: OTHER_CODE, owner_token_sha256: tokenHash(newToken()) };
    const answers = await Promise.all(Array.from({ length: 8 }, () => post(t, wrong)));
    const statuses = answers.map((r) => r.status);
    assert.ok(statuses.includes(503), statuses.join());
    assert.equal(answers.find((r) => r.status === 503)!.headers.get('retry-after'), '1');
    assert.ok(statuses.filter((s) => s !== 503).length <= 4, statuses.join());
    await t.close();
});
