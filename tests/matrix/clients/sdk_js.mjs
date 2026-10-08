// @typesafe-ai/sdk matrix adapter. Run with NODE_PATH-free resolution: the runner installs the
// SDK into a private npm prefix and sets MATRIX_SDK_JS_DIR to it. Applicable only to the SDK's
// own surface: POST /v1/systemone and GET /v1/models. See README.md.
//
// CA-trust mechanisms tried in order, each reported on a TRUST line:
//   1. env-NODE_EXTRA_CA_CERTS   child process started with NODE_EXTRA_CA_CERTS=<ca>
//   2. custom-fetch              the documented hook: new TypeSafeClient({ fetch }) using node:https + ca
import fs from 'node:fs';
import https from 'node:https';
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import path from 'node:path';

const chainOf = (e) => { const o = []; for (let x = e, i = 0; x && i < 8; x = x.cause, i++) { if (x.message) o.push(x.message); if (x.code) o.push(x.code); } return o.join(' | '); };
const argv = process.argv.slice(2);
const attempt = process.env.MATRIX_SDK_ATTEMPT || '';
const [method, url, cacert, tmo, bodyf, hdrf] = argv;
const dir = process.env.MATRIX_SDK_JS_DIR;

if (!attempt) {
  const t = [];
  if (new URL(url).protocol === 'https:') {
    const env0 = { ...process.env, MATRIX_SDK_ATTEMPT: 'env', MATRIX_SDK_CONTROL: '1' }; delete env0.NODE_EXTRA_CA_CERTS;
    const c = spawnSync(process.execPath, [new URL(import.meta.url).pathname, ...argv], { env: env0, encoding: 'utf8' });
    const cl = (c.stdout || '').trim();
    t.push('TRUST control-no-ca ' + (cl.includes('refused-as-expected') ? 'refused-as-expected' : 'UNEXPECTED-OK: ' + cl.slice(0, 150)));
  }
  let last = '';
  for (const mech of ['env', 'fetch']) {
    const env = { ...process.env, MATRIX_SDK_ATTEMPT: mech };
    if (mech === 'env') env.NODE_EXTRA_CA_CERTS = cacert; else delete env.NODE_EXTRA_CA_CERTS;
    const r = spawnSync(process.execPath, [new URL(import.meta.url).pathname, ...argv], { env, encoding: 'utf8' });
    const outl = (r.stdout || '').trim().split('\n');
    if (outl.some((l) => l.startsWith('TLSFAIL'))) {
      last = outl.find((l) => l.startsWith('TLSFAIL')).slice(8);
      t.push('TRUST ' + (mech === 'env' ? 'env-NODE_EXTRA_CA_CERTS' : 'custom-fetch') + ' fail: ' + last);
      continue;
    }
    t.push('TRUST ' + (mech === 'env' ? 'env-NODE_EXTRA_CA_CERTS' : 'custom-fetch') + ' ok');
    console.log([...t, ...outl].join('\n'));
    process.exit(0);
  }
  console.log([...t, 'TRUST none fail: ' + last, 'ERROR trust-configuration failure: no CA-trust mechanism worked'].join('\n'));
  process.exit(0);
}

const req = createRequire(path.join(dir, 'x.js'));
const sdkPath = req.resolve('@typesafe-ai/sdk');
const sdk = await import(sdkPath.endsWith('.cjs') ? sdkPath.replace('.cjs', '.mjs') : sdkPath);
const headers = {};
if (hdrf !== '-') for (const l of fs.readFileSync(hdrf, 'utf8').split('\n')) { const i = l.indexOf(':'); if (i > 0) headers[l.slice(0, i).trim().toLowerCase()] = l.slice(i + 1).trim(); }
let key = headers['authorization'] || '';
key = key.toLowerCase().startsWith('bearer ') ? key.slice(7) : (headers['x-api-key'] || '');
const body = bodyf === '-' ? null : JSON.parse(fs.readFileSync(bodyf, 'utf8'));
const u = new URL(url);

