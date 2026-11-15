#!/usr/bin/env node
// Serves the vendored npm registry that build-registry.mjs made, read-only,
// on 127.0.0.1. The container's entrypoint starts it and points npm and pnpm
// at it, so installs need no network and see only vendored versions.
//
//   node serve.mjs [PORT_FILE]
//
// Listens on a free port the kernel picks, so containers sharing the host's
// network never clash, and writes that port to PORT_FILE (or stdout).
// Anything not vendored gets a 404 that says so.
import { createReadStream } from 'node:fs';
import { readFile, stat, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { dirname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = process.env.RHEL9DEV_NPM_REGISTRY_DIR || dirname(fileURLToPath(import.meta.url));
const portFile = process.argv[2];
let base = '';
const cache = new Map();

function send(res, status, body, type = 'application/json') {
  res.writeHead(status, { 'content-type': type, 'content-length': Buffer.byteLength(body) });
  res.end(body);
}

function notVendored(res, what) {
  send(res, 404, JSON.stringify({
    error: `${what} is not in the rhel9-dev vendored npm set (see /opt/npm-vendor/package.json)`,
  }));
}

const server = createServer(async (req, res) => {
  try {
    if (req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, '{}');
    // npm sends scoped names as @scope%2fname; pnpm as @scope/name.
    const path = decodeURIComponent(new URL(req.url, 'http://x').pathname).replace(/^\/+/, '');
    if (path === '-/ping') return send(res, 200, '{}');
    if (path.includes('..') || normalize(path) !== path) return send(res, 400, '{}');

    const tarball = /^((?:@[^/]+\/)?[^/@][^/]*)\/-\/([^/]+\.tgz)$/.exec(path);
    if (tarball) {
      const file = join(ROOT, 'tarballs', tarball[1], '-', tarball[2]);
      const info = await stat(file).catch(() => null);
      if (!info) return notVendored(res, `${tarball[1]} tarball ${tarball[2]}`);
      res.writeHead(200, { 'content-type': 'application/octet-stream', 'content-length': info.size });
      if (req.method === 'HEAD') return res.end();
      return createReadStream(file).pipe(res);
    }

    if (/^(?:@[^/]+\/)?[^/@][^/]*$/.test(path)) {
      let body = cache.get(path);
      if (body === undefined) {
        const raw = await readFile(join(ROOT, 'packuments', `${path}.json`), 'utf8').catch(() => null);
        if (raw === null) return notVendored(res, `package ${path}`);
        body = raw.replaceAll('@@REGISTRY@@', base);
        cache.set(path, body);
      }
      return send(res, 200, req.method === 'HEAD' ? '' : body);
    }
    return send(res, 404, JSON.stringify({ error: `not found: ${path}` }));
  } catch (err) {
    send(res, 500, JSON.stringify({ error: String(err) }));
  }
});

server.listen(Number(process.env.RHEL9DEV_NPM_REGISTRY_PORT || 0), '127.0.0.1', async () => {
  const { port } = server.address();
  base = `http://127.0.0.1:${port}`;
  if (portFile) await writeFile(portFile, `${port}\n`);
  else console.log(port);
});
