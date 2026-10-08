# Data Model — Jev-Class Decision Models

**Feature**: 009-jev-decision-models | **Date**: 2026-10-07 | **Spec**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md)

Everything is files and JSON; there is no database. Field types are descriptive (JSON types). "Source" says where the data lives. Validation rules cite the requirement they implement.

## 1. Decision Profile (catalog entry) — `models/catalog.json`

Extends the existing profile object (see `contracts/catalog-schema.md` for the full schema and a worked example).

| Field | Type | Rules |
|---|---|---|
| `name` (map key) | string | unique; lowercase `[a-z0-9-]+`; **must not contain `.`** (reserved as instance separator, RD-22) |
| `capability` | array of string | contains `"decide"`; **must not** contain `"chat"`/`"coder"`/`"vision"` (FR-006); `auto chat` never selects a profile with `decide` |
| `engine` | `"llama"` \| `"colibri"` \| `"onnx"` | `onnx` ⇒ `protocol = "nli-onnx"` |
| `decision.protocol` | `"letter-logit"` \| `"systemone-native"` \| `"nli-onnx"` | selects the backend adapter |
| `decision.max_options` | int 2–255 | practical cap (CLI default 20); letter-logit hard cap 26 |
| `decision.score_levels` | [2,10] | |
| `decision.readout` | object | letter-logit only: `n_probs` (default 32), `mass_threshold`, `spellings`, `cache_prompt:false` |
| `decision.template_hash` | sha256 hex | hash of the authoritative prompt template (binds calibration profiles) |
| `decision.tier_note` | string | e.g. "experimental choice/score" for `decide-nli` (RD-20) |
| `min_tier` | `datacenter`\|`workstation`\|`baseline`\|`below-minimum` | `below-minimum` = recommend-only, never blocks |
| `port` | int | unique across catalog; internal backend port (loopback); gateway port is separate (default 8095) |
| `defaults` | object | `ctx`, `ngl`, `parallel`, `flash_attn`, `kv_cache_type`; decision profiles default `parallel` = 1 in deterministic mode |
| `hf_repo`, `hf_revision` | string | `hf_revision` is a **40-hex commit** (not `main`) for decision profiles (G2) |
| `license` | SPDX string | weights licence; must be on the allow-list (G1) |
| `provenance` | `{benchmark: {value, class}}` | `class` ∈ `llmctl-measured` \| `vendor-measured` \| `independent` \| `unverified` (FR-052) |
| `files[]` | array | each: `name`, `size` (bytes), `sha256` (**never null** for decision profiles after RD-09), `role` ∈ `model`\|`tokenizer`\|`config`\|`head`\|`mmproj` |
| `files[].sha256` | hex64 | verified at download; mismatch = hard failure, content never reaches the final path |

**State (per host)**: `catalogued → downloaded → verified → admitted → running → draining → stopped`. Transition rules: `verified` requires size+sha256 match for *every* file and a passed smoke test whose result is **real** (a skipped smoke test leaves the profile `downloaded`, with the reason recorded – D-12); `admitted` requires budget fit (scheduler); `running` requires the backend `ready`.

## 2. Decision Instance — registry file `${LLMCTL_STATE_DIR}/decide/registry.json`

Written atomically (temp + rename) under the same lock as service changes.

| Field | Type | Rules |
|---|---|---|
| `key` | string | `<profile>` for the first instance, `<profile>.<n>` for further (n ≥ 2) |
| `profile` | string | must exist in the catalog |
| `protocol` | enum | copied from the profile |
| `backend_url` | string | `http://127.0.0.1:<port>` (or UNIX socket later); **never** a non-loopback address (FR-073) |
| `port` | int | free at start; collision fails the start with the offending port and the override variable |
| `pid` | int | verified against `/proc/<pid>/cmdline` (or `ps`) before any signal; `pid ≤ 1` refused |
| `started_at` | ISO-8601 UTC | |
| `state` | `starting`\|`ready`\|`degraded`\|`draining`\|`stopped` | `ready` only after readiness probe passes |
| `slots` | int | = profile `parallel` |
| `in_flight` | int | gateway-side counter (not persisted) |
| `internal_key_file` | path | 0600, random per start, never printed |

Invariant (checked by doctor): registry rows == live backend processes (the "configured ≠ in use" check).

## 3. Typed Question and Typed Answer — wire shapes (`contracts/openapi.yaml`)

**Request** `{ model, state, questions: { <name>: { type, instructions, criteria } } }`

