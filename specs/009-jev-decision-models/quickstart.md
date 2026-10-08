# Quickstart — validation scenarios

**Feature**: 009-jev-decision-models | **Date**: 2026-10-07 | **Contracts**: [contracts/](contracts/) | **Data model**: [data-model.md](data-model.md)

This is the **run guide that proves the feature works end to end**. Each scenario names its prerequisites, the commands (final CLI names from `contracts/cli.md`), the expected outcome and the evidence record it must produce (`contracts/evidence-schema.md`). It contains no implementation; implementation lives in `tasks.md`. Commands are written for this host (Linux; rootless podman available). A scenario that cannot run records `not-exercised` with the reason – it is never skipped silently.

Conventions: `RUN=docs/qa/009-jev-decision-models/$(date -u +%Y%m%dT%H%M%SZ)`; every command is wrapped by the evidence writer; the key is read from the environment/`.env` and never printed. `GW=https://127.0.0.1:8095`; `CA=$HOME/llmctl/cert/ca/ca.crt`.

| # | Scenario | Proves | Spec |
|---|---|---|---|
| Q1 | Baseline and port differential | the merge lost nothing; +5 suites pass, same environment failures | FR-044 |
| Q2 | First start on a clean `LLMCTL_HOME` | key + CA + leaf created, owner-only, reused on restart, one generation under 5 simultaneous starters | FR-058, 059, 066 |
| Q3 | First typed answers | CLI returns valid noul / choice / score from a real model | US1, FR-011 |
| Q4 | Determinism | 20 identical repeats are byte-identical in deterministic mode | FR-010, 074, SC-001 |
| Q5 | Pins match the real source | size + sha256 + revision of all shipped files match huggingface.co; a corrupted file is rejected | FR-003, SC-002 |
| Q6 | Real-model golden run | typed answers from each profile that fits; accuracy ± interval vs baseline; letter mass; order-flip rate | US3, FR-076, 080, SC-003 |
| Q7 | LAN/second-vantage reachability | gateway reachable and TLS-trusted from a separate network namespace; engine ports refused | FR-064, 073, SC-013 |
| Q8 | Auth and transport negatives | 401 matrix; name mismatch, expired, untrusted, altered, plain-HTTP-to-TLS, legacy protocol | FR-019, 070 |
| Q9 | Hostile traffic | malformed / oversized / slow / concurrent requests; backend killed mid-request; service stays up | FR-022, 078, SC-006 |
| Q10 | Capacity equals admission | `plan --json` slots equal what the scheduler admits; refusal prints numbers; second instance works | FR-027–029, SC-010 |
| Q11 | Client-by-call matrix | every inventory case × every client × both vantages | FR-069, SC-013 |
| Q12 | Agents live | each of the 7 agents makes a decision call; gateway log proves it | FR-048, SC-007 |
| Q13 | Secrets hygiene | key never in argv, logs, evidence, docs, archives; scan proves it can find a decoy | FR-020, 084, SC-005, 014 |
| Q14 | Existing chat servers unchanged | chat request without a key still succeeds; planner changes are the documented ones | Clar. 2, SC-012 |
| Q15 | Documentation audit | zero code/doc mismatches; every doc reachable from README | FR-050, SC-009 |
| Q16 | Release verification | identical tag/notes/assets on both forges; re-download checksums match; archive runs its own tests | FR-054, SC-011, 014 |

---

## Q1 Baseline and port differential

Prereq: HEAD is `a9ebefe` (`git rev-parse HEAD`); a hardlinked backup of `.git` exists.
```
git rev-parse HEAD
bash tests/run_tests.sh | tee $RUN/baseline-head.txt          # in a scratch clone; record the 2 environment failures
# after the port on the scratch branch:
bash tests/run_tests.sh | tee $RUN/after-port.txt
```
Expected: baseline = 36 pass + 2 environmental failures (constitution inheritance, engine CPU regression) in the scratch clone; after port = +5 passing suites, the same 2 failures. In the real checkout all 38 existing files must pass. Evidence: both captures, `diff` of the pass lists.

## Q2 First start on a clean `LLMCTL_HOME`

Prereq: `export LLMCTL_HOME=$(mktemp -d)`; `unset LLMCTL_API_KEY`; a ready decision instance (or the gateway test backend in the unit tier only).
```
llmctl decide serve --foreground &        # prints bind, HTTPS URL, key location, CA fingerprint; never the key
stat -c '%a' $LLMCTL_HOME/.env $LLMCTL_HOME/cert/ca/ca.key $LLMCTL_HOME/cert/current/leaf.key   # expect 600 600 600
stat -c '%a' $LLMCTL_HOME/cert $LLMCTL_HOME/cert/ca/ca.crt                                       # expect 700 644
llmctl key doctor ; llmctl cert show
# restart: same fingerprints
# race: start 5 processes at once; exactly 1 CA/leaf/key generation logged, 4 "reuse"
```
Expected: owner-only modes; second start reuses key and certificate; env value wins over `.env` and `key doctor` reports the shadowing; blank `LLMCTL_API_KEY=` ⇒ exit 4; unwritable home ⇒ failed start, nothing left listening. Evidence: stat output, generation log lines, fingerprints before/after restart.