const httpsFetch = (input, init = {}) => new Promise((resolve, reject) => {
  const x = new URL(input);
  const h = {}; new Headers(init.headers || {}).forEach((v, k) => { h[k] = v; });
  const r = https.request({ hostname: x.hostname, port: x.port, path: x.pathname + x.search, method: init.method || 'GET', headers: h, ca: fs.readFileSync(cacert) }, (res) => {
    const ch = []; res.on('data', (c) => ch.push(c));
    res.on('end', () => {
      const rh = new Headers(); for (let i = 0; i < res.rawHeaders.length; i += 2) rh.append(res.rawHeaders[i], res.rawHeaders[i + 1]);
      resolve(new Response([204, 304].includes(res.statusCode) ? null : Buffer.concat(ch), { status: res.statusCode, headers: rh }));
    });
  });
  r.on('error', reject);
  if (init.signal) init.signal.addEventListener('abort', () => r.destroy(new Error('aborted')));
  if (init.body) r.write(init.body);
  r.end();
});

const extra = {};
for (const [k, v] of Object.entries(headers)) if (!['authorization', 'x-api-key', 'content-type', 'content-length'].includes(k)) extra[k] = v;
const ropts = Object.keys(extra).length ? { headers: extra } : undefined;
if (attempt === 'env' && u.protocol === 'https:' && process.env.MATRIX_SDK_CONTROL === '1') {
  // CONTROL (child started WITHOUT NODE_EXTRA_CA_CERTS): the private certificate must be refused
  try { await new sdk.TypeSafeClient({ apiKey: key, baseURL: u.protocol + '//' + u.host, timeout: 5000, retry: { maxRetries: 0 } }).models.list(); console.log('CONTROL UNEXPECTED-OK'); }
  catch (e) { const chain = chainOf(e);
    console.log(/CERT|certificate|self.signed|SSL|TLS/i.test(chain) ? 'CONTROL refused-as-expected' : 'CONTROL UNEXPECTED-OK: ' + chain.slice(0, 120)); }
  process.exit(0);
}
const cfg = { apiKey: key, baseURL: u.protocol + '//' + u.host, timeout: Number(tmo) * 1000, retry: { maxRetries: 0 } };
if (attempt === 'fetch' && u.protocol === 'https:') cfg.fetch = httpsFetch;
const client = new sdk.TypeSafeClient(cfg);
const out = (status, hdrs, payload) => {
  const l = ['STATUS ' + status];
  for (const [k, v] of Object.entries(hdrs || {})) l.push('HEADER ' + k.toLowerCase() + ': ' + v);
  l.push('BODY_B64 ' + Buffer.from(typeof payload === 'string' ? payload : JSON.stringify(payload)).toString('base64'));
  console.log(l.join('\n'));
};
try {
  if (method === 'POST' && u.pathname === '/v1/systemone') {
    const r = await client.systemOne({ state: body.state, questions: body.questions, ...(body.model ? { model: body.model } : {}) }, ropts);
    out(200, {}, r);
  } else if (method === 'GET' && u.pathname === '/v1/models') {
    out(200, {}, { models: await client.models.list(ropts) }); // the SDK's own listing: {models:[{name,description,release_date}]}
  } else {
    console.log('ERROR outside the SDK surface');
  }
} catch (e) {
  if (typeof e.status === 'number') {
    const hd = {}; if (e.headers && e.headers.forEach) e.headers.forEach((v, k) => { hd[k] = v; });
    out(e.status, hd, e.body === undefined ? {} : e.body);
  } else {
    const chain = chainOf(e);
    if (/CERT|certificate|self.signed|SSL|TLS/i.test(chain)) console.log('TLSFAIL ' + chain.replace(/\n/g, ' ').slice(0, 300));
    else console.log('ERROR ' + chain.replace(/\n/g, ' ').slice(0, 400));
  }
}
