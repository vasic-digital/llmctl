// node matrix adapter using the core `node:https` / `node:http` modules. See README.md.
import https from 'node:https';
import http from 'node:http';
import fs from 'node:fs';

const [method, url, cacert, tmo, bodyf, hdrf] = process.argv.slice(2);
const body = bodyf === '-' ? null : fs.readFileSync(bodyf);
const headers = {};
if (hdrf !== '-') {
  for (const line of fs.readFileSync(hdrf, 'utf8').split('\n')) {
    const i = line.indexOf(':');
    if (i > 0) headers[line.slice(0, i).trim()] = line.slice(i + 1).trim();
  }
}
if (body !== null) headers['Content-Length'] = String(body.length);
const u = new URL(url);
const mod = u.protocol === 'https:' ? https : http;
const opts = { method, headers, timeout: Number(tmo) * 1000, hostname: u.hostname, port: u.port, path: u.pathname + u.search };
if (u.protocol === 'https:' && cacert !== '-') opts.ca = fs.readFileSync(cacert);
let done = false;
const finish = (lines) => { if (!done) { done = true; console.log(lines.join('\n')); process.exit(0); } };
const req = mod.request(opts, (res) => {
  const chunks = [];
  res.on('data', (c) => chunks.push(c));
  res.on('end', () => {
    const out = ['STATUS ' + res.statusCode];
    for (let i = 0; i < res.rawHeaders.length; i += 2) out.push('HEADER ' + res.rawHeaders[i].toLowerCase() + ': ' + res.rawHeaders[i + 1]);
    out.push('BODY_B64 ' + Buffer.concat(chunks).toString('base64'));
    finish(out);
  });
  res.on('error', (e) => finish(['ERROR ' + e.code + ': ' + String(e.message).replace(/\n/g, ' ')]));
});
req.on('timeout', () => { req.destroy(new Error('timeout')); });
req.on('error', (e) => finish(['ERROR ' + (e.code || e.name) + ': ' + String(e.message).replace(/\n/g, ' ')]));
if (body !== null) req.write(body);
req.end();
