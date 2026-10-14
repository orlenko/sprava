import assert from 'node:assert/strict';
import { test } from 'node:test';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { request } from 'node:http';
import { cp, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

test('preview serves build files and refuses repeated slashes escaping the build directory', async () => {
    const folder = await mkdtemp(join(tmpdir(), 'sprava-preview-'));
    let child: ReturnType<typeof spawn> | undefined, exited: Promise<unknown> | undefined;
    try {
        await mkdir(join(folder, 'dist', 'web', 'src'), { recursive: true });
        await cp(new URL('../serve.mjs', import.meta.url), join(folder, 'serve.mjs'));
        await writeFile(join(folder, 'dist', 'index.html'), 'Invented app shell');
        await writeFile(join(folder, 'dist', 'web', 'src', 'app.js'), 'Invented app module');
        await writeFile(join(folder, 'private-fixture'), 'Invented outside marker');
        child = spawn(process.execPath, [join(folder, 'serve.mjs')], {
            env: { ...process.env, SPRAVA_WEB_PORT: '0' }, stdio: ['ignore', 'pipe', 'pipe'] });
        exited = once(child, 'exit');
        const port = await new Promise<number>((resolve, reject) => {
            let output = '';
            child!.stdout!.on('data', bytes => { output += bytes.toString();
                const match = /http:\/\/localhost:(\d+)/.exec(output); if (match) resolve(Number(match[1])); });
            child!.once('error', reject); child!.once('exit', () => reject(new Error('Preview exited')));
        });
        const get = (path: string) => new Promise<{ status: number; body: string }>((resolve, reject) => {
            request({ hostname: 'localhost', port, path }, response => {
                let body = ''; response.on('data', chunk => { body += chunk.toString(); });
                response.on('end', () => resolve({ status: response.statusCode!, body }));
            }).on('error', reject).end();
        });
        assert.deepEqual(await get('/'), { status: 200, body: 'Invented app shell' });
        assert.deepEqual(await get('/web/src/app.js'), { status: 200, body: 'Invented app module' });
        for (const path of [`//ignored/${folder}/private-fixture`, `//ignored//${folder}/private-fixture`,
            '///index.html', '/%2fprivate-fixture', '/../private-fixture']) {
            const reply = await get(path); assert.equal(reply.status, 404);
            assert.equal(reply.body.includes('Invented outside marker'), false);
        }
    } finally { child?.kill('SIGTERM'); if (exited) await exited; await rm(folder, { recursive: true, force: true }); }
});
