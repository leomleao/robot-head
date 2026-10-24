/* Captures the TS robot's still poses as PNGs, the references the Swift
   port is checked against: docs/swift-port/reference/web/*.png and
   manifest.json.

   Each image is the canvas's own pixels (toDataURL), at a device pixel
   ratio of exactly 2, read from the dev-only capture page
   (site/src/lab/capture.html) in headless Chrome, driven over the DevTools
   protocol with nothing but Node (22+, for its WebSocket).

   node scripts/swift/capture-web-references.mjs           write the references
   node scripts/swift/capture-web-references.mjs --check   compare against the ones on disk, write nothing

   It starts the site's dev server itself unless given --url <origin> of one
   already running. The browser is Google Chrome unless --chrome <binary> (or
   $CHROME) names another; its version goes in the manifest, since another
   version may rasterise a little differently. */

import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../', import.meta.url));
const outDir = fileURLToPath(new URL('../../docs/swift-port/reference/web/', import.meta.url));
const args = process.argv.slice(2);
const check = args.includes('--check');
const opt = (name) => (args.includes(name) ? args[args.indexOf(name) + 1] : null);
const urlArg = opt('--url');
const chromePath = opt('--chrome') ?? process.env.CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PORT = 5391;

/* headless Chrome at 2×, and a way to send it DevTools commands */
async function chrome() {
  const profile = mkdtempSync(join(tmpdir(), 'robot-capture-'));
  /* the canvas rasterised on the CPU: on the GPU, re-runs differ by a few pixels */
  const p = spawn(chromePath, ['--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profile}`, '--no-first-run', '--no-default-browser-check', '--force-device-scale-factor=2', '--disable-gpu', '--disable-accelerated-2d-canvas', '--hide-scrollbars', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
  const wsUrl = await new Promise((resolve, reject) => {
    let err = '';
    p.stderr.on('data', (d) => {
      err += d;
      const m = err.match(/DevTools listening on (ws:\S+)/);
      if (m) resolve(m[1]);
    });
    p.on('exit', (code) => reject(new Error(`${chromePath} exited (${code}): ${err}`)));
  });
  const ws = new WebSocket(wsUrl);
  await new Promise((r, j) => ((ws.onopen = r), (ws.onerror = j)));
  let next = 0;
  const pending = new Map(), waiting = [];
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.id && pending.has(m.id)) {
      const { resolve, reject } = pending.get(m.id);
      pending.delete(m.id);
      m.error ? reject(new Error(m.error.message)) : resolve(m.result);
    } else if (m.method) for (const w of waiting.filter((w) => w.method === m.method && w.sessionId === m.sessionId)) waiting.splice(waiting.indexOf(w), 1), w.resolve(m.params);
  };
  const send = (method, params = {}, sessionId) =>
    new Promise((resolve, reject) => {
      pending.set(++next, { resolve, reject });
      ws.send(JSON.stringify({ id: next, method, params, sessionId }));
    });
  const once = (method, sessionId) => new Promise((resolve) => waiting.push({ method, sessionId, resolve }));
  /* Chrome still writes to its profile while it quits */
  const close = async () => {
    ws.close();
    const exited = new Promise((r) => p.once('exit', r));
    p.kill();
    await exited;
    rmSync(profile, { recursive: true, force: true, maxRetries: 5 });
  };
  return { send, once, close };
}

/* one tab: load a page, run an expression in it */
async function tab(browser) {
  const { targetId } = await browser.send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await browser.send('Target.attachToTarget', { targetId, flatten: true });
  await browser.send('Page.enable', {}, sessionId);
  return {
    async goto(url) {
      const loaded = browser.once('Page.loadEventFired', sessionId);
      await browser.send('Page.navigate', { url }, sessionId);
      await loaded;
    },
    async eval(expression) {
      const r = await browser.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, sessionId);
      if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text);
      return r.result.value;
    },
  };
}

/* the site's dev server, unless one was given */
async function devServer() {
  if (urlArg) return { origin: urlArg.replace(/\/$/, ''), stop() {} };
  const origin = `http://localhost:${PORT}`;
  const p = spawn('pnpm', ['--dir', 'site', 'exec', 'vite', '--port', String(PORT), '--strictPort'], { cwd: root, detached: true, stdio: 'ignore' });
  const stop = () => {
    try {
      process.kill(-p.pid);
    } catch {}
  };
  for (let i = 0; i < 120; i++) {
    try {
      if ((await fetch(`${origin}/src/lab/capture`)).ok) return { origin, stop };
    } catch {}
    await new Promise((r) => setTimeout(r, 250));
  }
  stop();
  throw new Error(`dev server did not come up on ${origin}`);
}

/* what to capture: a file name and the page's query */
function plan(states, expressions) {
  const shots = [];
  for (const state of states) shots.push({ file: `state-${state}.png`, params: { state, size: 240 } });
  for (const expression of expressions) shots.push({ file: `expression-${expression}.png`, params: { state: 'idle', expression, size: 240 } });
  /* 96 is below the low-detail threshold, so these use the small mesh */
  shots.push({ file: 'small-idle.png', params: { state: 'idle', size: 96 } });
  for (const expression of ['happy', 'defense', 'asleep']) shots.push({ file: `small-${expression}.png`, params: { state: 'idle', expression, size: 96 } });
  shots.push({ file: 'colors-rust-moonlight.png', params: { state: 'idle', size: 240, color: '#6b3f2e', eyeColor: '#bfe3ff' } });
  shots.push({ file: 'floor-shadow-off.png', params: { state: 'idle', size: 240, floorShadow: false } });
  return shots;
}

