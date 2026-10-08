# Web / security research: HTTPS-only decision endpoints, access key, LAN + internet exposure

| Field | Value |
|---|---|
| Date | 2026-10-07 |
| Feature | 009-jev-decision-models (FR-018..020, FR-057..073, SC-005, SC-013) |
| Host used for local verification | Ubuntu 26.04, Linux 7.0, OpenSSL 3.5.5, Python 3.14.4, Node 26.8.1, Go 1.26.0, curl 8.18.0, OpenJDK 25, Chromium (snap), systemd 259, rootless podman 1.42 (pasta + slirp4netns) |
| Not available locally | macOS (LibreSSL, launchd, zsh defaults), a second physical machine, a router, a public IP |
| Method | ~45 web searches/fetches + ~60 local read-only experiments in `/tmp/claude-1000/.../scratchpad` (throwaway CA, throwaway keys, loopback-only listeners; nothing non-loopback was bound) |
| Legend | **VERIFIED-LOCALLY** = I ran it here and saw the stated result. **UNVERIFIED** = from documentation/search only. **INFERRED** = my reasoning, not observed. |

No credential of any kind appears in this file; all keys below were random throwaway values generated in the scratch directory.

---

## 0. Decisions at a glance

| # | Topic | Decision |
|---|---|---|
| D1 | Certificate architecture | **Two-tier: a per-host local CA (EC P-256, 10 y, `pathlen:0`) + a server leaf (EC P-256, 397 d).** Clients trust the CA once; leaf renewal and address drift never break them. Single self-signed leaf is kept as a documented fallback mode (`LLMCTL_TLS_MODE=selfsigned`) and BYO cert (FR-067) bypasses the CA entirely. |
| D2 | Key type | EC P-256 (ECDSA). Works with curl, Python (strict), Node, Go, Java, Chromium, openssl (all VERIFIED). RSA-2048 is a documented override only. |
| D3 | Tooling for generation | `openssl` CLI with **config/extfile files, not `-addext`**, and `ecparam -genkey -noout` (portable to OpenSSL 3 and LibreSSL). No pip packages. |
| D4 | TLS server pattern | `ThreadingHTTPServer` on a **plain** listening socket; wrap each accepted socket **inside the handler thread** with a bounded handshake timeout; bounded connection slots; absolute per-connection deadline. **Do not** wrap the listening socket and **do not** use Python 3.14's `ThreadingHTTPSServer` (both VERIFIED to stall the accept loop on one idle TCP connection). |
| D5 | Protocol floor | TLS 1.2 minimum (documented, FR-070), TLS 1.3 preferred, ALPN `http/1.1`, tickets off. Optional `LLMCTL_TLS_MIN=1.3`. |
| D6 | Auth header | `Authorization: Bearer <key>` primary; accept `X-API-Key` as a secondary alias; never accept the key in a query string. `hmac.compare_digest` on **bytes**. |
| D7 | Key generation | `secrets.token_urlsafe(32)` (43 chars, 256 bits). Atomic first-start creation with `O_EXCL` + `flock`. |
| D8 | Shell rc export | Write a **reference line** that reads the key from `.env` (no secret copied into a world-readable rc) by default; offer `--inline` for the literal value with the FR-059 warning. |
| D9 | Service hardening | Use non-namespace directives (verified effective in a user manager: `NoNewPrivileges`, `RestrictAddressFamilies`, `UMask`, `MemoryMax`, `LoadCredential`). **Filesystem-sandbox directives (`ProtectSystem`, `ProtectHome`, `InaccessiblePaths`) were accepted but NOT enforced in the user manager on this host** - treat as best-effort and runtime-probe, never claim. |
| D10 | Internet reachability | Document, in order of preference: Tailscale/WireGuard (private overlay) > port-forward + DDNS + firewall (direct, self-signed CA works end to end) > TCP/TLS-passthrough tunnels. HTTP-terminating tunnels (Cloudflare proxy, ngrok HTTPS endpoint) re-terminate TLS and are **not** end-to-end for the self-signed cert. |
| D11 | What can be proven from outside | A rootless `slirp4netns` container on this host is a usable *distinct-address* vantage with a positive control; `pasta` is NOT (VERIFIED, see 5.3). Real internet reachability and router/CGNAT behaviour cannot be proven without a machine outside the LAN. |

---

## 1. Certificate generation

### 1.1 openssl portability (OpenSSL 3.x vs macOS LibreSSL)

| Feature | OpenSSL 3.x (this host: 3.5.5) | macOS system `/usr/bin/openssl` (LibreSSL) |
|---|---|---|
| `req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -noenc` | VERIFIED-LOCALLY | UNVERIFIED. `-noenc` is OpenSSL 3.0+ only; LibreSSL knows `-nodes`. |
| `-nodes` | VERIFIED-LOCALLY (accepted, deprecated alias of `-noenc`) | works (INFERRED) |
| `req -addext "subjectAltName=..."` | VERIFIED-LOCALLY | Added in **LibreSSL 3.1.0** (release notes, UNVERIFIED on a Mac). Stock macOS reports LibreSSL **3.3.6** per multiple sources (INFERRED: `-addext` works), but old reports (2.9.2) say it does not. Do not depend on it. |
| `ecparam -name prime256v1 -genkey -noout -out k.pem` | VERIFIED-LOCALLY | standard in both (INFERRED) |
| `x509 -req -extfile ext.cnf -CA ca.crt -CAkey ca.key -set_serial 0x...` | VERIFIED-LOCALLY | standard (INFERRED) |
| `x509 -checkend`, `-checkhost`, `-checkip`, `-ext` | VERIFIED-LOCALLY | `-ext` and `-checkip` are OpenSSL 1.1.1+; **UNVERIFIED/likely missing in LibreSSL** - use Python (`ssl._ssl._test_decode_cert` is private; prefer `openssl x509 -text` parsing or `-noout -dates`) for macOS diagnostics |

**Decision:** drive every call with files (`-config`, `-extfile`), use `ecparam -genkey -noout` for keys, and `-set_serial 0x$(openssl rand -hex 16)` for serials. On macOS, `llmctl cert doctor` must feature-detect (`openssl version`, try `-checkend`) and fall back to `brew --prefix openssl@3` if present. The Python `ssl` module cannot create certificates (no stdlib x509 writer), so `openssl` is the only no-pip route.

### 1.2 Single self-signed vs CA + leaf: recommendation = CA + leaf

| Criterion | Single self-signed leaf | CA + leaf (recommended) |
|---|---|---|
| Clients trust once | No: every renewal / SAN change = new fingerprint to re-trust everywhere | **Yes**: trust `ca.crt` once |
| Address drift (DHCP, new interface, new DDNS name) | Must re-issue and every client re-imports | Re-issue **leaf only**; CA-trusting clients unaffected (VERIFIED, below) |
| Strict clients (Python 3.13+ `VERIFY_X509_STRICT`) | Works (VERIFIED: self-signed with SAN accepted as trust anchor) | Works (VERIFIED; CA needs `basicConstraints=CA:TRUE` + `keyUsage=keyCertSign`) |
| Pinning | Pin cert or SPKI | Pin CA (stable) or leaf SPKI (breaks on rotation unless leaf key reused) |
| Blast radius if the key leaks | One host's server identity | The CA key can mint certs for any name **for clients that trusted it** |
| Complexity | One file pair | CA dir + leaf dir + rotation logic |

