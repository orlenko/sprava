// Static build only. No relay URLs, tokens or binder contents enter the app shell cache.
import { cp, readdir, readFile, writeFile, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
const directory = fileURLToPath(new URL('.', import.meta.url));
const destination = new URL('./dist/', import.meta.url);
if (process.argv.includes('--clean')) { await rm(destination, { recursive: true, force: true }); process.exit(0); }
await cp(new URL('./public/', import.meta.url), destination, { recursive: true });
const pkg = JSON.parse(await readFile(new URL('./package.json', import.meta.url), 'utf8'));
const commit = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: directory, encoding: 'utf8' }).trim();
await writeFile(new URL('release.json', destination), JSON.stringify({ version: pkg.version, commit }));
async function files(at, prefix = '') {
    const paths = [];
    for (const entry of await readdir(at, { withFileTypes: true })) {
        const path = prefix + entry.name;
        if (entry.isDirectory()) paths.push(...await files(new URL(entry.name + '/', at), path + '/'));
        else if (entry.isFile() && entry.name !== 'sw.js') paths.push(path);
    }
    return paths.sort();
}
const paths = await files(destination), hash = createHash('sha256');
for (const path of paths) { hash.update(path); hash.update(await readFile(new URL(path, destination))); }
const cacheName = `sprava-shell-${hash.digest('hex').slice(0, 20)}`;
await writeFile(new URL('sw.js', destination), `
const name = ${JSON.stringify(cacheName)};
const assets = ${JSON.stringify(paths)}.map(path => new URL(path, self.registration.scope).href);
const home = new URL('./', self.registration.scope).href;
self.addEventListener('install', event => {
    event.waitUntil(caches.open(name).then(cache => cache.addAll(assets)));
});
// New releases wait until existing windows close, so running modules never mix releases.
self.addEventListener('activate', event => event.waitUntil((async () => {
    for (const key of await caches.keys()) if (key.startsWith('sprava-shell-') && key !== name) await caches.delete(key);
    await self.clients.claim();
})()));
self.addEventListener('fetch', event => {
    if (event.request.method !== 'GET') return;
    const url = new URL(event.request.url);
    const asset = url.href === home ? new URL('index.html', home).href : url.href;
    // Only this explicit static build can be cached. Every API request bypasses the worker.
    if (!assets.includes(asset)) return;
    event.respondWith(caches.open(name).then(cache => cache.match(asset)).then(saved => saved || fetch(event.request)));
});
`);