## Q3 First typed answers (real model)

Prereq: `llmctl models download decide-tiny` verified; gateway running.
```
llmctl decide ask --profile decide-tiny --type noul   --state "Disk usage is 97% and rising" --instructions "Is immediate action needed?" --json
llmctl decide ask --profile decide-tiny --type choice --state-file tests/fixtures/ticket1.txt --criteria '{"billing":"…","bug":"…","other":"…"}' --json
llmctl decide ask --profile decide-tiny --type score  --state-file tests/fixtures/review1.txt --criteria '["poor","ok","good"]' --json
```
Expected: valid JSON; `noul` ∈ [0,1] with no confidence field; choice probabilities sum to 1 (±1e-6), `confidence` ∈ [0,1]; score within [0, n−1]; `evidence` shows the profile and unquantised latency; exit 0. Evidence class `real-model`.

## Q4 Determinism

```
for i in $(seq 20); do llmctl decide ask … --json | sha256sum; done | sort | uniq -c    # expect a single line with count 20
```
Expected: one distinct hash in deterministic mode; in `throughput` mode the response evidence says so and no byte-identity claim is made.

## Q5 Pins match the real source

```
llmctl models download <profile> --from huggingface.co        # never the mirror
llmctl models verify <profile>                                # size + sha256 + revision
# negative: flip one byte in a copy; verify must exit non-zero and leave the final path untouched
```
Expected: 6/6 shipped profiles verified; the mutated file rejected; disk-space check precedes each download (host has ~92 GB free at 95% use); evidence log under `$LLMCTL_VERIFY_DIR`.

## Q6 Real-model golden run

Prereq: golden question set (≥ 30 questions over the three types, hash-pinned, seeded) and, for imbalance, items with a majority class.
```
llmctl decide calibrate --profile <p> --labels tests/fixtures/golden/<p>.csv --report $RUN/<p>-report.json
llmctl decide probe-order --profile <p> --questions tests/fixtures/golden/order.jsonl
```
Expected per profile that fits: all answers well-formed; accuracy with sample size, interval and baseline from the same tool, exceeds baseline; letter mass recorded (decoder profiles); option-order flip rate recorded; encoder RSS idle/peak/after-N recorded; profiles that cannot fit list the exact numbers and `not-exercised`. Optional: JevBench public tier through its `typesafe` adapter pointed at the gateway, labelled "public tier, contamination possible".

## Q7 Second-vantage reachability

Prereq: rootless podman bridge network (own address `10.88.0.x`), client image with curl and Python (already local); optionally slirp4netns cross-check. **Not** pasta, **not** `unshare -rn`.
```
LAN=$(hostname -I | awk '{print $1}')
podman run --rm --network=bridge -v $CA_PUBLIC:/ca.crt:ro <image> curl --cacert /ca.crt https://$LAN:8095/healthz
podman run … curl --cacert /ca.crt -H "Authorization: Bearer $LLMCTL_API_KEY" https://$LAN:8095/v1/models
podman run … curl http://$LAN:<engine-port>/health          # expect refused (FR-073)
```
Expected: gateway answers over HTTPS with the CA trusted; engine port refused from the container; the evidence states the vantage and that it does **not** prove NIC/router/firewall/ISP behaviour. The CA copy used in the container is the public 0644 export.

## Q8 Auth and transport negatives

```
# EP-009/010/031/032/051: no key / wrong key → 401 with generic body and WWW-Authenticate
# name not in SAN:   curl --cacert $CA --resolve other.example:8095:127.0.0.1 https://other.example:8095/   → (60) no alternative subject name
# expired:           serve a leaf issued with -not_after in the past → (60) certificate has expired
# untrusted:         client without the CA → per-client verify error (curl 60, Python CERTIFICATE_VERIFY_FAILED, Node UNABLE_TO_VERIFY_LEAF_SIGNATURE, Go unknown authority)
# altered:           load a cert with another key → KEY_VALUES_MISMATCH at start (start refused)
# plain HTTP:        curl -m 5 http://127.0.0.1:8095/ → (56) connection reset
# legacy protocol:   Python/Node/Go client offering TLS 1.0/1.1 → handshake failure (openssl 3.5 s_client cannot offer these)
```
Expected: each case behaves as documented; evidence per case id in `endpoint-inventory.tsv`.

