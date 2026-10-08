## Overview

`lib/admit.sh` implements `llmctl admit`, the admission pipeline for
decision-model candidates (spec 009, US6, FR-007/FR-008/FR-085). For one
Hugging Face repo it runs gates G1-G10 and records a machine-readable
outcome; `--all` runs every row of the candidate register and writes
`SUMMARY.md` / `SUMMARY.json`. Nothing is downloaded: only the model
metadata API (`/api/models/<repo>?blobs=true`) is read.

## Prerequisites

* `bash`, `curl`, `python3` (all gate logic and JSON output).
* Sourced by `bin/llmctl` after `lib/common.sh`; the dispatch line is
  `admit) cmd_admit "$@"`.
* For gate G4 the pinned llama.cpp tree (`submodules/llama.cpp`, override
  `LLMCTL_ADMIT_LLAMA_SRC`); if absent G4 is PENDING, never PASS.

## Usage

```sh
llmctl admit <hf-repo> [--paper-only] [--json] [--protocol P] [--pin FILE]...
                       [--known-issue TEXT] [--kind weights|harness] [--name N] [--no-write]
llmctl admit --all [--paper-only] [--candidates FILE]   # whole register + summary
llmctl admit --summarize                                # rebuild SUMMARY.* only
```

Exit codes: `0` ADMITTED or ADMIT-CANDIDATE, `10` USER-ONLY, `11` REJECTED,
`12` HOLD, `13` NOT-FOUND, `2` usage/runtime error. A repo present in the
candidate register supplies defaults (pins, protocol hint, known issue)
that the flags override.

## Gates

Every gate yields `{gate, name, status, evidence}`, `status` being
`PASS|FAIL|SKIP|PENDING`. Unknown is never PASS.

| Gate | Checks | FAIL when |
|---|---|---|
| G1 | weights SPDX licence (API `cardData.license`, else `license:` tag) against the allow-list | licence absent/unknown (fail closed) or not on the list (e.g. `cc-by-nc-4.0`, `other`) |
| G2 | 40-hex commit sha, not gated/private/disabled; `lastModified` recorded | gated, private, disabled, no sha |
| G3 | size + sha256 of each pinned file from the API LFS oid | no GGUF/ONNX to pin; pin missing from repo; model file without LFS sha256. Non-LFS aux files make it PENDING (sha256 must be computed at pin time) |
| G4 | loadable on paper: GGUF `architecture` is in the pinned tree's `llm_arch_names`; for native decision models `/v1/systemone` must be in `tools/server` | arch absent from the pinned tree. Missing `/v1/systemone` is PENDING (engine advance, FR-085), not FAIL |
| G5 | largest model file vs `LLMCTL_ADMIT_MAX_BYTES` (default 10 GiB) and memory ESTIMATE (GGUF size*1.3; ONNX size*1.5+512 MiB) vs `LLMCTL_ADMIT_MEM_BYTES` (default 60% of MemTotal); tier recorded | over either budget |
| G6 | protocol class: `letter-logit` \| `systemone-native` \| `nli-onnx` \| `unsupported`. API `gguf.decision_type` wins; otherwise the curated hint; none = unsupported. Contract files: nli-onnx needs a pinned tokenizer | unsupported, or format does not match the class |
| G7 | no pickle-format file (`.pt .pth .bin .pkl .npz .ckpt`) in the pin; pickle files merely present in the repo are noted | pickle in the pin |
| G8 | API `author` equals the repo owner | mismatch |
| G9 | known-issue sweep: register column `block:` (FAIL), `none-verified:` (PASS, attested live sweep), `note:` or empty (PENDING: tracker not queried by the driver) | blocking issue recorded |
| G10 | real run: loadability, smoke answer, determinism repeats, option-order sensitivity, measured memory (`g10_subchecks`) | executor reports failure (or a PASS with a non-PASS sub-check) |

## Disposition

`ADMITTED` (all ten PASS) \| `ADMIT-CANDIDATE` (no FAIL, PENDING gates remain)
\| `USER-ONLY` (any FAIL other than below) \| `REJECTED` (G1 FAIL, or
`kind=harness`) \| `HOLD` (G9 FAIL) \| `NOT-FOUND` (HTTP 404/401/transport
error). G10 is attempted only for an ADMIT-CANDIDATE and only when not
`--paper-only` and `LLMCTL_ADMIT_REAL_RUN` names an executable; without
an executor G10 stays PENDING (never a fabricated PASS).