/* waits for the page at `href`, then reads the canvas and checks it */
const READ = (href) => `(async () => {
  for (let i = 0; i < 200 && !(location.href === ${JSON.stringify(href)} && window.capture); i++) await new Promise((r) => setTimeout(r, 25));
  const c = window.capture;
  if (!c) throw new Error('capture page never got ready');
  const px = c.canvas.getContext('2d').getImageData(0, 0, c.width, c.height).data;
  let opaque = 0;
  for (let i = 3; i < px.length; i += 4) if (px[i]) opaque++;
  const corners = [0, c.width - 1, (c.height - 1) * c.width, c.height * c.width - 1].map((p) => px[p * 4 + 3]);
  return {
    params: c.params, dpr: c.dpr, frame: c.frame, states: c.states, expressions: c.expressions,
    width: c.width, height: c.height, cssWidth: c.cssWidth, cssHeight: c.cssHeight,
    opaque, corners, png: c.canvas.toDataURL('image/png'),
  };
})()`;

/* how many pixels of the canvas differ from a PNG, both decoded the same way by the same browser */
const DIFF = (png) => `(async () => {
  const c = window.capture;
  const pixels = async (src) => {
    const img = new Image();
    img.src = src;
    await img.decode();
    const o = new OffscreenCanvas(img.width, img.height).getContext('2d');
    o.drawImage(img, 0, 0);
    return { w: img.width, h: img.height, px: o.getImageData(0, 0, img.width, img.height).data };
  };
  const a = await pixels(${JSON.stringify(png)}), b = await pixels(c.canvas.toDataURL('image/png'));
  if (a.w !== b.w || a.h !== b.h) return { size: [a.w, a.h], differing: -1 };
  let n = 0;
  for (let i = 0; i < a.px.length; i += 4) if (a.px[i] !== b.px[i] || a.px[i + 1] !== b.px[i + 1] || a.px[i + 2] !== b.px[i + 2] || a.px[i + 3] !== b.px[i + 3]) n++;
  return { size: [a.w, a.h], differing: n };
})()`;

const query = (p) => new URLSearchParams(Object.entries(p).map(([k, v]) => [k, String(v)])).toString();

const server = await devServer();
const browser = await chrome();
const failures = [];
try {
  const page = await tab(browser);
  const { product } = await browser.send('Browser.getVersion');
  await page.goto(`${server.origin}/src/lab/capture`);
  const first = await page.eval(READ(`${server.origin}/src/lab/capture`));
  const shots = plan(first.states, first.expressions);
  const manifest = { generatedBy: 'scripts/swift/capture-web-references.mjs', page: 'site/src/lab/capture.html', dpr: 2, browser: product, files: [] };
  mkdirSync(outDir, { recursive: true });
  for (const shot of shots) {
    const href = `${server.origin}/src/lab/capture?${query(shot.params)}`;
    await page.goto(href);
    const r = await page.eval(READ(href));
    /* a 2× canvas, something drawn, nothing in the corners */
    if (r.width !== 2 * r.cssWidth || r.height !== 2 * r.cssHeight) throw new Error(`${shot.file}: canvas ${r.width}×${r.height} is not 2× ${r.cssWidth}×${r.cssHeight}`);
    if (!r.opaque) throw new Error(`${shot.file}: blank canvas`);
    if (r.corners.some(Boolean)) throw new Error(`${shot.file}: corners are not transparent`);
    const png = Buffer.from(r.png.slice(r.png.indexOf(',') + 1), 'base64');
    const path = outDir + shot.file;
    if (check) {
      if (!existsSync(path)) failures.push(`${shot.file}: missing`);
      else {
        const old = readFileSync(path);
        if (!old.equals(png)) {
          const d = await page.eval(DIFF(`data:image/png;base64,${old.toString('base64')}`));
          if (d.differing) failures.push(`${shot.file}: ${d.differing < 0 ? `size ${d.size.join('×')} differs` : `${d.differing} pixels differ`}`);
          else console.log(`${shot.file}: pixel-identical (bytes differ)`);
        }
      }
    } else writeFileSync(path, png);
    const { state, expression = null, size, color = null, eyeColor = null, floorShadow = true } = shot.params;
    manifest.files.push({
      file: shot.file,
      params: { state, expression, size, color, eyeColor, floorShadow, paused: true, interactive: false },
      canvas: { width: r.width, height: r.height },
      css: { width: r.cssWidth, height: r.cssHeight },
      frame: r.frame,
      sha256: createHash('sha256').update(png).digest('hex'),
    });
    console.log(`${shot.file}  ${r.width}×${r.height}`);
  }
  const json = JSON.stringify(manifest, null, 2) + '\n';
  if (!check) writeFileSync(outDir + 'manifest.json', json);
  else if (!existsSync(outDir + 'manifest.json') || readFileSync(outDir + 'manifest.json', 'utf8') !== json) failures.push('manifest.json: differs');
  console.log(`${check ? 'checked' : 'wrote'} ${shots.length} references in ${outDir}`);
} finally {
  await browser.close();
  server.stop();
}
if (failures.length) {
  console.error(failures.join('\n'));
  process.exit(1);
}
