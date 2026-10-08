# Independent adversarial review #1 — Spec Kit planning artefacts, feature 009

| Field | Value |
|---|---|
| Reviewed | spec.md, plan.md, research.md, data-model.md, quickstart.md, traceability.md, contracts/*, checklists/requirements.md, source-findings.md, research/* (12 files) |
| Reviewer | independent subagent (did not author the artefacts); read-only except this file |
| Date | 2026-10-07 |
| Method | Read every artefact; ran read-only commands against `/home/milosvasic/Projects/llmctl` (HEAD `a9ebefe`), the candidate tree `/home/milosvasic/Projects/jev/llmctl/llmctl`, the toolkit/constitution snapshots, and the live host (`ss`, `free`, `df`, `nvidia-smi`, `loginctl`, `ldd`). Every "not found" result below carries a control search that proves the instrument can find things. Inferences are marked INFERRED. |
| Verdict | **NO-GO** for `/speckit-tasks` until the 3 BLOCKING findings are resolved (or turned into recorded operator decisions); the IMPORTANT ones should be fixed in the same pass because tasks would otherwise inherit contradictory tests. |

Counts: **BLOCKING 3 · IMPORTANT 26 · MINOR 22** (R-037 is a no-action confirmation counted under MINOR).

---

## 1. Internal contradictions (cross-document probes)

**R-001 · IMPORTANT · spec.md:297 (FR-075) vs contracts/openapi.yaml:52-60,371-373 vs contracts/endpoint-inventory.tsv:23,33,39 vs data-model.md:77**
What: FR-075 says error responses use "status 400, 401, 422, 429, 503 or 529" and that the gateway reproduces the hosted shapes "exactly". The contracts add 405 (method), 413 (body cap), 404 (EP-060 unknown path) and 502 (`readout_failed`, `backend_failed`). data-model §3 lists only the FR-075 set. Also the hosted service answers `400 Too many choices` at 256 options (research/web-jev-api-and-bench.md:62,137) while openapi/EP-015 return 422.
Why: `/speckit-tasks` will generate contract tests from both sources; one of them must fail. "Exactly" is untestable as written.
Fix: Amend FR-075 to "hosted statuses where the hosted service defines them, plus the llmctl-defined set {404, 405, 413, 502} listed in openapi.yaml"; decide 400 vs 422 for >255 options explicitly and record the deviation (or match hosted 400).

**R-002 · IMPORTANT · spec.md:300 (FR-078) vs research.md:43 (RD-21) vs plan.md:20 vs contracts/env-vars.md:40 vs research/web-jev-api-and-bench.md:137**
What: Saturation status is 529 in FR-078/env-vars/EP-020, but "503/429 + Retry-After when full" in RD-21, "answers or sheds (429/503 + retry hint)" in the plan's Performance Goals, and "429 … on saturation, 529 on overload" in the API research.
Why: Four documents, three mappings; clients (hosted SDK) treat these differently.
Fix: One table (status → condition → retryable → Retry-After) in openapi.yaml; make RD-21 and plan.md:20 cite it.

**R-003 · IMPORTANT · spec.md:270 (FR-018) vs contracts/env-vars.md:32**
What: FR-018 says "the existing bind-address overrides (global and per profile) [are] available to restrict" the gateway. env-vars.md introduces a new `LLMCTL_DECIDE_BIND` and states `LLMCTL_BIND_HOST[_<PROFILE>]` apply to **chat profiles only**.
Why: Direct contradiction on which variable restricts the network-facing surface — a security-relevant control.
Fix: Pick one; if `LLMCTL_DECIDE_BIND` stays, amend FR-018 and add a test that `LLMCTL_BIND_HOST=127.0.0.1` does (or explicitly does not) affect the gateway, documented either way.

**R-004 · IMPORTANT · spec.md:29 (Clarification 1), spec.md:281 (FR-059), repo `.env.example:1-2` vs plan.md:16, plan.md:209 (OD-8), contracts/env-vars.md:11-12, data-model.md:84**
What: The operator said the key is persisted "in llmctl's `.env` file". In this repository that is the repo-root `.env` (`.env.example`: "Copy to .env … .env is gitignored"; `.gitignore:2`). The plan moves it to `$HOME/llmctl/.env` and labels this "operator-requested" (plan.md:16, OD-8); the operator only requested the **certificate** directory (`llmctl/cert`, Clarification 4). FR-059 ("`.env` MUST be gitignored") only makes sense for the repo-root file.
Why: Mislabelled provenance of an operator decision; produces two `.env` files (HF_TOKEN in one, the key in the other); see R-020 for the security consequence.
Fix: Make the `.env` location an explicit open decision (OD) with both options, or follow the literal clarification (repo `.env` / documented install-time path) and keep only `cert/` under `$HOME/llmctl`.

**R-005 · IMPORTANT · spec.md:78 (US2 AS2) vs research.md:18 (RD-06) vs openapi.yaml:8-10**
What: US2 AS2 still says a hosted-Jev client works "with only the base address changed". RD-06 established this is false (key + CA trust also needed) and openapi's description says so. The spec's planning amendments (spec.md:35-43) did not amend AS2.
Why: An acceptance scenario that the plan itself proves cannot pass.
Fix: Reword AS2: "with the base address, the access key and CA trust changed (exact per-SDK steps from P6)".

**R-006 · IMPORTANT · contracts/env-vars.md:36, openapi.yaml:46-48, endpoint-inventory.tsv:9 (EP-008) vs data-model.md:60 vs research/web-jev-api-and-bench.md:64,105 vs spec.md:212**
What: Decoder profiles shorten over-long state (head+tail) and answer 200 with header `x-llmctl-decide-truncated`; data-model §3 says over-limit → 422; the hosted service and Kev reject over-limit (never silent truncation). Hosted SDKs validate the body and do not surface custom headers, so an SDK user gets an answer on a truncated state with no visible signal.
Why: Contradiction between artefacts and with FR-075 "exactly"; the edge case "the response must say so" is not met for SDK clients.
Fix: Default to 422 (hosted behaviour); make head+tail truncation opt-in (request field or env), and when used put the flag in the JSON body too.

**R-007 · IMPORTANT · spec.md:291 (FR-069), spec.md:385 (SC-013) vs quickstart.md:136 (Q11) vs plan.md:159 (P6)**
What: FR-069/SC-013 require the seven agents (where they can make HTTP calls) as matrix columns from both vantages. The Q11 runner's client list contains no agent; the plan's P6 list has no agents either (agents appear only in P8 as a single decision call).
Why: The completeness check (evidence-schema rule 3) would either fail or the agent columns silently disappear.
Fix: Either add agent columns to Q11 with a defined subset of cases, or amend FR-069/SC-013 to "agents: one authenticated success call + one 401 call each (P8)".

**R-008 · MINOR · spec.md:271 (FR-019 "the minimal health probe") vs openapi.yaml:75-119**
Two unauthenticated probes exist (`/healthz`, `/readyz`). Also EP-041 expects 405 on `POST /healthz` but openapi declares no 405 for `/healthz` or `/readyz`. Fix: plural in FR-019; add 405 to both probe paths.

**R-009 · MINOR · spec.md:279 (FR-057 "exactly one credential variable") vs env-vars.md:10, data-model.md:89**
`LLMCTL_API_KEY_PREVIOUS` is a second credential variable. Fix: store the grace key in `.env` under a non-variable name, or amend FR-057.

**R-010 · MINOR · spec.md:259 (FR-010) vs spec.md:296 (FR-074)**
FR-010 promises identical answers unconditionally; FR-074/RD-17 scope byte-identity to deterministic mode. FR-010 was not amended. Fix: add "in deterministic mode (FR-074)".

**R-011 · MINOR · contracts/cli.md:35 vs contracts/env-vars.md**
cli.md references a "documented last-resort env override" that disables verification; no such variable is in env-vars.md, so the SC-009 audit (env vars vs contracts) would flag it, and FR-068 makes it sensitive. Fix: name it in env-vars.md with the warning, or delete the sentence.

**R-012 · MINOR · checklists/requirements.md:28 vs spec.md**
Checklist says "73 requirements … 13 success criteria"; spec has FR-001…FR-086 (86) and SC-001…SC-014 (14). Stale after amendments. Fix: re-run validation.

---

## 2. Unsupported or wrong claims (25+ checked)

Checked TRUE (with the command used): HEAD `a9ebefe` (`git rev-parse`); VERSION 3.0.2; 38 `tests/test_*.sh`; 10 chat profiles in `models/catalog.json`; llama.cpp pin tag b10969 at `391fac16`, binary reports `0.4.1-dev (build 10969)`; `LLAMA_OPENSSL:BOOL=ON` and `libssl.so.3` linked (RD-32); `--api-key-file` exists at `common/arg.cpp:3490` of the pin (RD-33); no `systemone` in the pinned tree; `lib/common.sh:74` defaults `0.0.0.0`; `CLAUDE.md:32` and `.specify/memory/constitution.md:188,217` claim 127.0.0.1; project constitution v2.0.0; `Jev.md` 3,715 lines; v70 snapshot has 0 gate scripts vs 286 in our pin; pinned constitution has no §11.4.276–284 (control: `### §11.4.275` found); inventory 455/26/33(29+4 pyc)/5 = 519; every MODIFIED/NEW-IN-JEV path appears in merge-plan.md or jev-llmctl-new-files.md (control: `lib/decide.sh` found 3+5 times); coverage files 309 rows (124/105/80); N-01…N-29 present; candidate pins for decide-tiny (rev `edf37c26…`, 529,296,864 B, sha `0a19bc29…`) match catalog-schema.md example; 5 distinct forges behind 7 remote names; `~/.bashrc` mode 644; Python 3.14.4, OpenSSL 3.5.5; aider/cline absent, opencode/pi/crush/claude present; D-01 (`onnx_server.py:253,256` `[:MAX_LEN]`), D-05 (`decide.sh:840-866` kills pidfile PID unverified), D-03 argv key (`decide.sh:886-890`, `scheduler.sh:427-428`); host linger = yes (so the "linger" baseline failure is scratch-env only, consistent with merge-plan.md:134).

Found FALSE / unsupported / stale:

**R-013 · MINOR · source-findings.md:18** — `Prompt.md` "597-line"; `wc -l` = 596 (file ends with a newline). Fix the number.

**R-014 · MINOR · plan.md:56, traceability.md:43** — Disposition counts "72 ADOPT-AFTER-VERIFICATION … 3 split rows". A classifier on the leading keyword (stripping `**`) gives 41 / **73** / 103 / 26 / 64 / **2** unclassifiable (J3-027, J3-073). The total (309) agrees; the split is classifier-dependent and not reproducible from the text. Fix: state the counting rule, or tag split rows explicitly so `tests/coverage_rows.sh` can count them.

**R-015 · IMPORTANT · source-findings.md:27 (D-03)** — Evidence cites `lib/service_macos.sh`, but that file is **IDENTICAL** to HEAD in the inventory and contains no `API_KEY`/`decide` text (grep: 0 hits; control: `LLMCTL_DECIDE_API_KEY` found at candidate `lib/scheduler.sh:427`). The macOS claim is unsupported, and the real gap is the opposite: the candidate has **no** macOS support for decision services at all (relevant to FR-031). Fix: remove the citation; add a finding "no launchd path for decision profiles/gateway".

**R-016 · IMPORTANT · source-findings.md:53 (D-30)** — Rated M / "UNVERIFIED". Reading `scripts/release/build_archive.sh` (body: `tar --exclude='*/build/*' -czf … -C "${parent}" "${base}"`; `zip -qr … -x "*/build/*"`) confirms by reading that it archives the **whole working tree**, including untracked/ignored files (`.env`) and `.git/`. Fix: re-rate H, status CONFIRMED-by-reading; RED test still required (FR-040).

**R-017 · MINOR · source-findings.md:5 and all D-rows "UNREPRODUCED"** vs research/jev-llmctl-new-files.md:393 ("D-08 reproduced for both servers") and plan.md:8 ("several reproduced"). The register is stale. Fix: update statuses from the new-files cross-check.

**R-018 · MINOR · plan.md:21, spec.md:396** — "~4.8 GiB [VRAM] free": `nvidia-smi` now reports 4,054 MiB free; disk 90 GB free (plan: ~92). Time-varying facts presented as constants. Fix: phrase as "at planning time; re-measured before every live step" (P4 should log it).

**R-019 · IMPORTANT · plan.md:21, plan.md:211 (OD-10), source-findings.md:112** — Port facts incomplete. Live `ss -ltnp`: **8099 is held by `aicur`** — the candidate's `decide-max` catalog port; **8080 is held by `helixcode`** (catalog `fast`), **8087 by `workshop-server`** (catalog `ws-moe-30b`), 8082 by `llama-server` (the running vision profile); 8110/8111 are in use, so "free 8103+ range" is not accurate. The plan keeps the six candidate ports (catalog-schema.md example keeps 8092) and never reassigns `decide-max`; FR-047 live chat regression on catalog ports will collide on 8080/8087.
Fix: Reassign `decide-max` (or document the override used), list every collision with catalog ports in P4/P6 prerequisites, and record which `LLMCTL_PORT_<PROFILE>` overrides the live runs use.

Not verifiable here (UNCONFIRMED, not refuted): llama.cpp PR #29818 / first tag b11361 (local tags stop at b11100); hosted-API facts (255 options, 2–10 levels, 10 s SDK timeout) — cited to vendor docs in research/web-jev-api-and-bench.md but not re-fetched by this reviewer.

---

## 3. Security design flaws

**R-020 · BLOCKING · plan.md:16, contracts/env-vars.md:11, data-model.md:95-103, README.md:22-23, docs/quickstart.md:14-15, .gitignore, scripts/release/build_archive.sh**
What: Default `LLMCTL_HOME=$HOME/llmctl`. The README/quickstart install instruction is `git clone --recursive <url> llmctl` — run from the home directory this makes **the git working tree itself `$HOME/llmctl`**. Then `cert/ca/ca.key`, `cert/v-*/leaf.key` and `.env` land inside the repository. `.gitignore` covers `.env` but has **no `cert/` rule** (grep: 0 hits; control: `.env` found), so `git add -A` would commit the CA private key; and the archive builder tars the whole tree including untracked files (R-016), so `make archive`/release assets would ship the CA key and `.env`.
Why: Credential leak path via both VCS and release assets, created by the plan's own default (INFERRED for the user's clone location, but it is the documented one).
Fix: Choose a default that cannot coincide with the clone dir (e.g. `${XDG_CONFIG_HOME}/llmctl` or `~/.llmctl`, which the operator must approve since they named `llmctl/cert`), and/or refuse to start when `LLMCTL_HOME` is inside a git work tree; add `cert/` to `.gitignore`; make the archive builder use an allow-list (tracked files + submodule content) not the raw tree; extend the SC-014 planted-secret test to plant `cert/ca/ca.key` inside the repo.

**R-021 · BLOCKING · research.md:51 (RD-24 "Optional name constraints (off by default)"), research.md:63 (RD-36 "OS-store install is the lowest-friction universal option"), plan.md:222,225; research/web-security-tls-exposure.md:60,275**
What: The default design is a per-host root CA with **no name constraints**, whose private key sits 0600 on a developer host readable by every process of that user — including the seven coding agents the feature integrates (which execute model-chosen shell commands and are prompt-injectable). The plan and research recommend installing that CA in the OS trust store on clients.
Why: Anyone who reads `ca.key` (malware, a prompt-injected agent, a backup, R-020's archive) can mint a certificate for *any* domain trusted system-wide on every machine that installed the CA — a MITM capability far beyond the feature. The research itself verified name constraints work in openssl, curl, Python and Node (web-security-tls-exposure.md:60); the stated reason for defaulting off (operators must list extra names) is an operability preference, not a blocker.
Fix: Name constraints ON by default (permitted: the host's names/`.local`/`localhost`, loopback, RFC 1918/ULA ranges, plus `LLMCTL_TLS_SAN` extras; regenerate the CA when extras change, documented); recommend per-client CA bundles first and OS-store install only with constraints on; offer the "offline CA key" mode prominently; add an OD for the operator.

**R-022 · IMPORTANT · contracts/env-vars.md:39-42, research.md:43 (RD-21), quickstart.md:Q9**
What: Unauthenticated connection exhaustion. One global pool `LLMCTL_DECIDE_MAX_CONNS=64`, 3 s handshake budget, 10 s read deadline, no per-source connection cap. A single LAN or internet host opening ~22 connections/s keeps all 64 slots busy pre-authentication; valid clients get nothing (INFERRED arithmetic: 64 slots / 3 s). Q9 only tests 10 idle connections, below the cap.
Fix: Per-source concurrent-connection cap well below the global cap, accept-queue shedding before TLS, and a Q9 case with > MAX_CONNS hostile connections from one source while a second source keeps succeeding (SC-006).

**R-023 · IMPORTANT · endpoint-inventory.tsv:20 (EP-019), openapi.yaml:356-360**
What: "Burst of failed authentications from one source → 429" — scope undefined (does it also block a *correct* key from that source? per IP?). Behind NAT, a port-forward or a tunnel (RD-34 options) all clients share one source address, so an attacker can lock out legitimate users. The `auth` column says `key`, which contradicts the scenario.
Fix: Specify that throttling applies only to failing attempts and never to a request carrying the valid key; key the throttle on (source, failure) with bounded memory; fix the column.

**R-024 · IMPORTANT · openapi.yaml:58,371-373, endpoint-inventory.tsv:23 (EP-022); research/web-jev-api-and-bench.md:99**
What: `readout_failed` (deterministic: the model will fail the same way again) is returned as 502. The hosted SDKs retry any 5xx twice by default (30 s budget), tripling backend cost per bad request — an amplification path on the most expensive operation.
Fix: Return a non-retryable 4xx/422 (`readout_failed`) for deterministic readout failures; keep 502 only for transient backend failures.

**R-025 · IMPORTANT · spec.md:287 (FR-065 "every llmctl endpoint"), spec.md:286 (FR-064), research.md:61 (RD-34)**
What: FR-065 makes cloud reachability a documented, tested capability for **every** llmctl endpoint, including the chat servers, which by Clarification 2 have no key and (by default) no TLS. Documenting port-forward/tunnel exposure of an unauthenticated plaintext llama-server invites free compute use and prompt/response interception.
Fix: For chat servers, document cloud access only through an authenticated overlay (WireGuard/Tailscale) and state plainly that port-forwarding them is unsafe; keep port-forward/tunnel recipes for the HTTPS + key gateway only.

**R-026 · MINOR · data-model.md:2,4; env-vars.md:45**
The key that keys the request-log "keyed state hash" is unspecified (if it is `LLMCTL_API_KEY`, rotation breaks log correlation and log readers holding the key can test guesses of low-entropy states). Fix: a separate per-install log-HMAC key.

**R-027 · MINOR · openapi.yaml:120-134** — `/metrics` requires the full decision key, so a metrics scraper holds full decision privileges. Record as accepted limitation (scoped keys are ADOPT-LATER) and say so in the docs.

**R-028 · MINOR · spec.md:308 (FR-086), discovery-contract.md §2** — Hook policy "fail-closed or fail-open stated explicitly" leaves the default open; the toolkit snapshot's gate is fail-open (its CHANGELOG v1.30.5). For a gate on dangerous commands the safe default is fail-closed. Fix: default fail-closed in shipped templates; fail-open only by explicit choice.

**R-029 · MINOR · spec.md:237 (edge case "Several users on one host")** — Each user gets their own cert/key, but they cannot both bind 8095 or the catalog ports; the edge case is silent on ports. Fix: document per-user port overrides.

---

## 4. Feasibility on this host / macOS

**R-030 · IMPORTANT · plan.md:154 (P1), spec.md:332 (FR-040), spec.md:376 (SC-004)**
What: P1 must show each finding RED on the unmodified candidate before any fix, but the real-model/real-tokenizer preconditions for H-rated D-01 (encoder truncation) and D-07 need the hash-locked venv and the downloaded model, which arrive only in P3/P4. A constructed precondition (P1 text) cannot close a defect as FIXED under Helix §11.4.115(G), so SC-004 ("0 high items open") cannot be met as sequenced (new-files.md:393 already notes "D-01 not reproduced (needs real tokenizer)").
Fix: Pull a minimal "candidate + real tokenizer + model.onnx" RED harness (scratch venv) into P1 for D-01/D-07, or explicitly schedule their RED after P3/P4 against the unmodified candidate.

**R-031 · IMPORTANT · spec.md:287 (FR-065 "tested capability"), plan.md:159 (P6), plan.md:203 (OD-2)**
What: Cloud reachability must be "tested", but no outside-the-LAN vantage exists; OD-2 only covers a second LAN machine. As written the requirement has no test path and will end as "not exercised".
Fix: Add an OD (e.g. a short-lived cloud VM or a phone tether as external vantage) or amend FR-065 to "documented; tested from an external vantage when the operator provides one".

**R-032 · IMPORTANT · plan.md:161 (P8), spec.md:342 (FR-048), quickstart.md Q12**
What: Each agent needs a driving LLM to make a decision call. Claude Code needs the operator's Anthropic account; opencode/pi/crush/aider need a configured provider; a local chat profile must co-reside with the vision server on ~4 GiB free VRAM plus a decision profile. The plan does not say which model drives each agent, its cost, or its host budget.
Fix: Add a per-agent driver table (model, provider, credential source, budget) and an OD for any paid provider.

**R-033 · IMPORTANT · data-model.md:138 (§10 `total_decision_slots = max(...)`), research.md:44 (RD-22), spec.md:373 (SC-001)**
What: The gateway spreads load "least-loaded" across instances of a profile, which may be placed on GPU and on CPU. CPU and GPU kernels give different logits, so byte-identical repeats (SC-001, FR-074) break as soon as a second instance exists (INFERRED; RD-17 already notes batch-size dependence). Separately, `max(instances_gpu, instances_cpu)` vs a sum is unexplained and SC-010 demands equality with live admission.
Fix: Scope determinism to "one instance / one device placement", or pin deterministic-mode requests to one instance; define and justify `max` vs sum.

**R-034 · MINOR · plan.md:14, research.md:55-57** — Gateway target Python ≥ 3.9 stdlib, but the TLS behaviour was verified only on Python 3.14/OpenSSL 3.5; macOS `/usr/bin/python3` 3.9 links LibreSSL (INFERRED). Schedule a check or document as unverified (US7 AS4 permits).

**R-035 · MINOR · spec.md:373 (SC-001 "under 5 minutes of hands-on time")** — Not machine-measurable as stated; define the measurement (scripted timed run from the docs) or drop the hands-on clause.

---

## 5. Coverage ("ignored items")

Spot-check of 30 random ADOPT / ADOPT-AFTER-VERIFICATION rows (seeded sample): 24 map clearly to an FR/RD/phase (e.g. J1-003→FR-001, J1-013/J1-044→FR-050 diagrams, J1-016→US2 AS1, J1-111→cli.md exit codes, J2-040/041→FR-080, J2-074→RD-01). Gaps:

**R-036 · IMPORTANT · research/jev-md-coverage-{1,2,3}.md "Ideas … NOT yet in the spec" (11 + 11 + 20 = 42 ideas) vs plan.md:56, traceability.md:43**
What: The closure rule covers rows only; the three "Ideas" lists have no closure rule. Ideas with no trace in any plan artefact (grep across spec/plan/research/data-model/quickstart/traceability/contracts):
- per-class accuracy + imbalanced-base-rate items (cov-1 I-04, row J1-008): grep `per-class` → 0 (control: `jev-at-home` → research.md hit);
- `jev-pi`/`pi-jev` existence check for the Pi page (row J2-006, cov-2 I-07): 0 hits in plan artefacts and in web research;
- `jev-mcp-server` verification (row J2-002): only in web research, no task/FR;
- vendor failure-mode list (ten per web-jev-api-and-bench.md:147) → limitations page + arithmetic/date probes (row J1-009, cov-1 I-10): not in plan;
- harmful-pass measurement or "not a guardrail" statement (cov-3 I-13), language coverage per profile (I-14), ecosystem-port list (I-16), p50/p95 in `decide status` (I-17), local drift-check run (I-08), BYO end-to-end example (I-12 — FR-008 exists but no example chosen).
Fix: Extend traceability rule 1 to the Ideas lists (each idea → FR/RD/task or explicit closure), and make `tests/coverage_rows.sh` check idea ids too.

**R-037 · MINOR** — Inventory check passed: every NEW-IN-JEV and MODIFIED path is accounted for in merge-plan.md / jev-llmctl-new-files.md (scripted, 0 missing). No action.

**R-038 · IMPORTANT · data-model.md:136-138, discovery-contract.md:9 vs candidate `lib/catalog.sh:604-613`**
What: The candidate (and the v70 constitution anchors that consume it, `Constitution.md:11973,12029` of the snapshot) emit `decision_instances` as an object keyed by profile with `per_instance:{ram_mb, vram_mb, slots}` and an optional `reason`. data-model §10 defines a different shape (`profile`, `protocol`, `per_instance:{ram_mib, vram_mib}`, `slots_per_instance`). This is an unrecorded contract change (cli.md "Delta vs candidate" omits it; discovery-contract says "existing keys unchanged").
Fix: Keep the candidate shape (additive fields only), or record the change in discovery-contract §2 and the release notes.

---

## 6. Constitution / process compliance

**R-039 · BLOCKING · spec.md:305 (FR-083), spec.md:173 (US7 AS3), plan.md:38 (row VII), source-findings.md:39 (D-15) vs `lib/service_linux.sh:119-130` and `specs/001-llmctl-completion/tasks.md:187`**
What: The current unit code deliberately sets `MemoryMax` = full RAM by a recorded **operator decision (2026-09-15): "remove artificial caps entirely, maximal performance/resources for served models"**. The 009 artefacts call this a defect ("gap against the 60% ceiling"), require ≤ 60% for decision units, and never mention the operator decision. The Constitution Check marks it "NEEDS ATTENTION" without disclosing the conflict.
Why: Silently reversing a recorded operator decision (and creating two memory policies in one product) is a governance violation; tasks would implement it unasked.
Fix: Add an OD ("decision units: follow the 2026-09-15 no-cap decision, or the §12.6 60% ceiling?"), cite both sources, and amend D-15/FR-083/US7 AS3 to the answer.

**R-040 · IMPORTANT · plan.md:34 (row III "PASS") vs `.specify/memory/constitution.md:14`**
The project constitution's TDD rule is "Tests written → **User approved** → Tests fail → Then implement". No phase or human checkpoint (plan.md:185-189) schedules user approval of tests. Row III is mislabelled PASS. Fix: add the approval checkpoint (at least for P1 RED suites and P2 security tests) or record an operator waiver.

**R-041 · IMPORTANT · plan.md:46 ("Floor applies to new code")**
Helix §11.4.224 leaves brownfield adoption of the coverage floor deliberately undefined and requires the question to go to the operator before first enforcement ("never an invented ratchet"). The plan picks changed-code-only unilaterally; it also omits the RED-capable-numerator rule. Fix: add an OD with the §11.4.224 options; record the answer.

**R-042 · IMPORTANT · plan.md:151-163 (phases) — missing manual QA gate**
Helix §11.4.185 / §11.4.195(B) require live manual QA before a feature merges to `main`/is released, and §11.4.236 requires a candidate-fingerprinted readiness verdict before QA hand-off. P10 goes from automated suites straight to tagging; the Constitution Check does not list these anchors. Fix: add a QA hand-off step before P10 and list the anchors in the check.

**R-043 · MINOR · plan.md:24-48** — Other undisclosed governance edits: the project constitution's Technology Stack table (`.specify/memory/constitution.md:75-91`) lists every component as Bash; a Python service package is a stack change needing the same amendment as the bind statement; release tags `v3.x` do not follow Helix §11.4.151's `<prefix>-<version>`; work runs on an unnamed "scratch branch", not a §11.4.195 `feat/` branch. List them in the check (as accepted deviations if the operator agrees).

**R-044 · IMPORTANT · spec.md:31 (Clarification 3 note: "all endpoints, APIs and models MUST be fully available inside the local network or from the cloud") vs spec.md:38 (amendment) and FR-073**
The planning amendment makes engines/runtimes loopback-only. It is disclosed as an amendment ("review and revert"), but it narrows an operator statement and is not among the plan's Open Decisions. Fix: add it as an OD so the operator confirms explicitly.

**R-045 · MINOR · spec.md:376 (SC-004) vs traceability.md:45** — SC-004 counts "the findings register", which contains only D/I rows; N-01…N-29 (one H: N-01) live in research. Fix: say "register + N-rows".

---

## 7. Spec quality

**R-046 · IMPORTANT · spec.md:375 (SC-003) vs research.md:42 (RD-20)**
"Exceeds that baseline" is undefined (point estimate or CI lower bound?) and the consequence of failing is undefined; RD-20 plans to ship `decide-nli` with caveats or refuse choice/score. Fix: define the comparison (e.g. CI lower bound > baseline) and the outcome (not shipped / ships as experimental with the measured numbers).

**R-047 · IMPORTANT · spec.md:385 (SC-013), spec.md:379 (SC-007)**
Both are satisfiable by marking every cell/agent "not exercised". With ~41 cases × (6+ clients + 7 agents) × 2 vantages, the stress/chaos cases (EP-019…024, 070, 071) will be "not exercised" for agents and browser by construction. Fix: set floors — every programmatic client (curl, Python, Node, Go, CLI) must PASS every case on both vantages; "not exercised" allowed only for named case×client classes listed in advance.

**R-048 · MINOR · spec.md:261 (FR-012) / env-vars.md:37 vs spec.md:297 (FR-075 "up to 255 options")** — The default profile (decide-tiny, letter-logit) caps at 20 (hard 26); a hosted-built client sending 30 options to `jev-latest` gets 422. That is a legitimate profile limit but conflicts with "exactly". Fold into R-001's amendment and document per-profile limits in `/v1/models`.

**R-049 · MINOR · openapi.yaml / data-model.md** — Behaviour when a request names a known profile that is not running (start on demand? 503? 422?) is unspecified; no inventory case. Add one.

---

## 8. AI-slop / evidence-quality notes

The research files are unusually well cited (URLs, VERIFIED-LOCALLY tags, hashes). Specific issues:
- R-018 (time-varying host numbers stated as constants) and R-013/R-014 (counts that do not reproduce exactly).
- plan.md:61 "several hundred searches and fetches" — vague; the per-file counts exist, so sum them.
- research/web-jev-api-and-bench.md:143 still recommends `TYPESAFE_BASE_URL=http://127.0.0.1:8095` (plain HTTP), superseded by Clarification 5; mark the line superseded so it is not copied into docs (**MINOR, R-050**).
- No "verified" claim was found without a cited command or source in research.md; plan.md:15 "macOS ≥ 14 required by the onnxruntime wheel" is INFERRED from a platform tag in the research (web-runtime-engineering.md:138) and should carry that label (**MINOR, R-051**).