Existence verdict per Helix 11.4.270: `VERIFIED` (HTTP 200 model document),
`AMBIGUOUS` (401: private and missing look alike), `UNVERIFIED` (404,
transport failure, or a non-HF name that was not probed).

## Environment variables

| Variable | Default | Effect |
|---|---|---|
| `LLMCTL_HF_BASE` | `https://huggingface.co` | API base (tests point it at a local fixture server) |
| `HF_TOKEN` | unset | sent as a bearer header via a curl config pipe; never printed or stored |
| `LLMCTL_ADMIT_EVIDENCE_DIR` | `specs/009-jev-decision-models/evidence/admission` | where `<slug>.json`, `SUMMARY.*` go |
| `LLMCTL_ADMIT_CANDIDATES` | `<evidence dir>/candidates.tsv` | candidate register (TSV, `-` for empty) |
| `LLMCTL_ADMIT_LICENSES` | apache-2.0,mit,bsd-2-clause,bsd-3-clause,cc-by-4.0,cc0-1.0,isc,unlicense | G1 allow-list |
| `LLMCTL_ADMIT_MAX_BYTES` | 10737418240 | G5 per-file cap |
| `LLMCTL_ADMIT_MEM_BYTES` | 60% of MemTotal | G5 memory budget |
| `LLMCTL_ADMIT_LLAMA_SRC` | `submodules/llama.cpp` | pinned engine tree for G4 |
| `LLMCTL_ADMIT_DELAY` | 1 | seconds between candidates in `--all` |
| `LLMCTL_ADMIT_RETRY_WAIT` | 20 | wait after an HTTP 429 (3 retries) |
| `LLMCTL_ADMIT_REAL_RUN` | unset | real-run executor, called `<exe> <repo> <record.json>` |

Real-run executor contract: print one JSON object
`{"status":"PASS|FAIL","evidence":"...","subchecks":[{"check","status","evidence"}...]}`
with checks `loadability, smoke_answer, determinism_repeats,
option_order_sensitivity, memory_fit_measured`. The driver re-evaluates it;
a PASS with any non-PASS sub-check becomes FAIL.

## Outputs

`<evidence dir>/<repo-slug>.json` (slug: `/` becomes `__`; non-HF names use
the register name): schema `llmctl.admission/1` with `candidate`,
`existence`, `api`, `pins`, `protocol`, `needs_engine_advance`, `tier`,
`gates`, `g10_subchecks`, `disposition`, `reasons`, `retrieved_at`.
Files are written atomically (temp + rename). `SUMMARY.json`/`SUMMARY.md`
count dispositions, existence verdicts and gate failures and list the
ADMIT-CANDIDATEs that still need real runs, with an honest-gaps section.

## Edge cases

* HF answers 401 for private and missing repos alike: existence AMBIGUOUS.
* A repo that holds pickle files (Kev `head.pt`, NLI `training_args.bin`)
  is fine when the explicit pin excludes them.
* Two pinned files from one repo (JevK5 2B/9B) are one record with two pins.
* Curated columns are VENDOR-CLAIM/paper input; every verdict is
  recomputed from the live API. A candidate with no hint is `unsupported`.

## Tests

`tests/test_admit.sh` (network-free; fixture API in `tests/fixtures/admission/`
served by `server.py` on 127.0.0.1): golden-good candidate, forbidden and
unknown licence, over-budget GGUF, memory budget, gated repo, pickle pin,
non-LFS model, unpinnable repo, missing architecture, author mismatch,
blocking known issue, protocol classes, 404/401 existence, executor
PASS/FAIL/absent, HF_TOKEN never leaked, batch + summary.

## Related scripts

`lib/download.sh` (same `LLMCTL_HF_BASE` seam and API shape), `lib/decide.sh`
(consumer of admitted profiles), `docs/decision-models.md`.

## Last verified date

2026-10-07

## Scratch directory (C-19)

`_admit_one` evaluates a candidate inside a subshell whose `EXIT` trap removes
the scratch directory (the trap references a variable, never an interpolated
path) and removes it again on every return. A `die` from inside the evaluation
therefore no longer leaks the directory, and a `TMPDIR` containing a quote no
longer breaks the cleanup. Proof: `tests/test_admit.sh` ("C-19").