Mitigations for the CA blast radius (all VERIFIED-LOCALLY): `basicConstraints=critical,CA:TRUE,pathlen:0`; CA key `0600` in a separate `ca/` dir; **optional `nameConstraints`** - I generated a CA permitting only `DNS:localhost`, `DNS:lan`, `IP:127.0.0.0/8`, `IP:192.168.0.0/16`, `IP:10.0.0.0/8`, `IP:::1` and verified: a leaf inside the constraints validates in `openssl verify`, curl, Python (strict) and Node (`fetch` returned 401 = TLS fine), while a leaf with `DNS:evil.example.com` fails with `permitted subtree violation` in all four. Caveats: constraints must include every operator extra name / public DDNS name / public IP / `172.16/12` etc., or issuance of the leaf will not validate - therefore **off by default, offered as `LLMCTL_CA_NAME_CONSTRAINTS=auto`** (permitted = RFC1918 + loopback + the operator's extra names). Client enforcement differences exist for old LibreSSL/OpenSSL (an old report shows `unsupported name constraint type` for IP SANs) - UNVERIFIED on macOS.

Verified rotation behaviour (VERIFIED-LOCALLY): after re-issuing a new leaf from the same CA with a different SAN set, `curl --cacert ca.crt` kept working; a client pinned with `--pinnedpubkey` to the *old leaf* failed with `public key does not match pinned public key (90)`. Therefore document: **pin the CA, not the leaf**; if an operator pins the leaf SPKI, `cert renew` can optionally reuse the leaf key (`--reuse-key`).

Apple note (fetched): the 398-day cap applies only to certificates chained to *pre-installed* roots; "this change will not affect certificates issued from user-added or administrator-added Root CAs". Still issue leaves at **397 days** so the same files work on any platform policy; the CA at 3650 days.

### 1.3 SAN contents

Required SAN set (all as `subjectAltName`, CN is cosmetic):

1. `DNS:localhost`, `IP:127.0.0.1`, `IP:::1`
2. `DNS:<short hostname>` and `DNS:<FQDN>` if different (`socket.gethostname()`, `socket.getfqdn()` - VERIFIED to work, both returned the short name here)
3. `DNS:<host>.local` (mDNS) **only if** the platform advertises it (Avahi on Linux resolves `<hostname>.local` by default; Bonjour on macOS) - this is a decision, not auto-detectable portably; include by default (harmless) and document
4. Every **global/private non-link-local** interface address (IPv4 and IPv6). Exclude `fe80::/10` (needs a zone id; clients never match it by name).
5. Operator extras: `LLMCTL_TLS_SAN="dns:nas.example.org,ip:203.0.113.7"` (needed for the internet name / DDNS name / public IP - llmctl must **not** discover the public IP by calling a third party).

Stdlib-only interface enumeration (VERIFIED-LOCALLY): `ip -o addr show scope global` (Linux; `hostname -I` also), plus the UDP-connect trick for the primary IPv4 (`socket.socket(AF_INET, SOCK_DGRAM).connect(("192.0.2.1", 9)); s.getsockname()[0]` returned `192.168.1.115`; sends no packet). `socket.if_nameindex()` lists names only. macOS: `ifconfig -a | awk '/inet /{print $2}'` / `ipconfig getifaddr en0` - UNVERIFIED. Put the enumeration behind one function that returns a sorted set and tolerates tool absence.

**Drift detection:** store the issued SAN set as sorted text in `cert/leaf.san`. At start and in `llmctl cert doctor`, recompute the *desired* set; if desired is not a subset of issued, WARN with the exact new names and the command `llmctl cert renew` (FR-066: never silent regeneration). Expiry warning: `openssl x509 -checkend $((30*86400))` returns non-zero if it expires within 30 d (VERIFIED-LOCALLY). Also check key/cert match (below).

### 1.4 Exact commands (all VERIFIED-LOCALLY on OpenSSL 3.5.5 unless marked)

```bash
umask 077
# --- CA (once) ---
openssl ecparam -name prime256v1 -genkey -noout -out ca.key
cat > ca.cnf <<'E'
[req]
distinguished_name=dn
prompt=no
x509_extensions=v3_ca
[dn]
CN=llmctl local CA (HOSTNAME)
[v3_ca]
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
E
openssl req -x509 -new -key ca.key -sha256 -days 3650 -config ca.cnf \
  -set_serial 0x$(openssl rand -hex 16) -out ca.crt

# --- leaf (every renewal) ---
openssl ecparam -name prime256v1 -genkey -noout -out leaf.key
openssl req -new -key leaf.key -subj /CN=llmctl -out leaf.csr
cat > leaf.ext <<'E'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost,DNS:HOSTNAME,IP:127.0.0.1,IP:::1,IP:192.168.1.115
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid
E
openssl x509 -req -in leaf.csr -CA ca.crt -CAkey ca.key -sha256 -days 397 \
  -extfile leaf.ext -set_serial 0x$(openssl rand -hex 16) -out leaf.crt
openssl verify -CAfile ca.crt leaf.crt                # leaf.crt: OK
```

Notes: `keyUsage` for an ECDSA server leaf is `digitalSignature` only (no `keyEncipherment`, which is RSA-key-transport only); `extendedKeyUsage=serverAuth` is required by browsers/Java; a CSR round trip is used instead of `req -x509` so the leaf is not self-signed. A random 128-bit serial encodes as a positive ASN.1 INTEGER (openssl accepted it, no negative-serial error).

One-step fallback mode, single self-signed (VERIFIED-LOCALLY; also accepted as a strict-Python trust anchor and by curl):

```bash
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -noenc -keyout ss.key -out ss.crt \
  -days 365 -subj /CN=llmctl -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" -addext "extendedKeyUsage=serverAuth"
```

Fingerprints and pins (VERIFIED-LOCALLY):

```bash
openssl x509 -in ca.crt -noout -fingerprint -sha256      # SHA256 Fingerprint=35:A0:...  (display this)
openssl x509 -in leaf.crt -pubkey -noout | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary | base64                # SPKI pin for curl --pinnedpubkey / Chromium
openssl x509 -in leaf.crt -noout -checkend $((30*86400)) # rc!=0 if it expires within 30 days
openssl x509 -in leaf.crt -noout -checkhost localhost    # "does match"
openssl x509 -in leaf.crt -noout -checkip 192.0.2.10     # "does NOT match" (drift check helper)
# cert/key match test (identical digests => match)
openssl x509 -in leaf.crt -noout -pubkey | openssl dgst -sha256
openssl pkey -in leaf.key -pubout       | openssl dgst -sha256
```

Python load-time validation for FR-067 (VERIFIED-LOCALLY): `ssl.SSLContext(PROTOCOL_TLS_SERVER).load_cert_chain(cert, key)` raises `SSLError [X509: KEY_VALUES_MISMATCH] key values mismatch` for a mismatched pair; an expired cert is *not* detected by `load_cert_chain` - check `-checkend 0` / parse `notAfter` yourself (VERIFIED: server started with an expired cert and curl reported `certificate has expired (10)`).

### 1.5 File layout, permissions, atomicity, concurrency

```
$HOME/llmctl/cert/                 0700
  ca/ca.key                        0600   (only present in CA mode)
  ca/ca.crt                        0644   (public; safe to copy to clients)
  current -> v-<epoch-ms>/         symlink, atomically swapped
  v-<epoch-ms>/leaf.key 0600, leaf.crt 0644 (chain = leaf only; clients get CA separately), leaf.san 0644, meta.json
  .lock                            0600   flock target
```
Gotcha (VERIFIED-LOCALLY): files created `0600` are **unreadable inside a rootless container** that runs as a different mapped uid (`curl: (77) error setting certificate file`); copy the public CA to a `0644` file for container/test use (`ca.crt` is public anyway).

Race safety, tested with 5 simultaneous starters (VERIFIED-LOCALLY): `fcntl.flock(LOCK_EX)` on `cert/.lock`; the winner generates into a `0700` temp dir (`.gen-XXXX`), `rename()`s it to `v-<ts>`, then publishes by creating a temp symlink and `os.replace(tmp, "current")` (atomic). Exactly one generated; four logged `reuse`. Pair-consistency: readers always resolve `current/` so key and cert come from the same generation. `flock(1)` exists on Linux but **not on stock macOS** - use Python `fcntl.flock` (works on both) or `mkdir`-lock in bash. Gateway + runtimes should all call the same `llmctl cert ensure` before binding.

### 1.6 Validity period (documented, FR-066)

CA 3650 d, leaf 397 d, warn at 30 d, error (refuse to start) at expiry with the exact command. 397 matches the strictest platform policy (Apple, publicly-trusted chains) even though user-added roots are exempt. Short-lived (days) leaves are **not** recommended: renewal is an explicit operator action (FR-066), so a long leaf avoids unattended outages (INFERRED design reasoning).

---

## 2. Python stdlib TLS server pattern

### 2.1 Findings (all VERIFIED-LOCALLY unless marked)

1. **The common recipe is unsafe.** `httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)` performs the TLS handshake inside `accept()` on the serving thread. With one idle TCP connection open, a legitimate TLS request timed out (`http=000`, 6.0 s) on both a plain `HTTPServer` and on Python 3.14's new **`http.server.ThreadingHTTPSServer`** (its `server_activate` wraps the listening socket - source inspected). `ThreadingHTTPServer` does *not* help because the blocking part is in `accept`, before threading.
2. **Correct pattern:** keep the listening socket plain; in the handler's `setup()` set a socket timeout and `wrap_socket(self.request, server_side=True)`. Python 3.5+ semantics: the socket timeout is the **total** handshake time (docs). Verified: 3 idle TCP connections did not delay a real request (0.044 s), and an idle connection was closed at exactly 5.0 s (3.0 s in the hardened variant).
3. **Connection cap:** a `BoundedSemaphore` acquired non-blocking in `process_request` and released in `shutdown_request`; the 5th connection with 4 slots busy was shed immediately (`SSLEOFError` at 0.00 s); slots freed after the handshake timeout and a real request succeeded.
4. **Slow-drip after the handshake:** `Handler.timeout` is a *per-recv* timeout; a client sending 1 byte/second never trips it. A `threading.Timer` that calls `request.shutdown(SHUT_RDWR)` after an absolute deadline (10 s) cut the drip at 11.0 s (`BrokenPipeError`). Cancel the timer in `finish()`.
5. **Plain HTTP to the HTTPS port** gets a connection reset (`curl: (56) Recv failure`) - which is exactly what FR-066/FR-070 want (no plain-HTTP answer, no redirect; do not add one).
6. **Protocol checks:** `openssl s_client -tls1_1` -> `no protocols available`; `testssl.sh 3.2` (run in a rootless container against the loopback server) reported SSLv2/SSLv3/TLS1.0/TLS1.1 not offered, TLS1.2 and TLS1.3 offered, ALPN `http/1.1`, EC P-256 / ECDSA-SHA256, key usage Digital Signature, `Session Resumption: Tickets no, ID: yes`.
7. `ssl.SSLContext(PROTOCOL_TLS_SERVER).minimum_version` defaults to `MINIMUM_SUPPORTED` (-2); **set it explicitly**. `OP_NO_TICKET` disables TLS1.2 tickets; for TLS1.3 use `ctx.num_tickets = 0` (docs; UNVERIFIED locally). Default cipher list is OpenSSL's secure default (60 entries incl. TLS1.3 suites); no custom cipher string needed (Mozilla "intermediate" = TLS1.2+1.3 with ECDHE/AEAD - I could not fetch the page; INFERRED from memory).

### 2.2 Reference skeleton (the tested one, hardened)

```python
import ssl, socket, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

def make_context(cert, key, min_tls=ssl.TLSVersion.TLSv1_2):
    c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    c.minimum_version = min_tls
    c.load_cert_chain(cert, key)                 # raises on mismatch
    c.set_alpn_protocols(["http/1.1"])
    c.options |= ssl.OP_NO_TICKET
    return c

class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 128
    max_conns = 64
    def server_bind(self):
        super().server_bind()
        self._slots = threading.BoundedSemaphore(self.max_conns)
    def process_request(self, request, client_address):
        if not self._slots.acquire(blocking=False):      # shed load, do not spawn unbounded threads
            try: request.close()
            except OSError: pass
            return                                       # (no 'return' inside 'finally': SyntaxWarning)
        super().process_request(request, client_address)
    def shutdown_request(self, request):
        try: super().shutdown_request(request)
        finally: self._slots.release()
    def handle_error(self, request, client_address):
        pass                                             # handshake noise: count, never log bodies/keys

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    timeout = 5                                          # per-recv idle
    HANDSHAKE_TIMEOUT = 3
    DEADLINE = 10                                        # absolute per-connection cap (raise for long generations, see 2.3)
    def setup(self):
        self.request.settimeout(self.HANDSHAKE_TIMEOUT)  # total handshake budget
        self.request = self.server.ctx.wrap_socket(self.request, server_side=True)
        t = threading.Timer(self.DEADLINE, self._kill); t.daemon = True; t.start(); self._t = t
        super().setup()
    def _kill(self):
        try: self.request.shutdown(socket.SHUT_RDWR)
        except OSError: pass
    def finish(self):
        self._t.cancel()
        try: super().finish()
        except OSError: pass
```
Bind: `Server(("0.0.0.0", port), Handler)` for all IPv4; for dual-stack set `address_family = AF_INET6` and clear `IPV6_V6ONLY` in `server_bind` (UNVERIFIED - I did not bind a non-loopback address). `Server.ctx = make_context(...)` assigned before `serve_forever()`.

### 2.3 Caveats to carry into the plan

- A fixed absolute deadline conflicts with long LLM generations or streaming: make the deadline cover **request read** only (start the timer in `setup`, cancel it when headers+body are fully read, then rely on the per-send timeout), or make it configurable per endpoint. Decision endpoints are short, so a 10-30 s cap is fine; do not reuse the pattern unchanged for chat streaming.
- `http.server` is documented as "not recommended for production... only basic security checks" (Python docs). Residual risks: no HTTP/2, header-count/size limits are only the 64 KiB line limit, `Content-Length` must be enforced by the handler (reject > N bytes before reading; reject missing/negative length; require `Content-Type: application/json`).
- macOS system Python is 3.9-era (INFERRED; check `python3 -c "import ssl;print(ssl.OPENSSL_VERSION)"`), so the pattern avoids 3.14-only APIs. `ssl.TLSVersion`, `PROTOCOL_TLS_SERVER`, `set_alpn_protocols` exist since 3.6/3.7 (docs). Feature-detect `ssl.HAS_TLSv1_3`; on LibreSSL-linked Python TLS 1.3 may be absent -> the 1.2 floor is what makes it work.
- Process startup invariants (FR-018/066): refuse to start if key absent, cert invalid/expired/mismatched; print the bind address, cert fingerprint (SHA-256), CA fingerprint and expiry - never the key.
- Incidental finding (outside this feature): the existing `~/.config/systemd/user/llmctl-llama@.service` triggers `Unknown key 'StartLimitIntervalSec' in section [Service], ignoring` (VERIFIED-LOCALLY via `systemd-analyze verify`); `StartLimitIntervalSec` belongs in `[Unit]`. Hardening the units (section 5.5) should fix this in the same change.

---

## 3. Client trust matrix (exact commands)

CA file below = `$HOME/llmctl/cert/ca/ca.crt` (or the single self-signed cert in fallback mode). `llmctl cert show` should print the path and fingerprint; `llmctl cert export <dest>` should copy it `0644`.

| Client | Command / setting | Status |
|---|---|---|
| curl | `curl --cacert ca.crt -H "Authorization: Bearer $LLMCTL_API_KEY" https://host:port/...` | VERIFIED-LOCALLY |
| curl (env) | `CURL_CA_BUNDLE=ca.crt curl ...` | VERIFIED-LOCALLY (replaces the default bundle) |
| curl, pin without CA | `curl -k --pinnedpubkey "sha256//<SPKI-b64>" ...` (wrong pin -> `(90) public key does not match pinned public key`) | VERIFIED-LOCALLY |
| curl wrong name | name absent from SAN -> `(60) no alternative certificate subject name matches target hostname` | VERIFIED-LOCALLY (negative test) |
| openssl | `openssl s_client -connect h:p -CAfile ca.crt -verify_hostname h -alpn http/1.1 </dev/null` -> `Verification: OK` | VERIFIED-LOCALLY |
| Python urllib | `ssl.create_default_context(cafile="ca.crt")` or `SSL_CERT_FILE=ca.crt` | VERIFIED-LOCALLY (both) |
| Python requests | `verify="ca.crt"`, `REQUESTS_CA_BUNDLE=ca.crt` and `CURL_CA_BUNDLE=ca.crt` work; **`SSL_CERT_FILE` is ignored by requests** (certifi) -> `SSLError` | VERIFIED-LOCALLY |
| Python httpx | honours `SSL_CERT_FILE`/`SSL_CERT_DIR` when `verify=True`/trust_env (docs via search); not installed here | UNVERIFIED |
| Node (fetch/undici, https) | `NODE_EXTRA_CA_CERTS=ca.crt node app.js` (without it: `UNABLE_TO_VERIFY_LEAF_SIGNATURE`). Read **once at process start**; cannot be set later via `process.env`. | VERIFIED-LOCALLY |
| Node, system store | `NODE_USE_SYSTEM_CA=1` / `--use-system-ca` (it honoured `SSL_CERT_FILE=ca.crt` on Linux here) | VERIFIED-LOCALLY on Linux; macOS Keychain behaviour UNVERIFIED |
| Node last resort | `NODE_TLS_REJECT_UNAUTHORIZED=0` (works, prints a warning) | VERIFIED-LOCALLY - docs must show it only as a warned last resort (FR-068) |
| Go | `SSL_CERT_FILE=ca.crt ./prog` (replaces system roots), or `SSL_CERT_DIR=<dir with ca.crt>`; without -> `x509: certificate signed by unknown authority` | VERIFIED-LOCALLY. Programmatic: `x509.SystemCertPool()` + `AppendCertsFromPEM` (UNVERIFIED, standard API) |
| Java | default truststore fails (`PKIX path building failed`); works with `-Djavax.net.ssl.trustStore=ts.p12 -Djavax.net.ssl.trustStorePassword=...` after `keytool -importcert -noprompt -alias llmctl -file ca.crt -keystore ts.p12 -storetype PKCS12` | VERIFIED-LOCALLY |
| wget | `wget --ca-certificate=ca.crt --header=... https://...` | VERIFIED-LOCALLY |
| Chromium (automation/test only) | untrusted -> `net::ERR_CERT_AUTHORITY_INVALID`; `chromium-browser --headless=new --ignore-certificate-errors-spki-list=<leaf SPKI b64> ...` loads the page (this is the FR-069 "browser-driven client" recipe; it pins the *leaf*) | VERIFIED-LOCALLY |
| Browsers (interactive) | Chrome/Chromium Linux: `certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n llmctl -i ca.crt` (needs `libnss3-tools`; not installed here). Firefox: Settings > Certificates > Import (trust for websites) or `security.enterprise_roots.enabled` (Windows/macOS). Safari/Chrome on macOS: `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ca.crt` | UNVERIFIED (search results) |
| OS trust (Linux) | Debian/Ubuntu: copy to `/usr/local/share/ca-certificates/llmctl-ca.crt` + `sudo update-ca-certificates`; Fedora/RHEL: `/etc/pki/ca-trust/source/anchors/` + `sudo update-ca-trust` | UNVERIFIED (docs; needs root) |

Strict-verification note (VERIFIED-LOCALLY on Python 3.14): `create_default_context()` sets `VERIFY_X509_STRICT | VERIFY_X509_PARTIAL_CHAIN` (flags=557088); both the CA-issued leaf (CA has `CA:TRUE`, `keyCertSign`, SKI; leaf has AKI) and the plain self-signed cert were accepted. Keep `basicConstraints`/`keyUsage`/SKI/AKI in the templates above; they are what strict clients check.

### 3.1 The seven agents

| Agent | Runtime | How to give it the CA | Evidence |
|---|---|---|---|
| Claude Code | Node/native | `export NODE_EXTRA_CA_CERTS=/path/ca.crt` **in the shell before launching** (official doc). Default trust is bundled Mozilla + OS store (`CLAUDE_CODE_CERT_STORE=bundled,system`), so installing the CA into the OS store also works. Official doc says every env var can also live in `settings.json` `env`, and says background agents need it there (the supervisor does not inherit the shell); but a GitHub issue (v2.1.29, closed *not planned*) reports `NODE_EXTRA_CA_CERTS` in `settings.json` was ignored while the shell export worked. Verify with `claude --debug` -> log line `CA certs: Appended extra certificates from NODE_EXTRA_CA_CERTS (...)`. | official doc fetched; issue summary fetched; UNVERIFIED locally (agent not run against the server) |
| opencode | Bun | `NODE_EXTRA_CA_CERTS=/path/ca.crt` (official network doc: "works for both proxy connections and direct API access"); `NODE_OPTIONS=--use-system-ca`/`BUN_OPTIONS=--use-system-ca` for the OS store. A commit adds per-provider `tls.ca`, `tls.rejectUnauthorized` options (not in the public network page) | docs + commit via search; UNVERIFIED locally |
| pi | Node (INFERRED: pi-mono is TypeScript) | Upstream README gives no TLS guidance (404 on the deep page I tried). Use `NODE_EXTRA_CA_CERTS`; **must be tested in the matrix** | UNVERIFIED |
| crush | Go | README documents `base_url`/`extra_headers` but nothing about CA. Go's `net/http` honours `SSL_CERT_FILE`/`SSL_CERT_DIR` (VERIFIED with a Go test client), so `SSL_CERT_FILE=ca.crt crush` is the expected route (INFERRED for crush itself; its HTTP stack could use a custom pool) | UNVERIFIED for crush |
| aider | Python (litellm/httpx + some `requests`) | `SSL_CERT_FILE=ca.crt` (litellm docs: `SSL_CERT_FILE` or `ssl_verify`), plus `REQUESTS_CA_BUNDLE=ca.crt` for requests-based code paths (VERIFIED that requests ignores `SSL_CERT_FILE`). Aider has only `--[no-]verify-ssl` (`AIDER_VERIFY_SSL`), **no CA-bundle option** | docs fetched; UNVERIFIED locally |
| Continue | Node (VS Code / JetBrains extension) | Per model: `requestOptions: { caBundlePath: /path/ca.crt }` (array allowed; `verifySsl: false` last resort) per Continue's cert-troubleshooting text; or `NODE_EXTRA_CA_CERTS` in the IDE's launch environment | search result; UNVERIFIED locally |
| Cline | VS Code extension host (Node) | VS Code setting `http.systemCertificates` (default true) -> install the CA into the OS store; or launch VS Code from a shell with `NODE_EXTRA_CA_CERTS` set. GUI-launched VS Code on macOS does **not** read `.zshrc`; use `launchctl setenv NODE_EXTRA_CA_CERTS /path/ca.crt` then restart VS Code (INFERRED) | search results; UNVERIFIED |

**Tools that ignore a custom CA bundle (observed or documented):** Python `requests` ignores `SSL_CERT_FILE` (VERIFIED); Java ignores every env var (VERIFIED); Node ignores `process.env.NODE_EXTRA_CA_CERTS` set after start (docs); Claude Code reads `NODE_EXTRA_CA_CERTS` from `settings.json` unreliably (issue, closed not planned); aider has no CA option; GUI-launched macOS apps do not inherit shell rc variables. Release docs should therefore recommend **installing the CA in the OS store as the lowest-friction universal option** (works for Claude Code default store, Node `--use-system-ca`, Cline/VS Code, browsers, curl on most distros) and keep the per-env-var recipes as the non-root alternative.

---

## 4. Access key handling

1. **Generation:** `python3 -c 'import secrets;print(secrets.token_urlsafe(32))'` -> 43 characters = 256 bits (VERIFIED); bash fallback `openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n'` -> 43 characters (VERIFIED). Format regex for validation: `^[A-Za-z0-9_-]{43,}$`; accept operator-supplied keys of >= 32 chars from the same alphabet and reject anything else explicitly (FR-058 "malformed is an error").
2. **Compare:** `hmac.compare_digest(a_bytes, b_bytes)`; calling it with non-ASCII `str` raises `TypeError` (VERIFIED), so encode both sides to bytes first - an attacker-sent header must not turn into a 500 that leaks timing/paths. Reject missing/empty before comparing; compare against a fixed-length digest if lengths may differ (`hmac.compare_digest(sha256(a), sha256(b))`) to avoid leaking the stored length.
3. **Header convention:** RFC 6750 `Authorization: Bearer <token>`; most Jev/OpenAI-compatible clients use that. Accept `X-API-Key` as an alias; never read it from the query string (leaks into proxy/web-server logs - a real advisory in Dependency-Track logged `X-Api-Key` in clear; a litellm CVE masked only the first 5 chars). 401 responses carry `WWW-Authenticate: Bearer realm="llmctl"` and a generic body `{"error":"unauthorized"}`.
4. **`.env` write (first start):** `fd = os.open(path, O_WRONLY|O_CREAT|O_EXCL, 0o600)` -> exactly one creator wins; the second gets `FileExistsError` (VERIFIED; results mode `0o600`). To *update* an existing `.env`: write `.env.tmp.<pid>` created `0600`, `fsync`, `os.replace`. Hold the same `flock` as certificates so gateway + runtimes starting together generate one key. Tighten loose modes with `os.chmod(path, 0o600)` after reading the mode; refuse with a message if you cannot.
5. **Reading `.env` safely in bash** - never `source` it. VERIFIED failure: a file with UTF-8 BOM and CRLF makes `. ./t.env` fail (`$'\xef\xbb\xbfLLMCTL_API_KEY=...\r': command not found`) and leaves the variable empty. Safe reader (VERIFIED):
   ```bash
   while IFS= read -r l || [ -n "$l" ]; do
     l=${l%$'\r'}; l=${l#$'\xef\xbb\xbf'}
     case $l in LLMCTL_API_KEY=*) v=${l#LLMCTL_API_KEY=}; v=${v#\"}; v=${v%\"}; LLMCTL_API_KEY=$v;; esac
   done < "$HOME/llmctl/.env"
   ```
   The Python equivalent (decode `utf-8-sig`, `splitlines()`, regex `^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$`) was VERIFIED on the same file. Rule: **blank/whitespace-only value -> error, not "no key".** Do not `export` the variable in the shell that runs `llmctl` subcommands; pass it to child processes through the environment only where needed, and never as argv.
6. **Shell rc export (explicit operator command only, FR-059):** idempotent managed block, VERIFIED on a scratch file (second run printed `already present: no change`, count stayed 1, backup `*.llmctl.bak` created with `cp -p`):
   ```
   # >>> llmctl api key (managed by llmctl; remove with: llmctl key unexport) >>>
   export LLMCTL_API_KEY="$(sed -n 's/^LLMCTL_API_KEY=//p' "$HOME/llmctl/.env" | head -n1)"
   # <<< llmctl api key <<<
   ```
   The reference form keeps the secret out of the rc file (this host's `~/.bashrc` is mode 644, i.e. world-readable - VERIFIED, so a literal key there would be exposed); offer `--inline` for the literal value with the warning FR-059 demands. Which file: **Linux/bash** interactive non-login shells read `~/.bashrc`, login shells read `~/.profile`/`.bash_profile` (often sourcing `.bashrc`); **macOS/zsh** (default shell) reads `~/.zshenv` (all shells), `~/.zprofile` (login), `~/.zshrc` (interactive), `~/.zlogin`; `$ZDOTDIR` replaces `$HOME` for these if set (zsh manual; ZDOTDIR is unset here). The default `llmctl key export` target should be `${ZDOTDIR:-$HOME}/.zshrc` on zsh and `~/.bashrc` on bash, chosen from `$SHELL`, **always shown and confirmed**. Caveats to document: `.bashrc`/`.zshrc` are not read by systemd/launchd services, cron, or GUI-launched apps; `.zshenv` is read by everything including scripts (supply-chain/exposure risk) so avoid it.
7. **Keeping the key out of argv/ps/logs/core dumps/unit files:** env-var delivery to a process is visible in `/proc/<pid>/environ`, mode `0400` owner-only (VERIFIED), and never in `ps` argv (VERIFIED: `ps` showed `sleep 3` only) - but OWASP's secrets cheat sheet calls env vars "accessible to all processes and may be included in logs or system dumps; not recommended unless other methods are not possible". Preferred delivery per platform:
   - **Linux systemd user unit:** `LoadCredential=llmctl_api_key:%h/llmctl/.env.key` (or `SetCredential`) - VERIFIED in a transient user unit: `$CREDENTIALS_DIRECTORY=/run/user/1000/credentials/run-...service`, file mode `0400` owner-only, tmpfs. The server reads the file path from `$CREDENTIALS_DIRECTORY`. Fallback `EnvironmentFile=%h/llmctl/.env` (file must be `0600`; contents are not shown by `systemctl show`... but `Environment=` set via the unit **is** shown - VERIFIED `systemctl --user show -p Environment` prints it, so never put the key in `Environment=`).
   - **macOS launchd:** `EnvironmentVariables` in the plist is **not** a safe place (plist can be world-readable, values shown by `launchctl print`). Run a tiny wrapper (`ProgramArguments` = `/bin/sh -c 'exec llmctl serve ...'`) that reads `.env` itself with the safe reader above. Apple's launchd guidance requires agent plists to be owned by the user and not group/world-writable (mode 600/400).
   - Process hygiene: `prctl(PR_SET_DUMPABLE, 0)` / `resource.setrlimit(RLIMIT_CORE, (0, 0))` at start (stdlib `resource`; UNVERIFIED), `MemoryDenyWriteExecute` does not stop dumps.
8. **Rate limiting / brute force (stdlib, design - UNVERIFIED):** 256-bit random keys make online guessing infeasible; the point is cost control and log-flood control. Per-source-IP token bucket in a `dict` guarded by a lock: allow N failed auths per minute, then respond `429` with `Retry-After` and skip further work; global cap on concurrent handlers (section 2); evict entries by time. Behind a tunnel all clients share one source IP - rate limit on failures, not successes, and make limits configurable. Do not log the offending key or its prefix.
9. **Rotation:** `llmctl key rotate` generates the new key, writes `.env` atomically, prints a notice that every client and the shell rc must be updated; optional `--grace N` accepts old+new for N minutes (keep a second line `LLMCTL_API_KEY_PREVIOUS` with expiry, off by default). A rotation never happens implicitly (FR-058).
10. **Log redaction / leak scan (SC-005):** never log `Authorization`/`X-API-Key`; log only method, path (no query), status, latency, request-id, client IP. Redaction filter: replace any 43+-char `[A-Za-z0-9_-]` token adjacent to `Bearer ` or `LLMCTL_API_KEY=`. Evidence scan: run the **actual key value** (read at test time, never printed) as a fixed-string search (`grep -rFl -- "$KEY" evidence/ logs/ docs/`) plus `/proc/*/cmdline` and `/proc/*/environ` of *other* uids, and file-mode check; each scan must include a control needle (plant a decoy key in a scratch file and require the scan to find it) so a blind scan cannot pass.

---

## 5. Internet ("cloud") reachability

### 5.1 Options and how each interacts with the cert

| Option | Exposure | TLS path | Self-signed CA works? | Notes |
|---|---|---|---|---|
| Port-forward + DDNS + host firewall | Direct, public | end-to-end to llmctl | **Yes** (add DDNS name/public IP to `LLMCTL_TLS_SAN`; clients import CA) | Needs a public IPv4 (not CGNAT) or global IPv6. Anyone can reach the port: the key + rate limit are the only gate. Scanners will find it within hours (INFERRED). |
| IPv6 global address | Direct if firewall allows | end-to-end | Yes (global address in SAN) | Many routers' IPv6 firewalls block inbound by default; open a rule for the one port. No NAT: there is no "hidden" behind-NAT protection. |
| UPnP/NAT-PMP auto-mapping | Silent public exposure | end-to-end | Yes | **Do not implement or recommend.** UPnP IGD has no authentication, any LAN device can open ports, many routers hide mappings (sources: HKCERT, Avast, atibox). llmctl must never open router ports itself. |
| Tailscale / WireGuard (private overlay) | Only tailnet/VPN peers | WireGuard-encrypted *and* llmctl TLS | **Yes**; Tailscale-issued `*.ts.net` certs (`tailscale cert host.tailnet.ts.net`, Let's Encrypt, 90 d, you renew) are a public-CA option; machine names go into CT logs (Tailscale warns) | Best default recommendation: no inbound port. Bind llmctl to all interfaces; the VPN interface is just another interface (add its IP/name to SAN). |
| Cloudflare Tunnel (`cloudflared`) | Public hostname via Cloudflare edge | **HTTP-terminating**: users see Cloudflare's edge cert; `cloudflared` -> origin is a separate TLS leg: `originRequest: { originServerName: <name in SAN>, caPool: /path/ca.crt }` verifies the self-signed origin; `noTLSVerify` is "last resort" | Origin leg yes; end-to-end no (Cloudflare sees plaintext incl. the API key) | Traffic and key transit a third party - state this risk plainly. |
| ngrok | Public hostname | HTTPS endpoints terminate at ngrok's cloud; `ngrok tls`/TCP endpoints pass through so llmctl's own TLS stays end-to-end | TLS/TCP tunnel: yes (name in cert must match the ngrok hostname -> add to SAN; ngrok TCP gives host:port, hostnames change on free plans) | Account required (third party). |
| SSH reverse tunnel (`ssh -R`) to a VPS | Public via your VPS | TCP pass-through; end-to-end | Yes (VPS name in SAN) | Needs `GatewayPorts` on the VPS; you operate and secure the VPS (INFERRED/UNVERIFIED). |
| Public-CA cert (ACME) instead of the local CA | any of the above | end-to-end | n/a - clients need no import | DNS-01 (works for private/internal hosts, needs DNS API token), HTTP-01/TLS-ALPN-01 (needs inbound 80/443). **Let's Encrypt IP-address certificates are GA (2026-01-15)**: 160-hour lifetime, `shortlived` profile, ACME client with profile support (Certbot supports as of 2026-03) - validation methods not stated in the page I fetched; LAN/private IPs cannot get public certs (INFERRED). llmctl accepts any of these through FR-067 (drop `fullchain.pem` + key into `cert/`, mode checks identical) and must **re-read** the files on `SIGHUP`/`llmctl cert reload` because 6-90 day certs rotate (design; UNVERIFIED). |

### 5.2 Firewall rules (operator documentation; UNVERIFIED unless noted)

- ufw: `sudo ufw allow from 192.168.1.0/24 to any port <PORT> proto tcp` (LAN only), or `sudo ufw allow <PORT>/tcp` (anywhere). `ufw status` needs root (VERIFIED: it errors without it) - so `llmctl doctor` must say "cannot read firewall state without root" rather than guess.
- firewalld: `sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.168.1.0/24" port port="<PORT>" protocol="tcp" accept' && sudo firewall-cmd --reload`.
- nftables: `nft add rule inet filter input tcp dport <PORT> ip saddr 192.168.1.0/24 accept`.
- macOS: Application Firewall prompts per binary (`/usr/libexec/ApplicationFirewall/socketfilterfw --add /path/to/python3 --unblockapp /path/to/python3`); pf only for advanced users (INFERRED). Only the ports llmctl actually binds should be opened; engine backends stay loopback (FR-073), so they need no rule.
- Router: forward external `<PORT>`/TCP -> host LAN IP `<PORT>`; reserve the host's DHCP lease so the forward and the cert SAN stay valid.

### 5.3 What can be proven without a second machine or third-party accounts (probed here)

Host facts (VERIFIED-LOCALLY, read-only): `unshare -rn` fails (`write failed /proc/self/uid_map: Operation not permitted`; `kernel.apparmor_restrict_unprivileged_userns = 1`), so a hand-made user+net namespace is unavailable. Rootless podman works and offers two network modes:

| Vantage | Result in my test (server bound to **127.0.0.1** only; positive control = an existing 0.0.0.0 listener on :5432) |
|---|---|
| `podman run --network=pasta` -> host LAN IP | **both** ports refused (the host's own address is copied into the container namespace, so the connection never leaves it) -> **inconclusive; do not use for FR-064** |
| `podman run --network=slirp4netns` -> host LAN IP | :5432 `CONNECT OK` (positive control), :18443 refused (loopback-only listener) -> **a valid "distinct address" vantage** that distinguishes loopback-only from wildcard-bound listeners |
| pasta with `--map-host-loopback=10.0.2.2` | reaches the host's loopback listener; TLS name mismatch (`10.0.2.2` not in SAN -> curl error) is a free negative test; `--resolve localhost:18443:10.0.2.2` gets `401` |
| Same-host self-connect to the LAN IP (no container) | `192.168.1.115:18443` -> `ConnectionRefusedError` while `127.0.0.1` connects: a zero-dependency "bound only to this machine" detector for FR-064's start-up check (VERIFIED). `ss -Hltn "sport = :PORT"` prints the bound address (VERIFIED); macOS: `lsof -nP -iTCP:PORT -sTCP:LISTEN` (UNVERIFIED). |

Limits (INFERRED, state them in the evidence): slirp traffic is generated by a host process, so it normally arrives over the host's loopback/LAN path and **does not exercise the host firewall's inbound rules, the router, NAT, DDNS or the ISP** - it proves "bound to a non-loopback address and reachable from a different network namespace", not "reachable from the LAN" or "from the internet". Therefore SC-013/FR-064 evidence should record the vantage (`slirp4netns-container` vs `second-machine`) as the spec already allows, and FR-065 must list as **not provable here**: router port-forward, DDNS resolution, ISP/CGNAT, IPv6 inbound policy, third-party tunnel behaviour.

CGNAT / public-address detection without third parties: parse `ip route get 1.1.1.1` source, then flag if the *router WAN* address (operator-entered or from `upnpc`-free router page) is in `100.64.0.0/10` (RFC 6598). Local helper VERIFIED: `ipaddress.ip_address('100.64.1.1') in ip_network('100.64.0.0/10')` -> True; note `is_private` is **False** for CGNAT space, so use `is_global` (and TEST-NET `203.0.113.0/24` reads as private, not global). Comparing WAN IP vs "what the internet sees" needs an external echo service; document it as an operator step (e.g. an IP-echo page) rather than calling one from llmctl.

---

## 6. Hardening / enterprise checklist

### 6.1 OWASP API Security Top 10 (2023) mapped to the decision endpoints

| ID | Risk | llmctl mapping / control |
|---|---|---|
| API1 BOLA | object-level auth | Single shared key = single tenant; there are no per-user objects. State this explicitly; if a "decision id/profile" path parameter exists, a valid key may address any profile - acceptable because one key = one operator. |
| API2 Broken authentication | | Constant-time compare; no key in URL; 401 for every unauthenticated path except the minimal health probe; health probe returns `{"status":"ok"}` only (no profile name/backend state - see source-findings D-04); failed-auth rate limit; HTTPS only. |
| API3 Property-level auth | | Strict JSON schema in/out; reject unknown fields; never echo server config. |
| API4 Unrestricted resource consumption | | Max body (e.g. 256 KiB, configurable), max header size, max concurrent connections (section 2), handshake + absolute deadlines, bounded queue to the engine, per-request token/time cap, bounded `state` text length. |
| API5 BFLA | | Admin operations (`cert renew`, `key rotate`) are local CLI only, not HTTP routes. |
| API6 Sensitive business flows | | n/a (no business flow); note prompt-injection below. |
| API7 SSRF | | Gateway->runtime URLs come only from local config, never from request data; engine backends loopback-only (FR-073). |
| API8 Security misconfiguration | | Refuse start without key / valid cert; TLS floor; no plain listener; no default CORS; `Server` header minimal; error bodies generic; verify unit hardening with runtime probes (section 6.4). |
| API9 Improper inventory | | Auto-generated route table in docs; the SC-013 matrix is the inventory; reject unknown paths with 404 *after* auth. |
| API10 Unsafe consumption of APIs | | Validate engine responses against the schema before returning; timeouts on the loopback call. |

### 6.2 HTTP-level hygiene (all responses)

`Cache-Control: no-store`, `X-Content-Type-Options: nosniff`, `Content-Type: application/json; charset=utf-8` (these three were set in the verified test server), `Connection: close` for error paths, no `Server: BaseHTTP/...Python/...` banner (override `version_string`/`server_version`), HSTS is **not** needed for API clients and can lock browsers to a bad cert (INFERRED; omit). **CORS: none** - send no `Access-Control-*`; browser JS from another origin is not a supported client, and a permissive CORS would let any web page the operator visits call a LAN endpoint if the key leaks. Reject `Origin` headers that are present? (design choice: respond 403 for requests with `Origin` unless `LLMCTL_CORS_ORIGINS` is set - UNVERIFIED). Error bodies: fixed shape `{"error":{"code":"...","message":"..."}}`, never exception text, paths, or version strings.

### 6.3 Audit log format (no state text)

One JSON object per line: `ts` (UTC ISO-8601), `rid` (random 64-bit hex), `method`, `path` (no query), `status`, `ms`, `bytes_in`, `bytes_out`, `auth` (`ok|missing|invalid`), `client` (IP), `profile` (id only), `tls` (`TLSv1.3`), and **never** state text, prompts, the `Authorization` header or any key material. File mode `0600`, rotated by size, no secrets in rotated names. SC-005 leak scan covers these files.

### 6.4 systemd user-service hardening - what actually works here

Probed with transient `systemd-run --user` units on systemd 259 (VERIFIED-LOCALLY):

| Directive | Result |
|---|---|
| `NoNewPrivileges=yes` | effective (`NoNewPrivs: 1` in `/proc/self/status`) |
| `RestrictAddressFamilies=AF_UNIX` | effective (`socket(AF_INET)` -> `[Errno 97]`); for the real service use `AF_INET AF_INET6 AF_UNIX` |
| `UMask=0077` | effective (umask 0o77) |
| `LockPersonality`, `SystemCallArchitectures=native`, `MemoryDenyWriteExecute` | accepted; Python 3.14 starts under MDWE (use `MemoryDenyWriteExecute=yes` only after testing the real engine launcher - JITs/ONNX may break; keep it off the engine units) |
| `MemoryMax=` | applied to the cgroup (accepted; existing units already use it) |
| `LoadCredential=` | effective (`0400`, tmpfs path) |
| `ProtectSystem=strict`, `ProtectHome=yes/read-only`, `InaccessiblePaths=`, `PrivateTmp`, `PrivateUsers=yes` | **accepted with exit 0 but a write to `/tmp/...` and to `$HOME/.cache` still succeeded** - the user manager did not apply mount-namespace sandboxing (likely because `kernel.apparmor_restrict_unprivileged_userns=1`; INFERRED). `systemd-analyze security` still gives credit for them (score 7.6 EXPOSED on my test unit), so the score is **not** evidence. systemd's own manual states these need privileges or `PrivateUsers=` + unprivileged user namespaces in user instances. |

Decision: ship the effective set (`NoNewPrivileges`, `RestrictAddressFamilies`, `UMask=0077`, `LockPersonality`, `SystemCallArchitectures=native`, `MemoryMax`, `LoadCredential`, `Restart=always`, `StartLimit*` in `[Unit]`) and add the sandbox set as **opportunistic** with a doctor probe (`touch` a canary outside `ReadWritePaths` from a transient unit; report "sandbox not enforced on this host" instead of claiming). Never document ProtectSystem as a protection without that probe. macOS equivalents: none for most (launchd has `Sandbox`/seatbelt profiles - UNVERIFIED and unwieldy); rely on user-level agents, owner-only files, the Application Firewall, and `SoftResourceLimits`/`HardResourceLimits` keys for memory/files (UNVERIFIED).

### 6.5 Supply chain / release

- No pip dependencies for TLS/auth (stdlib only); `openssl` and `python3` are the only external binaries -> record their versions in `llmctl cert doctor`.
- SBOM: Syft (`docker.io/anchore/syft` image is already on this host) emits CycloneDX/SPDX; sign checksums + SBOM with `cosign sign-blob` (keyless needs a third party; a local key is the offline option) - SLSA-style provenance via in-toto attestation. Pin by digest/sha256 in a `SHA256SUMS` file shipped with the release (the repo already checksums downloads). `make archive` output should include `SBOM.cdx.json` and `SHA256SUMS`. All UNVERIFIED (not run).
- Pin test tooling versions (testssl.sh 3.2 and Syft v1.54.1 images are already local).
- Secret scanning of the release tree: TruffleHog image is local (`trufflesecurity/trufflehog:3.98.1`); run it in the SC-005 evidence scan in addition to the fixed-string key search (UNVERIFIED, not run).

### 6.6 Prompt-injection residual risk for `state` text

The decision endpoint feeds operator/user-supplied `state` text to a local model. OWASP LLM01 (2025) treats instructions embedded in data as a persistent, un-eliminable risk; mitigations that apply here: instruction/data separation in the prompt template, **constrained output** (typed choice with probabilities validated against the schema - a successful injection can at worst select a different valid label, it cannot produce free-form output or tool calls), output validation in code, no tools/network/filesystem access for the model, length limits, and logging only metadata. Residual risk to state in docs: an attacker who can write into `state` can bias the decision; downstream consumers must treat the label as advisory input to a human or a guard, not as an authorization decision (INFERRED from the OWASP guidance; no local test).

---

## 7. Test-matrix recipes (for FR-069/070, SC-013) that I proved work

| Case | Recipe | Result |
|---|---|---|
| Name not covered | `curl --cacert ca.crt --resolve other.example:PORT:127.0.0.1 https://other.example:PORT/` | `(60) no alternative certificate subject name matches` |
| Expired cert | issue a leaf with `openssl x509 -req ... -not_before 20250101000000Z -not_after 20250102000000Z` (OpenSSL 3.x) and serve it | `(60) certificate has expired (10)` |
| Untrusted cert | any client without the CA | curl `(60) unable to get local issuer certificate`; Python `CERTIFICATE_VERIFY_FAILED`; Node `UNABLE_TO_VERIFY_LEAF_SIGNATURE`; Go `unknown authority`; Java `PKIX path building failed`; Chromium `ERR_CERT_AUTHORITY_INVALID` |
| Altered cert/key | load a cert with another key | `KEY_VALUES_MISMATCH` at `load_cert_chain` |
| Plain HTTP to HTTPS port | `curl -m 5 http://127.0.0.1:PORT/` | `(56) Recv failure: Connection reset by peer` |
| Old protocol | `openssl s_client -connect h:p -tls1_1` | `no protocols available` (client side; confirm server side with `testssl.sh --protocols`: TLS1/1.1 "not offered") |
| Weak ciphers | `testssl.sh --ciphers` / `openssl s_client -cipher 'NULL:RC4'` | testssl run showed no legacy offerings (full cipher run not executed - UNVERIFIED) |
| Wrong pin | `curl -k --pinnedpubkey sha256//AAAA... ` | `(90) public key does not match pinned public key` |
| Slow / idle clients | 3-4 idle raw TCP sockets + a real request | real request served in 44 ms |
| Concurrent first start | 5 parallel `ensure` processes | 1 generated, 4 reused |

---

## 8. Open risks and recommendations for the plan

1. **`http.server` is not production grade** (Python docs); the pattern in 2.2 bounds the worst stdlib DoS paths but cannot give HTTP/2, rich header limits, or request pipelining safety. Accept and document, or front with Caddy/nginx in the operator's own setup (not required).
2. **The CA key lives on the same host as the server** - unavoidable for unattended renewal; mitigate with `pathlen:0`, `0600`, optional name constraints, and a documented "move `ca.key` offline" mode that makes `cert renew` require the operator to supply it.
3. **Agent CA support is the weakest link**: Claude Code env-in-settings is documented-working but reported broken; pi and crush are undocumented; aider has no CA option. The FR-069 matrix must exercise each agent for real or record "not exercised" with the reason (spec already allows).
4. **Address drift (DHCP)** invalidates IP SANs; recommend a DHCP reservation or hostname/DDNS use, and make the doctor warning actionable.
5. **Listening on all interfaces by default + key in `.env`**: first start prints the bind address and a one-line reachability summary (from the FR-064 self-connect check); document that anyone on the LAN can attempt requests and that the rate limit + 256-bit key are the control.
6. **Public exposure** is operator-initiated and documented with risks, never automated (no UPnP).
7. Items I could not verify locally: macOS behaviours (LibreSSL flags, launchd, zsh/Keychain/Safari), NSS import (no `certutil`), the seven agents' actual TLS behaviour, `num_tickets`, dual-stack binding, ufw/firewalld/nft/pf commands, ACME flows, SBOM/signing tools.

---

## Sources

- Python `ssl` docs: https://docs.python.org/3/library/ssl.html ; `http.server` docs (HTTPSServer/ThreadingHTTPSServer added 3.14, "not recommended for production"): https://docs.python.org/3/library/http.server.html
- Claude Code network config (CA store, `NODE_EXTRA_CA_CERTS`, `CLAUDE_CODE_CERT_STORE`, background agents): https://code.claude.com/docs/en/network-config.md ; bug report: https://claudeissues.com/issue/22512-bug-node-extra-ca-certs-is-not-effective-when-set-in-claude-settings-json
- opencode network docs: https://opencode.ai/docs/network ; per-provider TLS commit: https://git.joshthomas.dev/mirrors/opencode/commit/0c8f4475e9f798ae1265ceae6e54647d48cdbe7a
- Crush README: https://github.com/charmbracelet/crush ; pi-mono: https://github.com/badlogic/pi-mono
- Aider options: https://aider.chat/docs/config/options.html ; LiteLLM SSL settings: https://docs.litellm.ai/docs/guides/security_settings
- Continue cert troubleshooting (search result): https://docs.continue.dev ; Cline docs: https://docs.cline.bot
- Node CLI docs (`NODE_EXTRA_CA_CERTS`, `--use-system-ca`): https://nodejs.org/api/cli.html
- Apple TLS certificate requirements (398 days; user-added roots exempt): https://support.apple.com/en-us/102028
- LibreSSL `-addext` (3.1.0): https://ftp.fau.de/openbsd/LibreSSL/libressl-3.1.0-relnotes.txt ; issue: https://github.com/libressl-portable/portable/issues/544
- Let's Encrypt 6-day and IP certificates GA: https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability
- Tailscale HTTPS certs: https://tailscale.com/kb/1153/tailscale-cert
- Cloudflare Tunnel HTTPS origins: https://developers.cloudflare.com/tunnel/troubleshooting/https-origins/
- ngrok TLS termination: https://ngrok.com/docs/gateway/tls-termination.md
- CGNAT detection: https://oneuptime.com/blog/post/2026-03-20-detect-cgnat/view
- UPnP risks: https://hkcert.org/my_url/en/blog/13022801 ; https://www.avast.com/c-what-is-upnp
- OWASP API Security Top 10 2023: https://apisecurity.io/owasp-api-security-top-10/
- OWASP LLM01 prompt injection summaries: https://www.myctrl.tools/risk-lists/owasp-llm-top10/llm01 ; https://snyk.io/articles/building-safer-ai-agents-structured-outputs/
- RFC 6750: https://www.rfc-editor.org/rfc/rfc6750
- zsh startup files: https://zsh.sourceforge.io/Doc/Release/Files.html
- systemd.exec (credentials, user-service sandbox limits): https://man7.org/linux/man-pages/man5/systemd.exec.5.html
- launchd required behaviours: https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html
- macOS trust import (`security add-trusted-cert`): https://cert-depot.com/guides/trust-self-signed-cert-macos
- NSS/Firefox/Chrome CA import on Linux: https://thomas-leister.de/en/how-to-import-ca-root-certificate/
- Debian `update-ca-certificates`: https://manpages.debian.org/update-ca-certificates.8 ; Fedora shared system certificates: https://docs.fedoraproject.org/ms/quick-docs/using-shared-system-certificates/
- Name constraints (RFC 5280 4.2.1.10 overview): https://man.openbsd.org/NAME_CONSTRAINTS_new.3
- OWASP Secrets Management (env-var guidance, via summaries): https://developer.cyberark.com/?p=2096
- Remote access comparison: https://homelabstarter.substack.com/p/remote-access-without-port-forwarding
- Local throwaway artifacts (not part of the repo): `/tmp/claude-1000/-home-milosvasic-Projects-llmctl/09f54cd2-bbc4-42e2-81e6-8e453f2c3261/scratchpad/` (`srv.py`, `srv2.py`, `m1..m9.sh`, `pki/`)
