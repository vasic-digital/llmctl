# Limitations and honest boundaries (llmctl 3.1.0)

**Revision:** 2 - 2026-10-08. Read this before relying on a decision answer or on the security properties of the gateway. Each item names where it
comes from: *vendor-documented* (the hosted Jev vendor's own failure modes, as recorded in the research notes under
`specs/009-jev-decision-models/research/`, not re-verified by llmctl), *probe* (a case in the golden-set probe file), *measured* (llmctl measured it),
or *by design*. Status words follow the project's gap register (`specs/009-jev-decision-models/evidence/gaps-register.md`).

## What a decision model is not

* **It is not a safety guardrail.** A `noul`/`choice`/`score` answer is a probability-shaped score from a small model. llmctl has not measured how often a
  harmful input passes (no harmful-pass measurement exists) and makes no guardrail claim. Use a decision as one input to a gate that also fails closed
  on its own (abstain / `--min-confidence`, an allow-list, a human), never as the only barrier in front of a destructive action. *By design.*
* **Confidence is not the probability of being right.** `confidence` is a shaping convention (1.0 when one option holds all the mass, 0.0 at uniform).
  No calibration is claimed, and the golden set (132 labelled
  items) is too small for ECE/MCE (needs at least 200) so the statistics tool prints "insufficient for calibration". *Measured/by design.*
* **It is not a chat model and generates no text.** One forward pass (letter-logit) or one pair-score per option (NLI).

## Known weaknesses of this model class

* **Arithmetic, dates and multi-step reasoning** are unreliable; dates are read as text. If the decision is really a calculation, compute it.
  *Vendor-documented; arithmetic and date cases are in the probe set (`tests/fixtures/golden/probes.jsonl`) but have not been run against a real model (G-113).*
* **Double negatives and misleading options** can flip an answer. *Vendor-documented; probe set.*
* **Irrelevant state changes answers** (the probe file has paired irrelevant-state variants). Keep the state short and relevant. *Probe; not yet run.*
* **Option-order sensitivity.** A model may prefer an earlier letter. `llmctl decide ask --permute K` rotates the options K times, averages and reports
  `evidence.permute.flip_rate`; use K at least the largest option count. noul and score questions cannot be permuted. *Measured mechanism. One provisional measurement exists: on the development host `decide-julia` flipped its answer in 41.5% of 41 option-order trials (17/41), `decide-laya` 19.5% (8/41), `decide-kev-08b` 2.4% (1/41), all on the agent-authored golden set - provisional, labels agent-authored, human review pending. These are not stable per-model numbers.*
* **Prompt injection through the state.** Option-forging text, control/bidi characters and look-alike marker lines are neutralised before the prompt is
  built, but the neutralisation table is best effort and not complete (`docs/decide-gateway.md`). Text that merely *argues* with the question is still model input. *Probe; by design.*
* **Option count.** At most 26 options (letters A-Z), practically 20 by default (`LLMCTL_DECIDE_MAX_OPTIONS`); accuracy tends to fall with more options and the
  recommended maximum per profile is a measurement that has not been run on real models. `score` supports 2-10 levels.
* **Languages.** The golden set is English only. No claim is made for other languages for any profile.
* **Parity with the hosted vendor.** No shipped local profile is claimed to match the hosted service on knowledge-heavy or multi-hop items. llmctl implements the request/response *wire shape*;
  it is not a byte-for-byte clone and `usage.input_tokens` is an estimate (`ceil(characters/4)`), not a tokenizer count.

## Readout semantics

* **Letter-logit bound.** The engine lists only the top-n first tokens. When an option letter is absent from the list the answer carries `flags:["option_missing"]` and
  `upper_bounds`; its probabilities are the conservative worst case inside the polytope the listed mass allows, and the winner is always an option the engine listed.
  A letter that is listed counts only its listed spellings (its probability is a lower bound). `--min-confidence` gates on that worst-case confidence. Details: `docs/decide-gateway.md`.
  A spelling outside the three tokens per letter that the bound assumes is not covered (G-130, minor).
* **Determinism.** In deterministic mode (default) a fixed seed and one slot per instance give byte-identical answers **per instance and per device placement**. A busy primary overflows to another
  instance (named in `x-llmctl-decide-instance`), and CPU versus GPU may differ in the last digits. `throughput` mode gives up byte-identity and says so in a header.
* **Context.** The token budget is an estimate; the per-slot context is read from the engine (`/props`) and, when it is wrong, the engine's own overflow error is mapped to the same `422`.
  The estimator was measured on one tokenizer; it was not re-measured for the new engine pin or for every catalog tokenizer (G-126). Random letter soup and rare Unicode blocks can exceed it (G-094).
