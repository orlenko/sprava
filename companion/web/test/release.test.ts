import assert from 'node:assert/strict';
import { test } from 'node:test';
import { releaseInfo } from '../release.ts';

const commit = '0123456789abcdef0123456789abcdef01234567';

test('the build shows the release tag it was published from, or the package version locally', () => {
    assert.deepEqual(releaseInfo({ SPRAVA_RELEASE: 'v0.4.0' }, '0.0.0', commit), { version: 'v0.4.0', commit });
    assert.deepEqual(releaseInfo({}, '0.0.0', commit), { version: '0.0.0', commit });
    assert.deepEqual(releaseInfo({ SPRAVA_RELEASE: '' }, '0.0.0', commit), { version: '0.0.0', commit });
});

test('a tag that is not plain text, or a commit that is not a full SHA, stops the build', () => {
    for (const tag of ['<b>v1</b>', 'v1 two', '-v1', 'x'.repeat(65)])
        assert.throws(() => releaseInfo({ SPRAVA_RELEASE: tag }, '0.0.0', commit), /SPRAVA_RELEASE/);
    assert.throws(() => releaseInfo({}, '0.0.0', 'abc123'), /commit/);
});
