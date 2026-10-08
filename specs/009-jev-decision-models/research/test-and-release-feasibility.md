# Test-infrastructure and release-process feasibility (feature 009)

Date: 2026-10-07. Host: `anton` (Linux 7.0.0-34-generic, user `milosvasic`). Repo HEAD `a9ebefe`.
Method: read-only local probes (outputs below are verbatim excerpts from this session) plus web research.
Anything not directly measured is marked INFERRED. Nothing in the repo was modified except this file; scratch work was under the session scratchpad and has been stopped.
No agent was run against a model; no network scan was made; only this host's interface/neighbour tables were read.

## 1. Probe results

### 1a. Second network location (FR-064 / FR-069)

```
$ ip -brief addr
lo      UNKNOWN  127.0.0.1/8 ::1/128
enp5s0  UP       192.168.1.115/24 fe80::f22f:74ff:fe52:21a/64
$ ip route
default via 192.168.1.1 dev enp5s0 proto dhcp src 192.168.1.115 metric 100
192.168.1.0/24 dev enp5s0 proto kernel scope link src 192.168.1.115 metric 100
$ ip neigh   (neighbour table only; NOT contacted)
192.168.1.87 REACHABLE 02:67:18:9e:a0:23 ; 192.168.1.1 REACHABLE (gateway/router)
192.168.1.127/.128/.129/.130/.131/.25/.40/.14/.59/.20  STALE
```
- Other LAN machines exist in the neighbour table (11 besides the gateway), but I cannot tell which are the operator's own, which accept SSH, or which could host a client. `~/.ssh/config` has no `Host` entries. Using one is an operator decision (INFERRED: 192.168.1.87 is the only recently active one).
- Rootless `unshare -rn` is blocked:
  ```
  $ unshare -rn sh -c 'ip -brief addr; id'
  unshare: write failed /proc/self/uid_map: Operation not permitted
  $ sysctl kernel.apparmor_restrict_unprivileged_userns
  kernel.apparmor_restrict_unprivileged_userns = 1
  ```
- Rootless podman 5.7.0 works (`Rootless=true`, netavark, `/usr/bin/pasta`, `slirp4netns`, `passt` present). Small image already local, so nothing needs pulling: `docker.io/library/python:3.12-slim-bookworm` (129 MB), also `node:20-alpine`, `node:22-alpine`, `debian:bookworm-slim`, `localhost/g-cli-14-egress-test-tools` (16.9 MB).
- Experiment: throwaway `python3 -m http.server` bound to the LAN IP `192.168.1.115:38417` and another to `127.0.0.1:38418`; client inside a rootless container fetches `/index.txt`:

  | container network | container's own address | LAN-IP-bound server (192.168.1.115:38417) | loopback-bound server (127.0.0.1:38418) |
  |---|---|---|---|
  | `pasta` (podman default rootless) | 192.168.1.115 (same as host) | `Connection refused` | n/a |
  | `slirp4netns` | 10.0.2.100 | OK `hello-from-host` | `Connection refused` (via LAN IP and via 10.0.2.2) |
  | `bridge` (netavark) | 10.88.0.2 | OK | `Connection refused` (via LAN IP and via 10.88.0.1) |
  | `podman` (named bridge) | 10.88.0.3 | OK | not tested separately |

  The server log shows the source of every successful request as `192.168.1.115`, i.e. the host's own LAN address: the namespace's own address (10.88.0.x / 10.0.2.100) is NAT-ed (masqueraded) on the way. With `pasta` the container shares the host's address, so connecting to the host's own LAN IP lands on the container's own loopback and is refused; it is therefore NOT a valid second vantage point (a refusal there proves nothing).
- Firewall: `ufw` installed, `systemctl is-active ufw firewalld nftables` all `inactive`; `ufw status` and `nft list ruleset` need root (not available), so the rule base cannot be read. INFERRED: no host firewall is filtering inbound (ufw inactive); iptables rules from container runtimes may still exist. A "blocked by firewall" detector (FR-064) can only be tested against a real firewall by an operator with root; it can be unit-tested by faking the probe result.

### 1b. Host facts

