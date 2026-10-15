// Local preview of build output; deliberately binds only to localhost.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
const root = new URL('./dist/', import.meta.url);
const mime = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json',
    '.webmanifest': 'application/manifest+json', '.svg': 'image/svg+xml' };
const server = createServer(async (request, response) => {
    try {
        if (!request.url?.startsWith('/') || request.url.startsWith('//')) throw Error();
        const path = new URL(request.url, 'http://localhost').pathname;
        if (request.method !== 'GET' || !/^\/[a-zA-Z0-9_./-]*$/.test(path) || path.includes('..')) throw Error();
        const file = path === '/' ? 'index.html' : path.slice(1);
        const target = new URL(file, root);
        if (file.startsWith('/') || !target.href.startsWith(root.href)) throw Error();
        const body = await readFile(target);
        response.setHeader('Content-Type', mime[file.slice(file.lastIndexOf('.'))] ?? 'application/octet-stream');
        response.setHeader('Cache-Control', 'no-cache'); response.end(body);
    } catch { response.writeHead(404); response.end(); }
});
server.listen(Number(process.env.SPRAVA_WEB_PORT ?? 5173), 'localhost', () => {
    console.log(`Sprava preview: http://localhost:${server.address().port}`);
});