| Field | Rules |
|---|---|
| `model` | string; resolved by the alias table (RD-05); unknown → 422 `unknown_model` |
| `state` | string \| object \| array; combined with the longest question ≤ configured budget; over-limit → **422 by default** (as the hosted service); opt-in shortening (`LLMCTL_DECIDE_TRUNCATE=1`, head and tail kept) sets `x-llmctl-decide-truncated` and logs it; question/option text never shortened (FR-012) |
| `questions` | 1…N entries (N configurable, default 32); names are free keys, **never reach the model** |
| `type` | `noul` \| `choice` \| `score` |
| `criteria` (`noul`) | optional `{true, false}` descriptions |
| `criteria` (`choice`) | map option → description (null allowed); 2…255 entries (profile `max_options` applies first) |
| `criteria` (`score`) | ordered array of 2…10 level descriptions, lowest→highest |

**Answer** (per question, same keys)

| Type | Fields | Rules |
|---|---|---|
| `noul` | `type`, `noul` | `0 ≤ noul ≤ 1`; **no confidence** |
| `choice` | `type`, `choice`, `probabilities{option→p}`, `confidence` | `Σp = 1 ± 1e-6`; `choice = argmax`; `confidence = (p_max−1/n)/(1−1/n)` ∈ [0,1] |
| `score` | `type`, `score`, `legend{"0"…}`, `probabilities{"0"…}`, `confidence` | `0 ≤ score ≤ n−1`; probabilities keyed by level index string; confidence llmctl-defined (normalised peak) |

Response envelope: `{ model: <real local id>, answers: {…}, usage: { input_tokens, output_tokens } }`. `usage` is an estimate (≈ chars/4) and is labelled so in the docs. CLI additions (`decide ask`) add `evidence: { profile, port, latency_ms }` (unquantised ms).

**Errors**: `{ message, error_type }` with status 400/401/422/429/503/529; `x-llmctl-request-id` on every response; `Retry-After` on 429/503; `WWW-Authenticate: Bearer realm="llmctl"` on 401. Bodies never contain exception text, paths or versions.

## 4. Access Key — `LLMCTL_API_KEY`

| Aspect | Rule (FR-057…063) |
|---|---|
| Format | `^[A-Za-z0-9_-]{32,}$`; generated = `secrets.token_urlsafe(32)` (43 chars, 256 bits) |
| Sources, in order | (1) process environment (e.g. exported from `.bashrc`/`.zshrc`); (2) the installation-root `.env` (path from `LLMCTL_ENV_FILE`), line `LLMCTL_API_KEY=` ; (3) generated on first start |
| Blank / whitespace / malformed | explicit error; never "no key" |
| Persistence | `.env` created with `O_EXCL`, mode 0600; updates via temp+fsync+rename; pre-existing looser mode tightened or refused; **refused if the path is inside a git work tree and not ignored** (FR-087) |
| Concurrency | `flock` on `${LLMCTL_HOME}/cert/.lock`-style lock (shared with certificates) so simultaneous first starts generate exactly one key |
| Shadowing | env value differs from `.env` ⇒ env wins; doctor reports `.env` shadowed |
| Rotation | explicit `llmctl key rotate`; optional `--grace N` keeps `LLMCTL_API_KEY_PREVIOUS` with expiry (off by default) |
| Display | only through the deliberate command `llmctl key show`; never in logs/status/evidence |
| Shell export | `llmctl key export [--file F] [--inline]` – explicit; managed marker block; idempotent; backup; permission warning |

**State**: `absent → generated(persisted) → in-use → rotated` ; `invalid(blank|malformed)` is a terminal error until fixed.

## 5. Server Certificate — `${LLMCTL_HOME}/cert/`

```
cert/ (0700)
  ca/ca.key (0600)  ca/ca.crt (0644)
  current -> v-<epoch-ms>/                (atomic symlink)
  v-<epoch-ms>/ leaf.key (0600)  leaf.crt (0644)  leaf.san  meta.json
  .lock
```

| Field (meta.json) | Rules |
|---|---|
| `ca_fingerprint_sha256`, `leaf_fingerprint_sha256` | displayed by `cert show`; never regenerated silently |
| `issued_san[]` | sorted; desired set = hostname(s), `.local`, loopbacks, interface addresses, `LLMCTL_TLS_SAN` extras; desired ⊄ issued ⇒ doctor WARN with the exact new names |
| `not_after` | CA 3650 d; leaf 397 d; warn ≤ 30 d; refuse start when expired |
| `key_type` | EC P-256 (RSA-2048 only by documented override) |
| `mode` | `ca-leaf` (default) \| `selfsigned` (fallback) \| `byo` (operator-supplied pair, validated: matching, unexpired, readable) |
| `ca_name_constraints` | **on by default**: permitted DNS = host names, `localhost`, `*.local`, operator extras; permitted IP = loopback, RFC 1918, ULA, CGNAT/overlay ranges, operator extras. A name outside the constraints needs `byo` or a deliberate CA re-creation (documented; clients re-import the CA). Recommend per-client CA bundles first; OS-wide trust only with constraints on; offline-CA-key mode available (FR-066) |