## Q9 Hostile traffic

```
python3 tests/stress/slowclient.py --target $GW --mode drip --count 10        # connections closed at the read deadline
python3 tests/stress/slowclient.py --mode idle-tcp --count 10                  # real requests still served (< 100 ms added)
oversized body (> LLMCTL_DECIDE_MAX_BODY) → 413 before read;  JSON list body → 400;  burst of bad keys → 429 + Retry-After
kill -9 <backend pid> mid-request → 502 backend_failed, gateway stays up, registry marks the instance degraded and recovers
```
Expected: valid requests keep being answered; no gateway exit or hang; no unbounded thread growth (thread count sampled before/after).

## Q10 Capacity equals admission

```
llmctl plan --json | jq '.decision_instances'
llmctl decide scale decide-tiny <N from the report>      # succeeds
llmctl decide scale decide-tiny <N+1>                    # exit 3 with needed-vs-available numbers
```
Expected: the reported `total_decision_slots` equals the number the scheduler really admitted; the refusal changes nothing on the host; the already-running vision server is untouched.

## Q11 Client-by-call matrix

```
tests/matrix/run.sh --inventory specs/009-jev-decision-models/contracts/endpoint-inventory.tsv \
   --clients curl,python-urllib,python-requests,node-fetch,go-nethttp,chromium,llmctl-cli,typesafe-sdk-py,typesafe-sdk-js \
   --vantages host,podman-bridge
```
Expected: one evidence record per (case × client × vantage); cells either `pass` or `not-exercised` with a reason; **zero missing cells**; SDK rows record which CA-trust mechanism worked (custom `http_client`/`fetch`, or env var) or that none did.

## Q12 Agents live

For each of opencode, pi, crush, Claude Code, aider, continue, Cline: configure per its docs page, run its documented non-interactive command with a prompt that makes it call the gateway (via its shell tool with `curl --cacert`, or the integration kit), then fetch the gateway request log entry for that time window.
Expected per agent: `pass` only when the gateway's independent log shows the matching request; otherwise `not-exercised` (not installable / cannot run headless / no usable model) with the exact reason. Installing aider, continue and Cline uses their official installers and is recorded.

## Q13 Secrets hygiene

```
KEY=$(llmctl key show --yes-print)            # read at test time only, never echoed
grep -rFl -- "$KEY" $RUN docs/ specs/ ~/.local/state/llmctl/logs 2>/dev/null    # expect no output
ps -eo args | grep -F -- "$KEY"                # expect no output;  /proc/*/environ of other uids unreadable
# control needle: plant a decoy key in a scratch file; the same scan path must find it, otherwise the scan is blind → run fails
tests/test_archive_secrets.sh                  # plants .env, cert/*.key, a key string; builds both archives; finds none
llmctl key export --file /tmp/rc-test ; llmctl key export --file /tmp/rc-test     # second run: "already present", count stays 1
```

## Q14 Existing chat servers unchanged

A chat request to a running chat profile **without** a key still succeeds; `llmctl plan` output differences versus the previous release are exactly the documented set (decision profiles listed under their own capability; `recommended`/co-residency changes explained in the changelog).

## Q15 Documentation audit

```
tests/docs_audit.sh        # generated test counts vs ls; ports vs catalog; commands vs bin/llmctl; env vars vs contracts; bind statements vs code; links; orphan docs
```
Expected: zero findings; any "127.0.0.1 only" claim for chat servers is gone; new docs reachable from README.

## Q16 Release verification

```
bash scripts/release/create_release.sh --dry-run v3.1.0
# after publishing:
gh release download v3.1.0 --dir $RUN/gh ;  glab release download v3.1.0 --dir $HOME/.cache/llmctl-release/gl
( cd $RUN/gh && sha256sum -c SHA256SUMS ) ; cmp the archives across forges ; compare notes text
tar -xzf $RUN/gh/llmctl.tar.gz -C $(mktemp -d) && run its own test entry point
git ls-remote --tags --refs <each of 5 remotes> v3.1.0      # same sha everywhere
```
Expected: identical assets/checksums/notes on both forges; archive's own suite passes; SBOM present; assurance statement matches the evidence (build L1, unsigned unless OD-4).

## Q17 Dynamic ports and discovery (FR-088..091, SC-015)

```bash
LLMCTL_PORT_STRATEGY=dynamic llmctl start decide-tiny            # port allocated from LLMCTL_PORT_RANGE, bind-tested
llmctl discover --json                                            # registry rows == live processes
python3 - <<'PY'
# occupy a default port, start three instances, kill one, assert the registry and gateway routing follow within one health interval
PY
```
Expected: three distinct free ports, rows equal live processes, killed instance leaves routing within one health interval.
