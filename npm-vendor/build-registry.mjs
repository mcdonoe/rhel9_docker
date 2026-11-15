#!/usr/bin/env node
// Builds the vendored npm registry from pnpm-lock.yaml. Runs once, at image
// build time, with network access; serve.mjs serves the result offline.
//
//   node build-registry.mjs <pnpm-lock.yaml> <out-dir>
//
// For every package in the lockfile it writes a registry document (the
// "packument") that lists only the vendored versions, and downloads every
// tarball this platform (linux x64 glibc) can install, checking each against
// the lockfile's integrity hash. Versions for other platforms stay listed, so
// resolution matches the public registry, but they have no tarball: pnpm and
// npm skip them by their os/cpu/libc fields and never ask for one.
//
// Output:
//   <out>/packuments/<name>.json        tarball URLs start with @@REGISTRY@@
//   <out>/tarballs/<name>/-/<file>.tgz
//
// No dependencies beyond Node itself.
import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';

const UPSTREAM = 'https://registry.npmjs.org';
const PLATFORM = { os: 'linux', cpu: 'x64', libc: 'glibc' };
const CONCURRENCY = 16;

const [lockPath, outDir] = process.argv.slice(2);
if (!lockPath || !outDir) {
  console.error('usage: build-registry.mjs <pnpm-lock.yaml> <out-dir>');
  process.exit(2);
}

// --- read the lockfile's packages: section ---------------------------------
// Entries look like:
//   '@scope/name@1.2.3':
//     resolution: {integrity: sha512-...}
//     cpu: [x64]
const lock = await readFile(lockPath, 'utf8');
const start = lock.indexOf('\npackages:\n');
const end = lock.indexOf('\nsnapshots:\n');
if (start < 0 || end < 0) throw new Error('no packages:/snapshots: sections in the lockfile');
const section = lock.slice(start, end) + '\n';

const entries = [];
const entryRe = /^  '?((?:@[^/@'\s]+\/)?[^@'\s]+)@([^'():\s]+)'?:\n((?:    .*\n)*)/gm;
for (const m of section.matchAll(entryRe)) {
  const [, name, version, body] = m;
  const integrity = /resolution: \{integrity: ([^,}\s]+)/.exec(body)?.[1];
  if (!integrity) {
    throw new Error(`${name}@${version}: not from the npm registry (no integrity); vendor it another way`);
  }
  const list = (key) => {
    const v = new RegExp(`^    ${key}: \\[([^\\]]*)\\]`, 'm').exec(body)?.[1];
    return v === undefined ? undefined : v.split(',').map((s) => s.trim().replace(/^'|'$/g, ''));
  };
  entries.push({ name, version, integrity, os: list('os'), cpu: list('cpu'), libc: list('libc') });
}
if (entries.length === 0) throw new Error('found no packages in the lockfile');

// npm's os/cpu/libc rules: a list of allowed values, or of "!value" exclusions.
function allows(list, value) {
  if (!list || list.length === 0) return true;
  if (list.includes(`!${value}`)) return false;
  return list.every((v) => v.startsWith('!')) || list.includes(value);
}
const forThisPlatform = (e) =>
  allows(e.os, PLATFORM.os) && allows(e.cpu, PLATFORM.cpu) && allows(e.libc, PLATFORM.libc);

// --- helpers ----------------------------------------------------------------
async function fetchRetry(url, as) {
  for (let attempt = 1; ; attempt++) {
    try {
      const res = await fetch(url, { headers: { accept: 'application/json' } });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return as === 'json' ? await res.json() : Buffer.from(await res.arrayBuffer());
    } catch (err) {
      if (attempt >= 4) throw new Error(`${url}: ${err.message}`);
      await new Promise((r) => setTimeout(r, 1000 * attempt));
    }
  }
}

async function pool(items, fn) {
  let next = 0;
  await Promise.all(
    Array.from({ length: CONCURRENCY }, async () => {
      while (next < items.length) await fn(items[next++]);
    }),
  );
}

function checkIntegrity(buf, integrity, what) {
  const [algo, expected] = integrity.split(/-(.*)/s);
  const actual = createHash(algo).update(buf).digest('base64');
  if (actual !== expected) throw new Error(`${what}: integrity mismatch`);
}

// Highest version by semver precedence (enough for dist-tags.latest).
function compareSemver(a, b) {
  const parse = (v) => {
    const [core, pre] = v.split(/-(.*)/s);
    return { nums: core.split('.').map(Number), pre: pre ? pre.split('.') : [] };
  };
  const x = parse(a), y = parse(b);
  for (let i = 0; i < 3; i++) if (x.nums[i] !== y.nums[i]) return x.nums[i] - y.nums[i];
  if (!x.pre.length || !y.pre.length) return y.pre.length - x.pre.length;
  for (let i = 0; i < Math.max(x.pre.length, y.pre.length); i++) {
    const p = x.pre[i], q = y.pre[i];
    if (p === undefined) return -1;
    if (q === undefined) return 1;
    if (p === q) continue;
    const pn = /^\d+$/.test(p), qn = /^\d+$/.test(q);
    if (pn && qn) return Number(p) - Number(q);
    if (pn !== qn) return pn ? -1 : 1;
    return p < q ? -1 : 1;
  }
  return 0;
}

// --- build -------------------------------------------------------------------
const byName = new Map();
for (const e of entries) {
  if (!byName.has(e.name)) byName.set(e.name, []);
  byName.get(e.name).push(e);
}

let tarballs = 0, skipped = 0, bytes = 0;
await pool([...byName.keys()], async (name) => {
  const doc = await fetchRetry(`${UPSTREAM}/${name.replace('/', '%2f')}`, 'json');
  const versions = {}, time = {};
  for (const e of byName.get(name)) {
    const manifest = doc.versions?.[e.version];
    if (!manifest) throw new Error(`${name}@${e.version}: not on ${UPSTREAM}`);
    const file = manifest.dist.tarball.split('/').pop();
    if (manifest.dist.integrity && manifest.dist.integrity !== e.integrity) {
      throw new Error(`${name}@${e.version}: registry integrity differs from the lockfile`);
    }
    versions[e.version] = {
      ...manifest,
      dist: { ...manifest.dist, integrity: e.integrity, tarball: `@@REGISTRY@@/${name}/-/${file}` },
    };
    if (doc.time?.[e.version]) time[e.version] = doc.time[e.version];

    if (!forThisPlatform(e)) { skipped++; continue; }
    const buf = await fetchRetry(manifest.dist.tarball, 'buffer');
    checkIntegrity(buf, e.integrity, `${name}@${e.version}`);
    const dest = join(outDir, 'tarballs', name, '-', file);
    await mkdir(dirname(dest), { recursive: true });
    await writeFile(dest, buf);
    tarballs++;
    bytes += buf.length;
  }
  const latest = Object.keys(versions).sort(compareSemver).pop();
  const packument = { name, 'dist-tags': { latest }, versions, time };
  const dest = join(outDir, 'packuments', `${name}.json`);
  await mkdir(dirname(dest), { recursive: true });
  await writeFile(dest, JSON.stringify(packument));
});

console.log(
  `vendored ${byName.size} packages, ${entries.length} versions: ` +
    `${tarballs} tarballs (${(bytes / 1048576).toFixed(0)} MB), ` +
    `${skipped} for other platforms listed without tarballs`,
);