**Placement guard (FR-087)**: `cert/` is refused inside a git work tree unless ignored by version control; the repository `.gitignore` carries `cert/`; the release archive builder uses an allow-list of tracked files, so a planted `cert/ca/ca.key` never ships (tested).

**State**: `absent → ca+leaf generated → valid → expiring(≤30d) → expired(refuse) → renewed(new v-dir)` ; `byo` reload on `SIGHUP`/`cert reload`.

## 6. Calibration Profile — `${LLMCTL_STATE_DIR}/decide/calibration/<profile>.json`

| Field | Rules |
|---|---|
| `profile`, `model_sha256`, `template_hash` | the profile is **refused at load** if either differs from the live model/template |
| `method` | `temperature` \| `platt` \| `isotonic` (isotonic only with ≥ 1000 labels) |
| `params`, `n_samples`, `fitted_at`, `labels_source` | recorded; `n_samples < 200` ⇒ no ECE claim (SC-003 amendment) |
| `metrics` | `ece`, `mce`, `brier`, `accuracy`, `ci_low`, `ci_high`, `baseline_accuracy` – all computed by the same tool |

## 7. Candidate Model Record — `specs/009-jev-decision-models/research/candidates.tsv` (register)

`name, owner/repo, revision_sha, licence_weights, licence_code, formats, params, protocol, G1…G10 results (pass/fail + evidence ref), verdict ∈ {ADMITTED, ADMIT-CANDIDATE, USER-ONLY, REJECTED, NOT-FOUND, HOLD}, reason, verified_at`. A verdict of `ADMITTED` requires G10 evidence from a real run on this host.

## 8. Evidence Record — JSONL (`contracts/evidence-schema.md`)

`{ id, ts, requirement[], command, cwd, env_digest, exit_code, stdout_sha256, stderr_sha256, artifact_paths[], duration_ms, class ∈ {real-model, real-component, stand-in, not-exercised}, vantage ∈ {host, podman-bridge, slirp4netns, second-machine, none}, result ∈ {pass, fail, not-exercised}, reason }`. A run directory also holds `SHA256SUMS`; summaries are generated from the JSONL. `result=pass` with `class=stand-in` is allowed only in the unit tier and is excluded from every summary that claims real behaviour.

## 9. Findings Register Item — `source-findings.md`

`id (D-xx, N-xx, I-xx), severity, finding, evidence (file:line), status ∈ {UNREPRODUCED, REPRODUCED, NOT-REPRODUCED, FIXED, ACCEPTED-LIMITATION}, red_test, green_test, closure_evidence`. Transition rule: `UNREPRODUCED → REPRODUCED` requires a test seen **failing for the stated reason** on the unmodified candidate; `FIXED` requires the *same* test passing plus a paired mutation making it fail again.

## 10. Decision Capacity Report — `llmctl plan --json` key `decision_instances`

**Shape = the candidate's, additive only** (an unrecorded shape change was a review finding): an object keyed by profile name, because the v70 consumers already read that shape.

```json
"decision_instances": {
  "decide-tiny": {
    "instances_gpu": 3, "instances_cpu": 12,
    "per_instance": { "ram_mb": 1500, "vram_mb": 900, "slots": 1 },
    "total_decision_slots": 12,
    "reason": "…only when 0 instances fit…",
    "protocol": "letter-logit"            // additive field
  }
}
```

**Definition (honest)**: each profile is computed **alone** against the full current budgets – profiles are not additive with each other or with running chat profiles. `instances_gpu` and `instances_cpu` are *alternative placements* of that one profile; `total_decision_slots = max(instances_gpu, instances_cpu) × slots_per_instance` is the capacity of the best single placement. `per_instance` reports the GPU placement when it fits, else the CPU placement. Units are MiB, named `_mb` as in the existing plan JSON.

**Invariant (SC-010)**: starting instances of that profile one at a time through the scheduler, on an otherwise idle budget, in the best placement, succeeds exactly `max(instances_gpu, instances_cpu)` times and the next attempt is refused with numbers. The report never starts or reserves anything. Mixed GPU+CPU placement of one profile is not reported (it would need a different, simulated definition and is out of scope for 3.1.0).

## 11. Release Record — `dist/3.1.0/release.json`

`version, tag, commit, tag_remotes[{remote, sha}], assets[{name, sha256, bytes}], sbom_ref, sha256sums_ref, notes_sha256, forges[{name, url, asset_checksums_verified, archive_tests_passed}], assurance_level ("SLSA build L1, unsigned" unless OD-4), known_limitations[]`.
