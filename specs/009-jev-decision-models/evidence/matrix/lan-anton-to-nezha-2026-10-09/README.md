# T058n: client-by-call matrix, anton (LAN) -> persistent gateway on nezha (2026-10-09)

Vantage `anton-lan`; target `https://192.168.1.90:8095` (TLS, private CA "llmctl local CA (nezha)", SANs nezha, nezha.local, 192.168.1.90 + others).
Only the public CA cert was copied (`ssh nezha.local 'cat ~/llmctl/cert/ca/ca.crt'`, sha256 fp 57:B2:5A:F6:...:62:3C). The access key was read on nezha over ssh into a 0600 temp file, passed via `LLMCTL_API_KEY` env / header file, never on a command line, and shredded; a grep of this directory for the key value returns nothing. No code was changed. Sequential, concurrency 1.

## Commands (no secrets)
    python3 -B tests/matrix/run.py --base-url https://192.168.1.90:8095 --cacert ca.crt --server-cert ca.crt \
      --class-override real-component --run-dir run            # full matrix, 6 clients (dirs run/, run-auth-<client>/, run-ep050-N/ are scoped re-runs)
    python3 per_profile_driver.py --base https://192.168.1.90:8095 --cacert ca.crt --spki-cert ca.crt --out per-profile-results.json
      # supplementary: reuses matrix adapters + validators, sends explicit `model` per profile (run.py sends none)
    negative-tls-and-transport.txt: openssl s_client / curl / python ssl / node / go negative cases (see file)
all under `~/.local/bin/bounded-run -m 3G -t 400 -T 1200 -q --`.

## Results
* Per-profile, explicit model, 4 profiles x 5 clients (curl, python-urllib, python-requests, node-fetch, go-nethttp) x 3 question types (noul/choice/score): **60/60 pass** (strict validators except the additive `maturity` answer label, which tests/matrix does not know; model echo checked). Latency median/min/max ms: decide-nli 273/174/403, decide-2b 1955/1602/2145, decide-pro 5587/4627/5786, decide-max 9589/7805/9908 (all under the gateway 120 s timeout). See `per-client-verdicts.json`, `results.json`.
* Authenticated healthz/models/systemone-style subset per client (`run-auth-*`): curl, go, node-fetch, python-requests, python-urllib 6/6 pass each; chromium 4 pass + 2 not-exercised (class browser-non-get: CLI browser issues GET navigations only, FR-069).
* Full matrix (`run/`, 156 cells): 85 pass / 56 fail / 15 not-exercised (all chromium, browser-non-get). Harness verdict FAIL, all 56 failures classified below; none is a gateway wrong-answer.
* TLS (`negative-tls-and-transport.txt`): server chain verifies with CA (TLS1.3); wrong CA refused by curl/python/go (node untested, see defect 4); no CA/system trust refused; hostname not in SANs refused (curl, openssl); no key / wrong key => 401 (+ WWW-Authenticate Bearer) on /v1/models, /metrics, unknown path; plain HTTP to TLS port => connection reset; TLS1.0/1.1 refused, TLS1.2/1.3 accepted; engine ports 8080/8081/8094/8096-8098 refused from anton (loopback-only on nezha, control confirmed).
* Not exercised: Go `llmctl-decide` client (cross-built binary could not resolve nezha.local; IP use not run in this respawn: not exercised), llmctl-cli and 7 agent adapters (pending adapters in the harness), SDK adapters (`--with-sdk` not used), chromium non-GET, nezha firewall rules (sudo needs password; only listen sockets recorded), second vantage beyond anton.

## Defects / classification (root causes UNCONFIRMED unless stated)
1. 20 cells `POST /v1/systemone` 503 `not_ready` in the full run: run.py sends no `model`; the gateway has no default model. With an explicit model every profile answers (60/60). Cause of 503-vs-422 for a missing model UNCONFIRMED (gateway behaviour or readiness of the unnamed default); harness gap either way.
2. 24 cells 429 `rate_limited` where 401 was expected (unauth GET /v1/models, /metrics, unknown path, POST): failed-auth burst limiter tripped by the matrix' own repeated unauthenticated calls (documented: "429 rate_limited (failed-auth bursts only)"). Expected consequence of the matrix volume, not a defect; Retry-After 56 s seen.
3. 5 cells GET /v1/models: model entries carry additive keys (`maturity`, `maturity`-adjacent fields, `experimental_types`) the harness schema in tests/matrix does not list; 1 cell non-JSON body (cause UNCONFIRMED, probably a 429/503 body masking it).
4. node-fetch GET /metrics fails 3/3 (`run-ep050-*`): CONFIRMED harness-adapter defect, not gateway. `tests/matrix/clients/node_https.mjs` calls `process.exit(0)` right after `console.log` of the base64 body; when stdout is a pipe Node truncates at 8192 bytes (re-run: piped 8192 bytes, to file 26260 bytes; curl body 19463 bytes) so the base64 is invalid. Affects any response > ~6 KB through node. Gateway body is correct.
5. Node negative-TLS probe with an IP host threw ERR_INVALID_ARG_VALUE (servername set to an IP): probe-script issue, node wrong-CA case not shown.
