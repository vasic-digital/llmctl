// headless-chromium matrix adapter driven over the DevTools protocol (node >= 22 global WebSocket).
// Trust: the CLI cannot import a CA into the NSS store without certutil, so the server
// certificate is trusted by SPKI pin (--ignore-certificate-errors-spki-list); this is
// reported on the TRUST line. GET-only by design (FR-069 browser class). See README.md.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';

const [method, url, cacert, tmo, bodyf, hdrf] = process.argv.slice(2);
const spki = process.env.MATRIX_CHROMIUM_SPKI || '';
const bin = process.env.MATRIX_CHROMIUM_BIN || 'chromium';
if (method !== 'GET') { console.log('ERROR browser adapter issues GET navigations only'); process.exit(2); }
const headers = {};
if (hdrf !== '-') for (const l of fs.readFileSync(hdrf, 'utf8').split('\n')) { const i = l.indexOf(':'); if (i > 0) headers[l.slice(0, i).trim()] = l.slice(i + 1).trim(); }

const freePort = () => new Promise((res) => { const s = net.createServer(); s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => res(p)); }); });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const port = await freePort();
const args = ['--headless=new', '--no-sandbox', '--disable-gpu', '--disable-extensions', '--no-first-run', '--disable-background-networking',
  `--remote-debugging-port=${port}`, 'about:blank'];
if (spki) args.unshift(`--ignore-certificate-errors-spki-list=${spki}`);
const proc = spawn(bin, args, { stdio: 'ignore' });
let out = null;
const bail = (lines) => { out = lines; };
try {
  let ver = null;
  for (let i = 0; i < 100 && !ver; i++) {
    try { ver = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json(); } catch { await sleep(100); }
  }
  if (!ver) throw new Error('chromium did not expose the DevTools endpoint');
  const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  const page = targets.find((t) => t.type === 'page');
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((r, j) => { ws.onopen = r; ws.onerror = () => j(new Error('ws error')); });
  let id = 0; const pend = new Map(); const events = [];
  ws.onmessage = (m) => { const d = JSON.parse(m.data); if (d.id && pend.has(d.id)) { pend.get(d.id)(d); pend.delete(d.id); } else events.push(d); };
  const call = (method, params = {}) => new Promise((r) => { const i = ++id; pend.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
  await call('Network.enable'); await call('Page.enable');
  if (Object.keys(headers).length) await call('Network.setExtraHTTPHeaders', { headers });
  const nav = await call('Page.navigate', { url });
  const deadline = Date.now() + Number(tmo) * 1000;
  let doc = null, failed = null, finished = false;
  while (Date.now() < deadline && !finished) {
    for (const e of events.splice(0)) {
      if (e.method === 'Network.responseReceived' && e.params.type === 'Document' && !doc) doc = e.params;
      if (e.method === 'Network.loadingFailed' && e.params.type === 'Document') { failed = e.params.errorText; finished = true; }
      if (e.method === 'Network.loadingFinished' && doc && e.params.requestId === doc.requestId) finished = true;
    }
    if (!finished) await sleep(50);
  }
  if (nav.result && nav.result.errorText && !doc) failed = nav.result.errorText;
  if (!doc) bail(['ERROR ' + (failed || 'no document response (timeout)')]);
  else {
    const lines = ['STATUS ' + doc.response.status];
    for (const [k, v] of Object.entries(doc.response.headers)) for (const part of String(v).split('\n')) lines.push('HEADER ' + k.toLowerCase() + ': ' + part);
    const b = await call('Network.getResponseBody', { requestId: doc.requestId });
    const r = b.result || {};
    lines.push('BODY_B64 ' + (r.base64Encoded ? r.body : Buffer.from(r.body || '', 'utf8').toString('base64')));
    lines.push('TRUST ' + (spki ? 'spki-pin ok' : 'platform-default ok'));
    bail(lines);
  }
  try { await call('Browser.close'); } catch {}
} catch (e) {
  bail(['ERROR ' + String(e.message).replace(/\n/g, ' ')]);
} finally {
  console.log(out.join('\n'));
  setTimeout(() => { try { proc.kill('SIGKILL'); } catch {} process.exit(0); }, 300);
}
