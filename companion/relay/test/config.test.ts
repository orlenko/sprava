import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { test } from 'node:test';
import { ConfigError, isOrigin, isSetupCode, readConfig } from '../src/config.ts';

const base = {
    SPRAVA_INSTANCE: '0123456789abcdef0123456789abcdef',
    SPRAVA_WEB_ORIGIN: 'https://companion.example.org',
    SPRAVA_STORAGE: 'fs:/tmp/sprava-relay-example',
};

test('a complete environment is read, with port 8080 by default', () => {
    const config = readConfig(base);
    assert.equal(config.port, 8080);
    assert.equal(config.setupCode, null);
    assert.deepEqual(config.storage, { kind: 'fs', dir: '/tmp/sprava-relay-example' });
});

test('each required variable is required, and nothing has a default that points anywhere', () => {
    for (const name of Object.keys(base)) {
        assert.throws(() => readConfig({ ...base, [name]: undefined }), ConfigError, name);
        assert.throws(() => readConfig({ ...base, [name]: '' }), ConfigError, name);
    }
});

test('malformed values are refused', () => {
    for (const [name, value] of [
        ['SPRAVA_INSTANCE', '0123456789ABCDEF0123456789ABCDEF'],
        ['SPRAVA_INSTANCE', 'relay'],
        ['SPRAVA_WEB_ORIGIN', 'https://companion.example.org/'],
        ['SPRAVA_WEB_ORIGIN', 'http://companion.example.org'],
        ['SPRAVA_STORAGE', 'fs:relative/dir'],
        ['SPRAVA_STORAGE', 'memory'],
        ['PORT', '0'],
        ['PORT', '80a'],
    ]) {
        assert.throws(() => readConfig({ ...base, [name!]: value }), ConfigError, `${name}=${value}`);
    }
});

test('s3 storage needs its endpoint, region, bucket and key', () => {
    const s3 = {
        ...base,
        SPRAVA_STORAGE: 's3',
        S3_ENDPOINT: 'https://region.storage.example.org',
        S3_REGION: 'region',
        S3_BUCKET: 'bucket-example',
        S3_ACCESS_KEY_ID: 'key-id-example',
        S3_SECRET_ACCESS_KEY: 'secret-example',
    };
    const config = readConfig(s3);
    assert.equal(config.storage.kind, 's3');
    for (const name of ['S3_ENDPOINT', 'S3_REGION', 'S3_BUCKET', 'S3_ACCESS_KEY_ID', 'S3_SECRET_ACCESS_KEY']) {
        assert.throws(() => readConfig({ ...s3, [name]: undefined }), ConfigError, name);
    }
    assert.throws(() => readConfig({ ...s3, S3_ENDPOINT: 'https://region.storage.example.org/bucket' }), ConfigError);
    assert.throws(() => readConfig({ ...s3, S3_ENDPOINT: 'http://region.storage.example.org' }), ConfigError);
});

test('a setup code is exactly what `openssl rand -base64 32` prints (§6)', () => {
    for (let i = 0; i < 50; i++) assert.ok(isSetupCode(randomBytes(32).toString('base64')));
    const code = randomBytes(32).toString('base64');
    assert.ok(!isSetupCode(code.slice(0, -1)), 'without its padding');
    assert.ok(!isSetupCode('-' + code.slice(1)), 'the url alphabet');
    assert.ok(!isSetupCode(randomBytes(33).toString('base64')), '33 bytes');
    assert.ok(!isSetupCode(code.slice(0, 42) + 'B='), 'non-zero trailing bits');
});

test('origins have no path, and plain http only for localhost', () => {
    assert.ok(isOrigin('https://companion.example.org'));
    assert.ok(isOrigin('https://companion.example.org:8443'));
    assert.ok(isOrigin('http://localhost:5173'));
    assert.ok(!isOrigin('https://companion.example.org/app'));
    assert.ok(!isOrigin('HTTPS://companion.example.org'));
    assert.ok(!isOrigin('companion.example.org'));
});