* **Truncation** is off by default; with `LLMCTL_DECIDE_TRUNCATE=1` the middle of a long state is dropped and the response is flagged.

## Release status of 3.1.0

* **Manual QA waived by the operator, 2026-10-08; the constitution gate is operator-waived, not satisfied.** The release proceeds on the automated gates, the final independent review and the full test suite alone; no human ran the
  live manual-QA pass that Constitution section 11.4.185 requires. The same statement is in [validation](validation.md) and the CHANGELOG.
* **macOS: shipped labelled "verified statically only".** The launchd paths, plist generation, the `ps`-based process identity and bash 3.2 behaviour were checked by reading and by fixtures; no Mac was available. Linux is the live-verified platform. Windows is unsupported.
* **Second host.** The portability run (engine advance, test suites) used `nezha.local` (ALT Linux, CPU only). No other second machine was used.
* **Golden-set numbers are provisional.** Every accuracy, interval and flip-rate figure quoted anywhere is agreement with agent-authored labels, "provisional - labels agent-authored, human review pending"; the review is scheduled after the release.
* **Maturity labels (policy, OD-24).** All admitted decision profiles ship and nothing is hidden. For each profile and each answer type (`noul`, `choice`, `score`) whose measured Wilson lower bound does **not** clear the majority/chance baseline, the type is to be labelled
  `experimental` for that profile in `/v1/models`, `llmctl plan`, the documentation tables and the response metadata. That per-profile-and-type label is **not implemented yet**: it lands with the maturity task (T138), so until then the only statement is this page and the measured tables in
  [decision-models](decision-models.md): on the development host `decide-kev-08b` cleared the baseline on `noul` and `choice`, `decide-laya` on `choice` only, `decide-julia` on none, and `score` cleared no baseline on any profile measured.
  Profiles not yet measured (`decide-lev`, `decide-kev-4b`, `decide-kev-9b` were refused by the scheduler on that host) carry no accuracy claim at all.

## What was and was not verified live

Verified by running (evidence under `specs/009-jev-decision-models/evidence/` and `docs/qa/`): the Go gateway over real HTTPS against fake engines (`tests/test_gateway_endpoints.sh`), three native decision profiles (`decide-julia`, `decide-laya`, `decide-kev-08b`) through the real scheduler, a systemd user unit, the HTTPS gateway and the golden set (`evidence/live/NATIVE-REPORT.md`), the cluster CLI over real HTTP/3 with a real curl (`evidence/curl-h3/CURL-H3-REPORT.md`), certificate and key tooling,
the registry and dynamic ports with a live systemd `--user` run (`docs/qa/dynamic-ports-validation/`), the engine-pin advance on a second Linux host (ALT Linux, CPU only: the native `/v1/systemone` endpoint worked, 8/8 byte-identical, HTTPS compiled in), and
the agent installers on this host.

**Not** verified live, stated as open in the gap register at the time of writing:

| Item | Gap |
|---|---|
| macOS: launchd loading the generated plists, the `ps`-based process identity, bash 3.2 behaviour. Verified **statically and with fixtures only**; shipped labelled so | G-009, G-070, G-124 |
| Windows: **unsupported** (no code path) | by design |
| The golden set against any real model (no accuracy number is published; any number later quoted ships labelled *provisional - labels agent-authored, human review pending*) | G-110, G-113 |
| A live exercise of any coding agent with a real prompt through the gateway; agent permission behaviour for crush/continue/cline shell tools (the operator approved a minimal agent run, about 100 model requests in total; no result of it is recorded on this page) | G-060, G-061 |
| An authenticated call from a second machine; behaviour behind an active firewall; IPv6 `/48` aggregation beyond unit tests | G-090, G-091, G-101 |
| CUDA / MoE / vision / colibri / performance regression after the engine jump of 392 commits (CPU, one model, two prompts only) | G-118 |
| Real-model reproduction of long-state truncation and some encoder paths | G-017, G-018, G-075 |
| Candidate admission gate G10 for 13 candidates; a real-run executor | G-013 |
| `decide-lev`, `decide-kev-4b`, `decide-kev-9b` on any real run through the scheduler (refused for RAM on the development host; no accuracy, memory or latency figures); `decide-kev-08b` at its final catalog values (it ran under an earlier, lower estimate) | NATIVE-REPORT section 7 |
| The manual QA pass (waived by the operator, see above) | - |

## Native decision profiles (`decide-julia`, `decide-kev-*`, `decide-laya`, `decide-lev`)

These run the engine's own `/v1/systemone` endpoint and are served by the gateway only with `LLMCTL_DECIDE_NATIVE=1`. Measured on the development host ([NATIVE-REPORT](../specs/009-jev-decision-models/evidence/live/NATIVE-REPORT.md)):

