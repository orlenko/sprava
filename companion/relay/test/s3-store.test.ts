import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { parseListPage, S3Store, signV4 } from '../src/store/s3.ts';
import { Mutex, writeOnce } from '../src/store/store.ts';
import { S3_CREDENTIALS, startS3Stub, type S3Stub } from './s3-stub.ts';
import { INSTANCE, startTestRelay } from './harness.ts';
import { storeContract } from './store-contract.ts';

const stubs: S3Stub[] = [];
after(() => Promise.all(stubs.map((s) => s.close())));

async function open(options: { ignoreIfNoneMatch?: boolean } = {}): Promise<{ store: S3Store; stub: S3Stub }> {
    const stub = await startS3Stub(options);
    stubs.push(stub);
    return { store: new S3Store({ endpoint: stub.endpoint, bucket: stub.bucket, ...S3_CREDENTIALS }), stub };
}

storeContract('s3', async () => (await open()).store);
storeContract('s3 that ignores If-None-Match', async () => (await open({ ignoreIfNoneMatch: true })).store, { honoursIfAbsent: false });

test('SigV4 reproduces the GetObject example of the AWS documentation', () => {
    const headers = signV4({
        method: 'GET',
        host: 'examplebucket.s3.amazonaws.com',
        path: '/test.txt',
        query: {},
        headers: { range: 'bytes=0-9' },
        payload: new Uint8Array(),
        date: new Date('2013-05-24T00:00:00Z'),
        region: 'us-east-1',
        accessKeyId: 'AKIAIOSFODNN7EXAMPLE',
        secretAccessKey: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
    });
    assert.equal(
        headers.authorization,
        'AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, ' +
            'SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, ' +
            'Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41',
    );
});

test('s3: a listing longer than one page is read whole', async () => {
    const { store } = await open();
    const keys = Array.from({ length: 10 }, (_, i) => `p/${String(i).padStart(2, '0')}`);
    for (const key of keys) await store.put(key, new Uint8Array([1]));
    assert.deepEqual(await store.list('p/'), keys);
});

test('s3: write-once holds under the lock even on a store that overwrites despite If-None-Match (§6)', async () => {
    const { store, stub } = await open({ ignoreIfNoneMatch: true });
    const lock = new Mutex();
    const results = await Promise.all(['a', 'b'].map((t) => lock.run(() => writeOnce(store, 'owner.json', Buffer.from(t)))));
    assert.deepEqual(results, ['created', 'different']);
    assert.equal(Buffer.from(stub.objects.get('owner.json')!).toString(), 'a');
});

test('s3: a 5xx is retried, and a wrong key is an error, not an empty answer', async () => {
    const { store, stub } = await open();
    await store.put('k', new Uint8Array([7]));
    stub.failNext(2);
    assert.deepEqual(await store.get('k'), new Uint8Array([7]));
    stub.failNext(3);
    await assert.rejects(store.get('k'), /status 503/);
    const wrong = new S3Store({ endpoint: stub.endpoint, bucket: stub.bucket, ...S3_CREDENTIALS, secretAccessKey: 'other' });
    await assert.rejects(wrong.get('k'), /status 403/);
    await assert.rejects(wrong.list(''), /status 403/);
});

test('s3: the relay runs over a bucket, under its instance prefix (§7.8)', async () => {
    const { store, stub } = await open();
    await store.put(`${INSTANCE}/owner.json`, Buffer.from(`{"owner_token_sha256":"${'a'.repeat(64)}"}`));
    const t = await startTestRelay({ raw: store });
    assert.deepEqual(await (await fetch(`${t.url}/v0/health`)).json(), { protocol: 0, claimed: true, instance: INSTANCE });
    assert.ok([...stub.objects.keys()].every((k) => k.startsWith(`${INSTANCE}/`)));
    await t.close();
});

test('s3: keys with characters that need encoding are signed and stored as they are', async () => {
    const { store, stub } = await open();
    await store.put('requests/AAAA-_x/0000000000000001-B_c-d', new Uint8Array([1]));
    assert.ok(stub.objects.has('requests/AAAA-_x/0000000000000001-B_c-d'));
    assert.deepEqual(await store.list('requests/'), ['requests/AAAA-_x/0000000000000001-B_c-d']);
});

test('s3: a malformed or incomplete listing page is an error, never a shorter listing', async () => {
    const page = (inner: string) => `<?xml version="1.0" encoding="UTF-8"?><ListBucketResult>${inner}</ListBucketResult>`;
    const good = page('<IsTruncated>false</IsTruncated><KeyCount>1</KeyCount><Contents><Key>p/a&amp;b</Key><LastModified>2026-10-08T07:00:00.000Z</LastModified></Contents>');
    assert.deepEqual(parseListPage(good, 'p/'), { entries: [{ key: 'p/a&b', modified: Date.parse('2026-10-08T07:00:00Z') }], next: null });
    const bad = {
        'cut short': good.slice(0, good.indexOf('</Contents>')),
        'no IsTruncated': page('<Contents><Key>p/a</Key></Contents>'),
        'two IsTruncated': page('<IsTruncated>false</IsTruncated><IsTruncated>true</IsTruncated>'),
        'truncated without a token': page('<IsTruncated>true</IsTruncated><Contents><Key>p/a</Key></Contents>'),
        'a Contents without a Key': page('<IsTruncated>false</IsTruncated><Contents></Contents>'),
        'a key outside the prefix': page('<IsTruncated>false</IsTruncated><Contents><Key>q/a</Key></Contents>'),
        'a count that does not match': page('<IsTruncated>false</IsTruncated><KeyCount>2</KeyCount><Contents><Key>p/a</Key></Contents>'),
        'another root': '<Error><Code>InternalError</Code></Error>',
        'a bare ampersand': page('<IsTruncated>false</IsTruncated><Contents><Key>p/a&b</Key></Contents>'),
        'text after the root': good + 'x',
        'an empty body': '',
    };
    for (const [why, xml] of Object.entries(bad)) assert.throws(() => parseListPage(xml, 'p/'), /LIST failed/, why);
    const { store, stub } = await open();
    await store.put('p/1', new Uint8Array([1]));
    stub.nextListBody(good.slice(0, good.indexOf('</Contents>')));
    await assert.rejects(store.list('p/'), /LIST failed/);
});

test('s3: a write that failed may land later, so its key refuses other bytes until it is confirmed (§7.8)', async () => {
    const { store, stub } = await open({ ignoreIfNoneMatch: true });
    const lock = new Mutex();
    stub.hold((key) => key === 'devices/D/record.json');
    await assert.rejects(lock.run(() => writeOnce(store, 'devices/D/record.json', Buffer.from('A'))), /status 500/);
    assert.equal(await lock.run(() => writeOnce(store, 'devices/D/record.json', Buffer.from('B'))), 'different');
    stub.landHeld();
    assert.equal(Buffer.from(stub.objects.get('devices/D/record.json')!).toString(), 'A');
    assert.equal(await lock.run(() => writeOnce(store, 'devices/D/record.json', Buffer.from('A'))), 'same');
});