```
listening (ss -ltn, distinct local addr:port, abridged): 0.0.0.0:{22,139,445,5432,7186,7187,8000,8001,8082,8089,8402}
  127.0.0.1:{11434,18434,35091,41709,55432,631,8432,6881}  *:{27017,43715,56379,6335,6336,7061,7185,7188,7189,8080,8087,8099,8100,8102,8110,8111,8200-8206,8210-8212,8215,8220,8221,8224,8234-8239,8250-8254,8260-8263,8270,8317,8443,8445,9091,9117}
```
- Taken and relevant: 8095 (the toolkit's expected decision-gateway port) was NOT in the list (free at probe time, INFERRED: still free); 8443, 8445, 8080, 8200-8270 are taken, so a default HTTPS port in those ranges would collide. 11434 is bound (ollama-style) on loopback.
- `loginctl show-user`: `Linger=yes`. `systemctl --user is-system-running`: `degraded` (user manager is up but with at least one failed unit; `systemctl --user --failed` not checked).
- Disk: `/` 1.8T, 92G free, 95% used (tight for large model downloads). `/tmp` is a 16 GB tmpfs (15G free). Memory: 30 GiB total, 19 GiB available, swap 8.0/8.0 GiB used (swap is exhausted: real memory pressure risk for FR-049). 16 CPUs.
- Versions: python 3.14.4 (OpenSSL 3.5.5), node v26.8.1, go 1.26.0, curl 8.18.0 (OpenSSL 3.5.5, nghttp2), openssl 3.5.5, podman 5.7.0, git 2.53.0, gh 2.98.0, glab 1.121.0 (snap), jq 1.8.1.
- Reachability (HEAD): pypi.org 200, registry.npmjs.org 200, proxy.golang.org 200, github.com 200, gitlab.com 301, huggingface.co 200, api.github.com 200, files.pythonhosted.org 404 (host root; expected). Host is online, so pip/npm/go installs and release-binary downloads are possible; each one must be recorded as a need.
- A TLS/negative-matrix feasibility experiment (scratch self-signed cert with SAN `anton, 127.0.0.1, 192.168.1.115`, Python TLS server `minimum_version=TLSv1_2`):
  ```
  curl (no trust)            -> curl: (60) ... self-signed certificate (18)
  curl --cacert c.pem        -> 200
  curl --resolve other.name  -> (60) no alternative certificate subject name matches target hostname 'other.name'
  curl http:// to TLS port   -> (56) Recv failure: Connection reset by peer
  openssl s_client -tls1_1   -> "no protocols available" (client-side refusal: OpenSSL 3.5 will not even offer it)
  openssl s_client -cipher DES/RC4 -> "no cipher match" (client-side refusal)
  openssl s_client -tls1_2 -brief -CAfile c.pem -> CONNECTION ESTABLISHED, Protocol version: TLSv1.2
  python3 ssl, min=max=TLSv1_1 / TLSv1, ciphers ALL:@SECLEVEL=0 -> SSLError TLSV1_ALERT_PROTOCOL_VERSION
  node tls.connect minVersion TLSv1 maxVersion TLSv1.1          -> ERR_SSL_TLSV1_ALERT_PROTOCOL_VERSION
  go (stdlib, MinVersion TLS10 MaxVersion TLS11)                -> remote error: tls: protocol version not supported
  ```
  Consequence: the "client offering only outdated versions/weak ciphers" case of FR-070 CANNOT use stock `openssl s_client` or curl on this host; use the Python/Node/Go clients (all three delivered a genuine server alert). Expired-certificate generation: `openssl req -x509 ... -not_after` is not accepted by 3.5.5 as typed in my probe (it printed an error about `/etc/ssl/openssl.conf.d` and I did not obtain the expired cert); use `openssl x509 -req -days -1` or `faketime`/a Python `cryptography` (46.0.5 installed) builder instead (INFERRED, not tested).
- Browser-driven client: `/snap/bin/chromium` and `/usr/bin/firefox` exist. `chromium --headless=new --no-sandbox --disable-gpu --dump-dom about:blank` printed `<html><head></head><body></body></html>` (works; a harmless snap-mount warning is printed). Playwright is not installed (`import playwright` fails); the Playwright MCP tool of the harness is separate. Trusting the self-signed cert in Chromium needs `--ignore-certificate-errors-spki-list=<base64 sha256 spki>` (pins, not blanket disable) or an NSS db import (INFERRED from Chromium docs, not tested here).

### 1c. Tool availability (command -v)

| tool | present | tool | present |
|---|---|---|---|
| curl, openssl, wget, jq, sha256sum | yes | kcov | NO |
| python3 (3.14.4), requests 2.32.5, urllib3, cryptography 46.0.5 | yes | coverage.py | NO |
| node 26.8.1, npm 11.19, npx | yes | pytest | NO |
| go 1.26.0, gofmt, golangci-lint (in `~/go/bin`) | yes | shellcheck | NO (so `make lint` prints "skipping") |
| podman 5.7.0 (+pasta, slirp4netns) | yes | bats, shfmt, hyperfine | NO |
| gh 2.98.0 (logged in as milos85vasic, ssh, scopes repo/read:org/gist) | yes | wrk, hey, k6, vegeta, oha, ab | NO |
| glab 1.121.0 (snap; logged in to gitlab.com, ssh git ops, API https) | yes | testssl.sh, sslyze, nmap, slowhttptest | NO |
| gpg | yes, but `gpg --list-secret-keys` returned no keys; `commit.gpgsign`/`tag.gpgsign` unset | minisign, cosign | NO |
| uv (`~/.local/bin/uv`) | yes | hurl, newman, schemathesis, dredd, mutmut | NO |
| chromium (snap), firefox | yes | pip/pip3, pnpm, cargo/rustc, playwright | NO |
| trivy / semgrep / sonar-scanner CLIs | trivy/semgrep only as podman images (`aquasec/trivy:0.75.0`, `semgrep/semgrep:1.179.0`, `sonarsource/sonar-scanner-cli:12.2`) | zap | podman images `zaproxy/zap-stable`, `ghcr.io/zaproxy/zaproxy:2.17.0` |

Python modules absent: coverage, pytest, httpx, onnxruntime, numpy, playwright. Global npm: crush 0.91.2, pi-coding-agent 0.85.1, codegraph, mermaid-cli, speckit.

### 1d. The seven agents

Installed (measured): opencode 1.18.30 (`~/.opencode/bin/opencode`), pi 0.85.1, crush v0.91.2, Claude Code 2.1.292. NOT installed: aider (not on PATH), continue CLI `cn` (not on PATH; `command -v continue` only matches the shell builtin; no `~/.continue`), cline (no binary, no `~/.cline`). Installers exist in `docs/integrations/install_<agent>.sh` and the host can reach the upstream install sources (INFERRED from the reachability probe; each is a download-and-execute step that must be recorded as a need).

| agent | installed | non-interactive prompt (source) | custom CA / self-signed | base URL / provider | can it call a custom HTTP API (the decision endpoint)? |
|---|---|---|---|---|---|
| opencode | 1.18.30 | `opencode run "msg" -m provider/model --format json [--auto]` (`opencode run --help`, measured) | per-provider `options.tls.{ca,rejectUnauthorized,cert,key}` in `opencode.json`; also `NODE_EXTRA_CA_CERTS`, `NODE_OPTIONS=--use-system-ca`, `BUN_OPTIONS=--use-system-ca` (web: opencode providers docs / mirrored commit) | `provider.<id>.options.baseURL` with `@ai-sdk/openai-compatible` (repo docs/integrations.md line ~127-180) | Yes via its bash tool (curl, so CA is the system/curl trust: `--cacert`/`SSL_CERT_FILE`/`CURL_CA_BUNDLE`), `--auto` needed to auto-approve permissions (INFERRED the bash tool needs approval otherwise) |
| pi | 0.85.1 | `pi -p "msg" --provider X --model Y [--mode json] [--no-session]` (`pi --help`, measured) | Node-based: `NODE_EXTRA_CA_CERTS` (INFERRED, Node standard; not in pi docs) | `~/.pi/agent` models config with `base_url`/`api_key` (repo docs/integrations.md ~199-218); `--api-key` flag | Yes: built-in `bash` tool (`pi --help` header: "read, bash, edit, write tools"); `--tools` allowlist exists |
| crush | v0.91.2 | `crush run [-q] [-m provider/model] "prompt"` (stdin also accepted) (`crush run --help`, measured) | Go binary: `SSL_CERT_FILE`/`SSL_CERT_DIR` (INFERRED Go crypto/x509 behaviour; search found no crush-specific TLS doc) | `crush.json` provider `type: openai-compat`, `base_url`, `api_key` (mintlify/charm docs) | Yes via its bash tool; permission prompts in non-interactive `run` UNKNOWN (needs a `permissions.allowed_tools` setting or `--yolo`-style flag; not verified) |
| claude (Claude Code) | 2.1.292 | `claude -p "msg" --output-format json --allowedTools "Bash(curl *)" [--permission-mode ...]` (`claude --help`, measured) | `NODE_EXTRA_CA_CERTS` (web, nodejs.org + Claude Code proxy docs); bash tool uses curl so `SSL_CERT_FILE` as well | `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN`; colibri serves `/v1/messages` natively, llama-server needs an OpenAI->Anthropic shim (repo docs/integrations.md ~253-265) | Yes via Bash tool restricted by `--allowedTools` |
| aider | NO | `aider --message "text" --yes-always` (+ `--no-git`) (aider.chat/docs/scripting.html, web) | Python (litellm/httpx): `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`; aider has `--no-verify-ssl` (disabling is last-resort only per FR-068) (INFERRED from Python stack, partly web) | `OPENAI_API_BASE` / `--openai-api-base` | LIMITED: aider has no general bash tool; it only runs shell via `/run` and `/test` commands (INFERRED); likely "not exercised: cannot make HTTP calls" unless `--message "/run curl ..."` works (UNKNOWN, to be tested live) |
| continue (`cn`) | NO | `cn -p "msg"` headless prints final response only (Continue CLI docs, web) | `config.yaml` model `requestOptions` (`caBundlePath`, `verifySsl`) (training knowledge; web search did NOT confirm - UNVERIFIED) | `config.yaml` `apiBase` (repo docs/integrations.md ~290-375) | UNKNOWN: CLI has tools incl. terminal/bash (INFERRED), permission policy for headless needs `--allow Bash`-style flag (UNVERIFIED) |
| cline | NO | `cline -y "task"` (YOLO = headless, auto-approves), `--json`, or piped stdin (docs.cline.bot CLI reference, web) | Node: `NODE_EXTRA_CA_CERTS` (INFERRED, search found no cline-specific doc) | `cline auth -p openai -k KEY -b https://host/v1` (docs.cline.bot) | Yes: auto-approved shell commands under `-y` (docs) |

Common point (important for FR-069/SC-007): for "agent calls the decision endpoint" the agent's own LLM must be a chat model the host can run (or a hosted one, not allowed to be used here by the operator's local-only intent: UNKNOWN), and the agent's TLS to the decision endpoint is governed by the CA trust of the tool it uses (usually curl via bash), not by the agent's LLM-provider TLS settings. The independent request record on the endpoint (SC-007) is the only acceptable proof of an agent pass.