* **Scheduler refusals with numbers are the shipped behaviour for a RAM-constrained host.** `decide-lev`, `decide-kev-4b` and `decide-kev-9b` were refused (for example needs 3896 MiB RAM, 1976 MiB remained) and were not forced. See
  [runbooks](runbooks.md#the-scheduler-refuses-a-start). The planner's estimate (weights, KV cache and a declared `overhead_mb`) under-reserves these models; `overhead_mb` is measured only for `decide-julia`, `decide-laya` and `decide-kev-08b`, and a fix to the estimate is in progress.
* **"CPU mode" can still use VRAM** on a CUDA build of the engine: 0.1-0.2 GiB for the two small encoders, about 2.3 GiB for `decide-kev-08b`, none of it booked by the planner.
* **Input windows.** The catalog sets `decide-julia` and `decide-laya` to 1024 tokens and `decide-kev-08b` to 2048. A state that does not fit answers `422` (the engine's "input too large" error is mapped to it); on the development host 6,500- and 8,000-character prose states were refused by the 1024-token profiles and served by `decide-kev-08b`.
  Window sizes are a memory trade-off (peak memory grows with window and state length), not a model property.
* **Option-order sensitivity** was large for some: the provisional flip rates are in the option-order bullet above (`decide-julia` 41.5%).
* `decide-julia` does not reproduce its model card's 73% on the agent-authored set (a different quantisation and a different set: the two are not comparable); no claim is made either way beyond the measured intervals.
* `LD_LIBRARY_PATH` shadowing of the engine's libraries is fixed for services llmctl starts (see below).

## Security boundaries (also in `docs/tls-and-keys.md`)

* One access key, one trust level: no per-user keys, quotas or audit identity. Rotation is per installation. A key set in the gateway's *own* environment is not changed by rotating the key file.
* Weak operator-supplied keys are **rejected** (including one already stored in `.env`: the gateway refuses to start, exit 4, until `llmctl decide key rotate`).
* The loopback hop to an engine is plain HTTP: on a **multi-user host** a local user can race for an engine's port while it is down and receive one request's state and the internal key before the next rotation. Unix-socket peer credentials would close this and are not implemented (G-104).
* A volumetric flood from many addresses is out of scope; use a firewall or proxy ([cloud-exposure](cloud-exposure.md)). Behind NAT or a proxy all clients share one source budget.
* A BYO certificate that is a CA or lacks `serverAuth` only warns. A leaf with a very slow client link (more than 3 s to the first authenticated request) can hit the pre-auth timeout.
* The history check of the release archive is path-based: a secret committed under a harmless name and later deleted is not detected (G-123).
* Keys are Go strings and are not zeroed in memory; reading the gateway's memory or `/proc/<pid>/environ` is out of scope.

## Platform and tooling boundaries

* **Go >= 1.25** is required to build the decision binary; the rest of llmctl needs only bash, python3 and curl. `llmctl build all` needs PyPI access for the hash-locked `onnx` venv and Python >= 3.11 (G-034, G-035).
* `llmctl decide status --json` changed shape: `{"profiles":[...],"gateway":{...},"registry":...}` (it was a bare list).
* The opt-in cluster CLI (`llmctl cluster|tenant|apikey`) needs a host `curl` that lists the `HTTP3` feature (`curl --version`); otherwise it reports `llmctld unreachable` and its suites SKIP. It was verified against a real
  `llmctld` with a real curl 8.22.0 built with ngtcp2/nghttp3 in a **private test prefix** (not packaged by llmctl; loopback and one node only; the second-peer join scenario was not exercised). How to get such a curl:
  [llmctld-cluster-tls](llmctld-cluster-tls.md#getting-a-curl-that-lists-http3). What the cluster daemon's pieces really do (wired versus library only): [faq](faq.md).
* Multi-instance serving of one decision profile is `llmctl decide scale <profile> <N>` (admission-bounded; instances beyond the first need the port-registry binary, `llmctl build decide`). `decide capacity` stays a read-only report of how many would fit.
* `LD_LIBRARY_PATH` shadowing (G-129) is fixed for the services llmctl starts (systemd units; the launch wrapper `hk_run_engine` prepends the engine's directory, **macOS statically only**). A `llama-server` you launch by hand from a shell whose
  `LD_LIBRARY_PATH` points at a system `libggml` can still fail with `undefined symbol ggml_...` ([runbooks](runbooks.md#ld_library_path-shadowing)). The engine version stamp reads `build 1` on a shallow clone (G-132).
* Candidate-model admission (`llmctl admit`) mechanical dispositions differ from the research register for three candidates (G-014).
* The `golden`, `matrix` and `admit` tooling is test/evidence tooling, not a user feature.