---

## Verdict

**NO-GO** for `/speckit-tasks`. Resolve before generating tasks:
1. R-020 — `$HOME/llmctl` default coincides with the documented clone dir; CA key/`.env` can enter git and release archives.
2. R-021 — unconstrained per-host root CA + OS-store recommendation.
3. R-039 — silent reversal of the 2026-09-15 operator decision on memory caps.
Then fix the IMPORTANT contradictions (R-001…R-007) so contract tests are generated from one consistent source, and add the missing Open Decisions (R-004, R-031, R-032, R-041, R-044, R-039).

## Probes run (with outcomes and control needles)

| # | Probe | Outcome |
|---|---|---|
| P1 | Status-code set: FR-075 vs openapi vs inventory vs data-model vs RD-04/RD-21 vs API research | Contradiction (R-001, R-002, R-024) |
| P2 | Bind variable: FR-018 vs env-vars | Contradiction (R-003) |
| P3 | `.env` location: Clarification 1, FR-059, `.env.example`, `.gitignore` vs plan/env-vars/data-model | Contradiction + mislabel (R-004) |
| P4 | Saturation status across FR-078, RD-21, plan perf goals, env-vars, research | 3 different mappings (R-002) |
| P5 | Matrix clients: FR-069/SC-013 vs Q11 vs P6 | Agents missing (R-007) |
| P6 | FR/SC counts: plan vs spec vs checklist | Checklist stale (R-012); plan correct (86/14) |
| P7 | Jev.md disposition counts vs coverage files (scripted) | Total 309 matches; 72/3 vs 73/2 split (R-014) |
| P8 | Ports: catalog/source-findings vs plan vs live `ss -ltnp` | 8099/8080/8087/8082 collisions (R-019) |
| P9 | Memory ceiling: FR-083/D-15 vs `lib/service_linux.sh:119-130` vs specs/001 tasks.md:187 | Hidden operator-decision conflict (R-039) |
| P10 | Capacity shape: data-model §10 vs candidate `lib/catalog.sh:604-613` | Unrecorded schema change (R-038) |
| P11 | Over-long state: env-vars/openapi/EP-008 vs data-model §3 vs hosted/Kev | Contradiction (R-006) |
| P12 | Health probes: FR-019 vs openapi vs EP-041 | Singular/plural + missing 405 (R-008) |
| P13 | D-03 macOS evidence: inventory class of `lib/service_macos.sh` + grep `API_KEY\|decide` in candidate copy | 0 hits → unsupported (R-015). Control: `LLMCTL_DECIDE_API_KEY` found at candidate `lib/scheduler.sh:427` |
| P14 | D-30 archive contents: read `build_archive.sh` | Tars whole tree incl. untracked (R-016) |
| P15 | `cert/` in `.gitignore` | 0 hits (R-020). Control: `.env` found at `.gitignore:2` |
| P16 | Clone location in README/quickstart | `git clone … llmctl` (R-020) |
| P17 | Name-constraint default + OS-store recommendation in research | Off by default + recommended (R-021) |
| P18 | Ideas lists vs plan artefacts: grep `per-class`, `pi-jev`, `jev-pi`, `jev-mcp-server`, `nine` | Not in plan artefacts (R-036). Control: `jev-at-home` found in research.md |
| P19 | Pinned constitution §11.4.276–284 | 0 hits, as claimed. Control: `### §11.4.275` found |
| P20 | Engine HTTPS compiled (RD-32) via CMakeCache + `ldd` | Confirmed |
| P21 | llama.cpp tags for b11361 | Local tags end at b11100 → UNCONFIRMED (not refuted) |
| P22 | Inventory NEW/MODIFIED paths vs merge docs (scripted) | 0 unaccounted (R-037). Control: `lib/decide.sh` found 8 times |
| P23 | Host linger (baseline failure cause) | `Linger=yes` → scratch-env failure plausible |
| P24 | Agents/tools presence (`command -v`) | opencode/pi/crush/claude/node/go/chromium/podman/slirp4netns/uv present; aider/cline absent; `continue` resolves to the bash builtin only (not an agent) |