## 2. Vantage points available for FR-064 / FR-069 (decision)

Available, measured today:
1. **Rootless podman container on a netavark bridge** (`--network=bridge`, or the named `podman` network): own netns, own address (10.88.0.x), separate from the host stack, can reach a server bound to the LAN IP 192.168.1.115, cannot reach a loopback-bound server (this is the FR-073 negative test and it behaved correctly: `Connection refused`).
2. **Rootless podman `--network=slirp4netns`**: own address 10.0.2.100, same results. A second, independent implementation (useful as cross-check).
3. NOT valid: `unshare -rn` (blocked by AppArmor), `--network=pasta` (shares the host address; refuses connections to the host's own LAN IP, so a pass or fail there says nothing).
4. A real second machine on the LAN exists in principle (192.168.1.87 and others in the neighbour table) but none is known to be usable; `~/.ssh/config` is empty. Requires the operator.

**Decision (recommended): record the vantage as "isolated network namespace with its own address, rootless podman bridge (10.88.0.0/16), with slirp4netns as cross-check"** per the fallback allowed by FR-064, and ask the operator once whether a real second LAN machine is available for at least the minimum matrix subset (curl + one more client, health + one decide call); if yes, add it as vantage 3 and record both.

Caveats that MUST be stated in the evidence (honest limits): (a) the container's traffic is NAT-ed to the host's own source address `192.168.1.115` (observed in the server log), so it proves bind address, TLS SAN coverage, auth and routing as seen from a different network stack, but NOT physical-NIC reachability, router behaviour, or host firewall rules (ufw inactive and unreadable without root); (b) the FR-064 firewall/bound-only detector must be validated separately (unit-test with injected probe results; and live: bound-to-127.0.0.1 gives a deterministic refusal from the namespace, measured); (c) "cloud" reachability (FR-065) can only be proven to the extent that something outside the LAN can be contacted; INFERRED: not provable from this host without an external probe service or the operator's phone/other network - state "not exercised" with reason; (d) the container image must contain the client (python image has Python; Node/Go/curl clients need `node:22-alpine`/a Go static binary mounted in/curl image: nothing needs to be pulled if `node:22-alpine` + mounted Go binary are used, otherwise the `g-cli-14-egress-test-tools` 16.9 MB image may contain curl: UNKNOWN, check).

## 3. Test-type matrix mapped to requirements

Harness constraints: `tests/run_tests.sh` runs every `tests/test_*.sh` as `bash file`, captures output and exit code, prints a table (stdout only; no JSONL/manifest today). No coverage tool for bash or Python is installed; `make lint` silently skips because shellcheck is missing. Adding `test_*.sh` files is automatic; counts are documented in prose (FR-043 needs a generated count: a check comparing `ls tests/test_*.sh | wc -l` with documented numbers).

| test type (FR-038) | what to test | how, with what is available | FRs |
|---|---|---|---|
| unit | key generation/format/permissions, cert SAN building, planner math, arg parsing, endpoint inventory parser; stand-ins allowed ONLY here and tagged | bash `test_*.sh` + stdlib `unittest` (no pytest) | FR-038/039/041/063 |
| integration | real model files, real llama-server/onnx runner, gateway to runtime over HTTPS with cert verification | existing harness; real components only | FR-039/046/073 |
| end-to-end | CLI `decide ask/serve` -> HTTPS endpoint -> real model; install script e2e | real subprocesses; profile download only for fitting ones | FR-046/047 |
| contract | hosted-Jev wire shape (request/response JSON, error classes) per path and method | schema file in `specs/009.../contracts/` (currently EMPTY directory) checked by a stdlib JSON-schema-lite validator or `jq`; the OpenAPI-style inventory is the source of the endpoint list | FR-069, SC-013 |
| endpoint inventory / coverage | proof no path+method is untested | derive inventory from code (`do_GET`/`do_POST` branches in the candidate `lib/decide_gateway.py:287-311`, `lib/onnx_server.py:397-412`) AND from a checked-in list; matrix runner marks each cell pass / not-exercised(reason); CI-style check fails when a path in the inventory has an empty row | FR-069, SC-013 |
| TLS conformance / negative | host-name mismatch, expired, untrusted, altered cert/key, plain HTTP to TLS port, legacy protocol/cipher client, min-version documented | measured feasible (section 1b): curl for 4 of 6; Python/Node/Go for legacy-protocol; Python `cryptography` to mint expired/altered certs; `openssl s_client -tls1_2/-tls1_3 -brief` for the positive protocol matrix; optionally testssl.sh/sslyze as extra (need download: testssl.sh is a single bash file from GitHub, sslyze needs pip) | FR-066..070 |
| security | auth: missing/wrong key -> 401, key never in argv/logs/evidence (repo-wide scan), `.env` perms 0600, startup-file helper idempotent, stale pid not signalled, internal engine port loopback-only | bash + python; leak scan = grep of evidence tree for the generated key value | FR-059..063, 073, SC |
| perf / benchmark | latency/throughput of determinism and cold start; decision latency per type | no wrk/hey/k6/hyperfine present: use a small Python `ThreadPoolExecutor` or Go program (stdlib `net/http`) to drive N requests, record p50/p95; `llmctld` already has `make bench-all` (`go test -bench`) | FR-038 |
| stress / chaos | concurrent clients, oversized/malformed/slow requests, kill runtime mid-request, restart reuse of key/cert, memory ceilings | pure-Python slow-client script (open socket, send partial headers/body byte-by-byte; the classic slowloris/RUDY pattern; nmap/slowhttptest absent); `kill -9` the runtime; assert gateway stays up; keep within memory ceiling (swap is already full) | FR-049, US2 scenario 8 |
| reachability | LAN bind vs loopback, second vantage point, FR-073 internal port refused | podman bridge/slirp4netns clients (section 1a) | FR-064/073 |
| agent live | each of 7 agents, endpoint request log matches | only 4 installed; install 3 or mark "not exercised"; independent evidence = endpoint's own request record | FR-048, SC-007 |
| client matrix | curl, Python (requests/urllib), Node (`https`/fetch), Go (`net/http`), browser (chromium headless), llmctl CLI, 7 agents; each x {this host, namespace} | all of the first five exist locally; browser via chromium headless | FR-069, SC-013 |
| determinism | same question twice -> identical answer; golden files normalised for timestamps/ports/ids | `tests/test_determinism.sh` exists; add normaliser (replace dates, UUIDs, host:port, durations) both when writing and comparing the golden | US1, FR-042 |
| mutation / guard-can-fail | each new check shown failing on a deliberately corrupted case | hand-rolled `sed` mutations in a copy of the tree (no tool exists for bash; mutmut needs pytest which is absent); one mutation per guard, assert the test goes RED | FR-040/041 |
| coverage | bash line coverage and Python server coverage | kcov and coverage.py absent. Bash: `PS4='+COV:${BASH_SOURCE##*/}:${LINENO}:'` with `BASH_XTRACEFD` to a file (constitution 11.4.224(E) describes this; its limit: line not branch coverage, `set +x` regions unaccounted). Python: `coverage.py` needs `uv pip`/venv install (`uv` exists; pypi reachable) with `COVERAGE_PROCESS_START` + `sitecustomize`/`.pth` and `parallel=true` to cover the servers launched as subprocesses; alternative zero-install: stdlib `trace`/`sys.settrace` (slow) | constitution coverage floor |
| evidence | machine-produced JSONL (one record per test: command, env, rc, sha256 of output, timings) + `SHA256SUMS` manifest of the evidence dir; optional hash chain (each record carries sha256(prev+canonical json)) | `sha256sum`, `jq` available | FR-042 |

Tools: free of any install: curl, openssl, Python (requests, urllib, ssl, cryptography, unittest), Node, Go (stdlib), podman, chromium. Install needs (record them; all reachable): coverage.py (via `uv venv`), Hurl (single binary from GitHub releases; no cargo here), testssl.sh (single bash file), kcov (distro package or source; apt needs root: UNKNOWN), shellcheck (needed anyway for `make lint` to mean something; apt needs root, or static binary from GitHub releases). schemathesis (`uvx schemathesis`) and Hurl are the two OpenAPI/endpoint-driven candidates; schemathesis needs an OpenAPI document (none exists: `grep -il openapi` in the candidate tree found nothing) and Python deps via uv, Hurl needs a binary and handwritten `.hurl` files (but gives assertions on status, headers and certificate fields, `--cacert`, `--resolve`). Recommendation: write the endpoint inventory as a small checked-in machine-readable list (path, methods, auth required, error classes), generate both the matrix and (if wanted) `.hurl` files from it, and use plain curl/Python for the matrix to avoid new installs; add Hurl only if the operator accepts a binary download.

## 4. Release procedure (gh + glab) and gaps in current tooling

Findings in `scripts/release/create_release.sh` (read in full):
- It validates SemVer, runs submodule preflight, generates a conventional-commit changelog since the latest tag, runs `make archive`, then calls `gh release create <tag> --title ... --notes-file ...` and `glab release create <tag> --name ... --notes-file ...`.
- GAP 1: it NEVER passes assets. `gh release view v3.0.2 --json assets` returned `{"assets":[],"isDraft":false,"tagName":"v3.0.2"}`: the existing release has no assets, although FR-054/SC-011 require identical artifacts and checksums.
- GAP 2: it does not create or push the tag itself and does not use `--verify-tag`/`--ref`; both CLIs create a tag if missing (gh: on default branch unless `--target`; glab: from `--ref`), which could tag the wrong commit.
- GAP 3: no `SHA256SUMS`, no signature, no download-verify step. `--notes-file` is placed under `$HOME/.cache/llmctl-release` because the glab snap cannot read `/tmp` (documented in the script; the same constraint applies to any asset file path passed to glab: build assets under `$HOME`, not `/tmp`).
- GAP 4: the changelog groups only feat/fix/docs/other; FR-053 wants highlights and known limitations: append a hand-written (but evidence-derived) section.
- The default `since_tag` is `git describe --tags --abbrev=0` (currently `v3.0.2`). The repo's `origin` has five push URLs (codeberg, gitflic, github, gitlab, gitverse; `upstreams/*.sh` each set one `UPSTREAMABLE_REPOSITORY`); all five answered `git ls-remote --tags --refs` with `651c705... refs/tags/v3.0.2` (measured), so all five are reachable from here.

Proposed step list (nothing was executed):
1. Preconditions: clean tree, on merged `main`, `git fetch --all`, `git status -sb` shows up to date; `bash constitution/scripts/validation/run_verification.sh` and `meta_test_verification.sh` pass (FR-056); `make validate` and the full harness pass (shellcheck missing means lint was skipped: record it); evidence dir complete.
2. Bump `VERSION` (3.0.2 -> 3.1.0, minor per FR-053), update changelog/docs; commit. Doc/test counts generated, not typed.
3. `bash scripts/release/create_release.sh --dry-run v3.1.0` and review. Fix GAP 1-3 first (extend the script or add a wrapper): build assets (`make archive` writes `../llmctl.tar.gz` and `../llmctl.zip`; copy under `$HOME` for glab), write `SHA256SUMS` (`sha256sum`), sign it if a tool is chosen (see risks: no minisign/cosign, no gpg secret key; the default honest option is checksums only, stated as such).
4. Create an annotated tag on the exact commit: `git tag -a v3.1.0 -m ... <sha>`.
5. Push branch then tag to every remote, fast-forward only, never `--force`/`+ref`/`--no-verify`: `git push origin main` (origin has 5 pushurls, so one command pushes to all five; verify each result) then `git push origin v3.1.0`. Verify per remote: `git ls-remote --tags --refs <remote> v3.1.0` returns the same SHA on all five (and `git ls-remote <remote> refs/heads/main`).
6. GitHub: `gh release create v3.1.0 --verify-tag --title ... --notes-file ~/.cache/llmctl-release/notes.md ../llmctl.tar.gz ../llmctl.zip SHA256SUMS` (the `#label` suffix is optional). GitLab: `glab release create v3.1.0 --name ... --notes-file ... --no-update <files...>` (file args are uploaded as assets; `--use-package-registry` is an alternative that puts files in the generic package registry). Use the script's per-forge idempotent state for retries.
7. Verify by re-downloading into fresh directories: `gh release download v3.1.0 --pattern '*' --dir D1` and `glab release download v3.1.0 --dir D2` (glab: `-n` glob; glab is a snap: use `$HOME` directories). Then `sha256sum -c SHA256SUMS` in both, `cmp` the files across forges, extract the archive and run its own test entry point (`bash tests/run_tests.sh` or `make test`, and `make validate`) per SC-011; record notes text equality (`gh release view --json body` vs `glab release view`).
8. Other three remotes (codeberg, gitflic, gitverse) receive the tag via step 5 only; releases there are not required by FR-054 (INFERRED).
9. Store all outputs in the evidence dir with the manifest.

## 5. Risks and open questions

Risks (measured unless marked):
- Swap is full (8.0/8.0 GiB) and `/` is 95% used (92 G free): model downloads and live runs risk host safety (FR-049); the already-running vision server must not be disturbed.
- Port collisions: 8443, 8445, 8080, 8200-8270 are listening; choose and document default ports against the measured table; 8095 appeared free.
- Chat servers: current behaviour binds all interfaces; the new decision-engine loopback rule (FR-073) was successfully validated in principle (loopback-bound server refused from both namespace types).
- Network namespace evidence cannot prove firewall/router behaviour; ufw rules unreadable without root.
- `unshare -rn` blocked by AppArmor (`apparmor_restrict_unprivileged_userns=1`); relying on it would fail.
- The pasta namespace is a trap (shares the host address); use bridge/slirp4netns.
- OpenSSL 3.5.5 CLI cannot offer TLS 1.0/1.1/weak ciphers; use Python/Node/Go clients.
- No shellcheck: `make lint` is a silent no-op here; no bash coverage tool; no coverage.py; no pytest (mutmut unusable without it).
- Release script publishes no assets and no checksums (existing v3.0.2 release has zero assets); tag creation is implicit; glab snap cannot read `/tmp`.
- No signing key (gpg has no secret key; no minisign/cosign): signatures would be an operator decision (minisign is the smallest option; cosign keyless needs an OIDC identity: INFERRED). Checksums alone prove integrity of the download, not authenticity.
- 3 of 7 agents not installed; their headless/CA behaviours above are partly UNVERIFIED (continue `requestOptions` keys, crush permission flags in `run`, aider bash capability); the agent LLM itself must be a model the host can run, which may make agent live tests slow or weak (INFERRED).
- `systemctl --user` reports `degraded` (cause not examined).
- `specs/009.../contracts/` is empty; no OpenAPI document exists for the endpoints.

Open questions for the operator:
1. Is a real second LAN machine (e.g. 192.168.1.87) available and may it be used for the FR-064/069 subset? Otherwise the podman bridge vantage (recorded as such) is used.
2. May we download single binaries (Hurl, shellcheck, testssl.sh) and `uv`-install coverage.py into a scratch venv? Each will be recorded as a need.
3. Signing: checksums only, or create a minisign/gpg key (key handling is the operator's)?
4. Which default port range for decision endpoints (8095 vs others)?
5. For the cloud-reachability claim (FR-065): is any external vantage available (another network, phone hotspot)? Otherwise "not exercised: no external vantage".
6. Install the three missing agents on this host (aider via pip/uv, continue `cn` via its installer, cline via npm) for FR-048?

## 6. Sources

Web (searched or fetched 2026-10-07):
- Hurl manual: https://hurl.dev/docs/manual.html ; man page: https://man.archlinux.org/man/hurl.1.en
- Schemathesis (PyPI): https://pypi.org/project/schemathesis/3.38.2
- testssl.sh / sslyze / sslscan comparison: https://dev.to/coroner/cryptolyzer-vs-sslyze-vs-testsslsh-a-practical-comparison-eo9 ; https://www.pistack.xyz/posts/2026-04-22-testssl-vs-sslyze-vs-sslscan-self-hosted-ssl-tls-scanning-guide-2026/
- OpenSSL s_client protocol testing: https://www.feistyduck.com/library/openssl-cookbook/online/testing-with-openssl/testing-protocol-support.html ; https://www.simplified.guide/_export/xhtml/openssl/tls-version-test
- Slowloris / slow POST: https://github.com/gkbrk/slowloris ; https://nmap.org/svn/scripts/http-slowloris.nse ; https://github.com/jatj/sdn_onos/blob/master/SLOW_HTTP_ATTACKS.md
- Bash coverage via PS4/xtrace and kcov: https://manpath.be/f36/1/kcov ; https://www.libhunt.com/r/bashcov
- coverage.py subprocess measurement: https://coverage.readthedocs.io/en/6.5.0/subprocess.html
- mutmut: https://mutmut.readthedocs.io ; https://github.com/boxed/mutmut
- gh release create: https://cli.github.com/manual/gh_release_create ; gh release download: https://cli.github.com/manual/gh_release_download
- glab release create: https://docs.gitlab.com/cli/release/create/ ; download: https://docs.gitlab.com/cli/release/download/ ; upload: https://docs.gitlab.com/cli/release/upload ; GitLab release fields: https://docs.gitlab.com/ee/user/project/releases/release_fields.html
- Signing tools comparison: https://oneuptime.com/blog/post/2026-01-07-go-code-signing/markdown ; https://vyos.dev/T2108
- Aider scripting: https://aider.chat/docs/scripting.html
- Continue CLI guide (mirror): https://gitea.varghacsongor.hu/GithubMirror/continue/src/commit/97e9bc1b47dc98a7717c423d8219efe867fe4fb6/docs/guides/cli.mdx
- Cline CLI: https://docs.cline.bot/cline-cli/cli-reference ; https://docs.cline.bot/cline-cli
- opencode providers/TLS: https://opencode.ai/v2/docs/providers ; https://git.joshthomas.dev/mirrors/opencode/commit/0c8f4475e9f798ae1265ceae6e54647d48cdbe7a
- Crush custom providers: https://mintlify.com/charmbracelet/crush/advanced/custom-providers ; https://next-docs.charm.land/crush/configuration/providers.html
- Node enterprise network config / NODE_EXTRA_CA_CERTS: https://nodejs.org/en/learn/http/enterprise-network-configuration ; Claude Code proxy: https://developertoolkit.ai/en/claude-code/advanced-techniques/proxy-configuration/
- git push semantics: https://www.kernel.org/pub/software/scm/git/docs/git-push.html
- Golden files / flaky quarantine: https://yuantest-playwright.readthedocs.io/guides/flaky-management/ ; https://www.testmuai.com/learning-hub/quarantine-test/ ; https://sharedcontext.ai/skills/external/mracal/vibe-golden-file-testing
- Tamper-evident JSONL hash chains: https://huggingface.co/Arcaeon/arcaeon-ledger ; https://pypi.org/project/sasana/

Local: `scripts/release/create_release.sh`, `preflight_submodules.sh`, `build_archive.sh`, `docs/release-process.md`, `docs/integrations.md`, `Makefile`, `tests/run_tests.sh`, `upstreams/*.sh`, spec FR-038..049, 053..056, 064, 069, 070, SC-007/008/011/013; candidate tree `/home/milosvasic/Projects/jev/llmctl/llmctl/lib/{decide_gateway,onnx_server}.py`.
