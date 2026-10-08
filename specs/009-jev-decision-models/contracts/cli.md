# CLI contract — `llmctl decide`, `llmctl cert`, `llmctl key`

**Status**: draft contract for 3.1.0 (design target; the candidate implements a subset – see "Delta vs candidate"). Commands the `llmctl-decide` binary does not register are marked **planned, not in 3.1.0**: `scale` (its `scale` text below is a design target only). `calibrate`, `probe-order` and `completions` are implemented (operator decision OD-23, `evidence/od-decisions.md`): FR-080's calibration metrics, one-parameter fit, bound profile file and order-sensitivity probe, and the completions part of FR-081, are delivered by them; what is NOT delivered by these commands is the gateway APPLYING a calibration profile and the opt-in decision log of FR-080 (see "calibrate" below); `traceability.md` rows FR-080/FR-081 must be read with this. Conventions follow the project constitution: text in/out, errors to stderr, `--json` for machine output, deterministic exit codes. Every command is covered by tests that run the real entry point and assert exit status, output and state delta.

## Exit codes (all commands)

| Code | Meaning |
|---|---|
| 0 | success |
| 1 | backend / runtime failure (model produced no usable readout, backend died, timeout) |
| 2 | usage error (bad flags, bad JSON input, limit violated before any backend call) |
| 3 | refused by admission control (budget); stderr carries the exact needed-vs-available numbers |
| 4 | access-key problem (absent when required, blank/malformed, wrong key, unsafe `.env` permissions that could not be tightened) |
| 5 | certificate / TLS problem (untrusted, name mismatch, expired, unreadable, invalid pair) |
| 6 | no decision instance is ready / endpoint unreachable |
| 10 | abstained: answer withheld because confidence < `--min-confidence` (JSON still printed with `"abstained": true`) |

## `llmctl decide ask`

```
llmctl decide ask [--profile P] --type {noul|choice|score}
                  (--state TEXT | --state-file F | --stdin)
                  [--instructions TEXT]
                  [--criteria JSON | --criteria-file F]      # choice: {"opt":"desc",…}; score: ["lvl0","lvl1",…]; noul: {"true":…,"false":…}
                  | --question-file F                        # one Typed Question object (see data-model §3)
                  [--endpoint URL] [--cacert F]              # default: https://127.0.0.1:${LLMCTL_DECIDE_PORT:-8095}, CA from $LLMCTL_HOME/cert/ca/ca.crt
                  [--json] [--explain] [--dry-run]
                  [--min-confidence X] [--permute K]         # abstention; opt-in cyclic option permutation (K calls)
```

- `"model"` in a question file, a batch line or an MCP call must be a non-empty string; `""`, `null` and non-strings are usage errors (exit 2), never the default profile - omit the field instead.
- `--state-file`/`--stdin` are read as **data**, never passed on a command line (no argument-length limit; nothing visible in `ps`).
- Output: JSON answer in the hosted shape plus `model` and `evidence{profile,port,latency_ms,calibrated[,truncated][,mode][,instance][,flagged][,permute]}`; pretty-printed only on a TTY without `--json`. `evidence.mode` is the gateway's `x-llmctl-decide-mode`; `evidence.instance` is the engine instance that answered (`x-llmctl-decide-instance`; in deterministic mode a busy primary overflows to the next instance, and byte-identity holds per instance only; `mixed` when the calls of a `--permute` run were answered by different instances); `evidence.calibrated` is always present: `true` when at least one answer carries a `calibration` object (the gateway applied a calibration profile), so the abstention gate read a calibrated confidence. The gateway's additive answer fields `confidence_raw` and `calibration{method,n,profile_id}` are passed through untouched (the gateway's bytes are never re-rendered), as are `template_hash` and `calibration{applied,...}` of `models --json`; the `models` table gains `calibration` and `template` (first 12 hex) columns. **`--min-confidence` semantics:** an answer with a `calibration` object is compared on its CALIBRATED `confidence` (a probability of being right, chance level 1/n); an answer without one on the shaped `confidence` (chance level 0); the two scales differ, so a threshold picked for one shifts meaning on the other - re-pick it when a profile starts or stops being applied (`evidence.calibrated` tells which). A calibrated flagged answer keeps the gateway's cap (never above the winner's worst-case share) and is not capped a second time on the shaped scale; `calibration: "mixed"` (see `--permute`) is read as uncalibrated. `evidence.flagged` is true when an answer carries `flags` (an option absent from the model's readout, reported as an upper bound, never as 0); a flagged answer is gated on its WORST-CASE confidence for `--min-confidence`: the gateway already places the absent options at the worst case their bounds allow and the winner is a listed option, so the client reads the best listed option's share (no second scaling by `upper_bounds`).
- `--permute K` (2..64) asks the same request K times with the options of every **choice** question rotated cyclically (call i lists option j at position (j-i) mod n; K is capped at the largest option count), and prints the order-AVERAGED answer: probabilities averaged per option key (original option order), the argmax as `choice`, `confidence` recomputed from the average, usage summed, flags merged. `evidence.permute = {k, flip_rate}` where `flip_rate` is the share of (choice question, call) pairs whose own answer clearly preferred another option than the averaged one - how order-sensitive the model is; a call that ties best with its own top (it broke the tie by its listed order) is **not** a flip. Each question is averaged over a **whole number of cycles of its own option count** (with 4 calls, a 3-option question uses 3 and a 4-option question uses 4); with fewer calls than options only part of one cycle exists, all calls are averaged and the position bias is cancelled only partially - use K ≥ the largest option count. With calibrated answers: if every averaged call carries the SAME `calibration` object it is kept, `confidence` is the mean of the calls' calibrated confidences and `confidence_raw` the shaped value recomputed from the averaged (raw) probabilities; if the calls disagree (a different object, or only some calibrated) the answer gets `"calibration": "mixed"`, `confidence` = `confidence_raw` = the shaped value, and it is not counted as calibrated (`evidence.calibrated` false). noul and score questions are not permutable (their options are not interchangeable) and are taken from the first call; one failed call fails the whole answer (never a partial average). Also accepted by `batch`.
- `--explain` prints the rendered prompt (decoder profiles) or the premise/hypothesis pairs (encoder), the letter→option map and per-option probabilities. Never prints the key.
- `--dry-run` validates input and prints what would be sent (endpoint, model, question count) without a network call.
- Uses the key resolution of FR-058; uses HTTPS with certificate verification; llmctl's own client has **no** option or variable that disables verification. Third-party clients' own last-resort switches are mentioned only in the troubleshooting page, with a warning, as their behaviour and never as an llmctl setting (FR-068).

## `llmctl decide batch`

`llmctl decide batch [--in FILE|-] [--out FILE|-] [--profile P] [--endpoint URL]` – newline-delimited JSON in (`{"id":…, "state":…, "questions":{…}}`), newline-delimited JSON out in input order; per-line errors are reported as `{"id":…, "error":{…}}` and the exit code is the highest-severity code seen.

## `llmctl decide capacity | status`

`llmctl decide capacity [--json]` – read-only; per profile: instances that fit on GPU / CPU, per-instance footprint, slots, total decision slots (equals the scheduler's live admission, SC-010).
`llmctl decide status [--json]` – registry rows vs live processes (flags "configured but not running" and "running but not registered"), gateway state, key present (yes/no, never the value), certificate expiry.

## `llmctl decide serve`

```
llmctl decide serve [--foreground] [--enable|--disable] [--stop] [--status]
                    [--bind HOST] [--port N]
```
Starts the single gateway (default `0.0.0.0:8095`, HTTPS). Refuses to start without a resolvable/generated key or a valid certificate. Prints bind address, HTTPS URL, key location, CA fingerprint and expiry – never the key. `--stop` verifies the process identity from `/proc/<pid>/cmdline` (or `ps` on macOS), refuses `pid ≤ 1`, and signals only the verified process. `--enable` installs/starts the boot-time user service (systemd unit / launchd agent); `--status` also reports whether the bind is reachable from a non-loopback address (self-connect check, FR-064).

## `llmctl decide scale <profile> <N>` — planned, not in 3.1.0

*planned, not in 3.1.0*: the binary has no `scale` command; instances are started through the scheduler (`llmctl start|enable|auto`). The text below is the design target.

Starts or stops instances of one profile until `N` are ready, never beyond what admission control allows (refusal exits 3 with numbers). Instance keys: `<profile>`, `<profile>.2`, … Ports come from the registry allocator; a taken port fails with the port number and the override variable. In deterministic mode requests for a profile are served by its primary instance and only overflow to further instances when the primary is saturated (byte-identity is guaranteed per instance and device placement, FR-074); `throughput` mode spreads least-loaded and is marked in every response (`x-llmctl-decide-mode: throughput` header, client `evidence.mode`).

## `llmctl decide schema | interactive`

| Command | Behaviour |
|---|---|
| `schema [--format json-schema\|openai-tool\|mcp]` | Emits the Typed Question schema as a tool definition for coding agents (no chat route is implied). |
| `interactive` | The single sanctioned interactive wizard; prompts to stderr, final JSON to stdout; non-TTY without `--interactive` is an error, never a hang; every prompt has a flag equivalent. |

## `llmctl decide calibrate | probe-order | completions`

Implemented in the `llmctl-decide` binary (`cmd/llmctl-decide/cmd_calibrate.go`, `cmd_probeorder.go`, `cmd_completions.go`; maths in `internal/calibrate`); `llmctl decide <name>` forwards to them. Numbers agree with the Python reference `scripts/golden/stats.py` (Wilson interval, baselines, ECE/MCE/Brier, 10 equal-width bins, no ECE claim below 200 labels); a golden-master test runs both on the same fixture.

| Command | Behaviour |
|---|---|
| `calibrate --profile P --labels F [--method temperature\|platt\|isotonic] [--assume-uncalibrated] [--catalog C] [--state-dir D] [--model-sha H] [--template-hash H] [--unbound] [--dry-run] [--json]` | Reads operator-labelled answers; reports accuracy ± Wilson 95% interval, the majority/chance baseline and ECE/MCE/Brier with a reliability table; fits the method on the confidence of the predicted answer; reports in-sample and 5-fold held-out ECE/MCE/Brier after the fit; writes the calibration profile bound to the model sha256 and the prompt-template hash. Pure computation (no network, no key). |
| `probe-order --questions F [--profile P] [--permute K] [--state-file F] [--endpoint U] [--cacert F] [--retries N] [--timeout S] [--json]` | Re-asks every choice question with its options in K cyclic orders (the rotation of `ask --permute`; K = 0, the default, is a full cycle) and prints, per question, the answer-flip rate and the per-listing-position share of the answers against the uniform expectation 1/n, plus an overall summary. Non-choice questions are listed as not permutable (no call). |
| `completions {bash\|zsh}` | Prints a completion script generated from the registered commands, their flags (captured from the live flag sets or the command's own usage text) and the subcommands named by the usage text of key/cert/port/registry/vantage; refuses any other shell with exit 2. No network, no key, no state. `eval "$(llmctl decide completions bash)"` (bash 3.2+), `source <(llmctl decide completions zsh)` after `compinit`. |

**Exit codes.** `calibrate`: 0 a report was produced (with or without a profile, see the refusals), 2 usage / unreadable or invalid labels / a bound profile was requested but a binding cannot be resolved (the report is still printed), 1 the profile could not be written. `probe-order`: the client contract (0 measured, 1 backend/readout failure, 2 usage – including "nothing to probe" –, 4 key, 5 certificate/TLS, 6 not ready/unreachable); a failed call aborts the run and prints no partial result. `completions`: 0, or 2 for a missing/unsupported shell or extra argument.

**Label file (`calibrate --labels`).** CSV with a header row (column names case-insensitive; unknown columns ignored): `p_pred` (required; aliases `confidence`, `p`) – the probability the answer gave to its own prediction, in [0, 1], empty for an answer that had none; and EITHER `correct` (0/1/true/false) OR both `expected` and `predicted` (compared as text; a malformed or empty answer is wrong, as in stats.py); **Calibrated answers:** `p_pred` is always the RAW winner probability (what `scripts/golden/run_golden.py` writes; the gateway never changes `probabilities`). Alias columns/fields, in this precedence when several are present: `p_pred` > `confidence_raw` > `confidence`. A row whose `calibration` cell/field is set (CSV: non-empty and not `0/false/no/none/-/null`; JSON: an object or `"mixed"`) was collected from a CALIBRATED gateway, so its `confidence` is already calibrated: if its probability can only come from `confidence` (no `p_pred`, no `confidence_raw`) and the row is well-formed, `calibrate` REFUSES the file (exit 2, naming the line/record) - fitting on it would double-calibrate - unless `--assume-uncalibrated` is passed (the report then says so; `assumed_uncalibrated: true`). Rows with a raw source are fitted on it (report fields `calibrated_rows`, `raw_source_rows`). Note `confidence_raw` is the gateway's shaped confidence (chance = 0), not a probability of being right: prefer `p_pred`. optional `id`, `type` (noul|choice|score; enables the per-type rows), `well_formed` (default true), `variant` (rows other than `orig` are skipped), `options` (aliases `option_count`, `scale`; feeds the chance baseline). Also accepted: the JSON written by `scripts/golden/run_golden.py` (`{"records": [...]}`) or a bare array of such records – records with `variant` other than `orig` and records without `expected` are skipped and counted; a record without `well_formed` is read as well-formed.

**Refusals (report printed, no profile written, exit 0).** Fewer than 200 calibration pairs: the report prints accuracy, interval and baseline and then "insufficient for ECE (n=…, need 200)" – no ECE/MCE/Brier number is printed or stored. `--method isotonic` with fewer than 1000 pairs (data-model §6). Labels that are all correct or all wrong (nothing to fit). `--dry-run` writes nothing.

**Profile.** `$STATE/decide/calibration/<profile>.json` (`$STATE` = `--state-dir`, `$LLMCTL_STATE_DIR`, `$XDG_STATE_HOME/llmctl`, `~/.local/state/llmctl`), directory 0700, file 0600, written atomically (temp file in the same directory, fsync, rename). Fields: `version`, `profile`, `bound`, `model_sha256`, `template_hash`, `method`, `params`, `n_samples`, `fitted_at`, `labels_source` (base name), `labels_sha256`, `metrics`. Binding: `--model-sha`/`--template-hash`, else the catalog (`profiles.<P>.files[role=model].sha256`, exactly one; `profiles.<P>.decision.template_hash`). If a binding cannot be resolved the command says what and exits 2 without writing a bound profile; `--unbound` writes `<profile>.unbound.json` instead (never the bound name), which a consumer must never apply. `internal/calibrate.LoadProfile(path, modelSHA256, templateHash)` refuses an unbound profile and either mismatch.

**Methods.** `temperature`: p' = σ(logit(p)/T), T from a golden-section search on the convex negative log-likelihood. `platt`: p' = σ(A·logit(p)+B), Newton with a backtracking line search, Platt's smoothed targets and a ridge toward the identity (finite on separable data). `isotonic`: pool-adjacent-violators on the raw confidences, stored as knots, linear interpolation, monotone non-decreasing. All deterministic; standard library only. These recalibrate the confidence of the answer the model already gave; they never change which option wins.

**Applied by the gateway (T137).** `llmctl-decide serve` loads the bound profile at start and on `SIGHUP`, replaces **only** the answer's `confidence` with the calibrated probability (adding `confidence_raw` and `calibration:{method,n,profile_id}`), and publishes `template_hash` and the calibration state on `GET /v1/models`; see `docs/decide-gateway.md`. The catalog still carries no `decision.template_hash`: when it is absent `calibrate` binds to the hash the gateway computes (`gateway.TemplateHash`, from the catalog entry and `LLMCTL_DECIDE_TEMPERATURE`), so no `--template-hash` is needed; a catalog value that disagrees with the computed one binds as given but prints a warning (the gateway would refuse that profile). The opt-in decision log of FR-080 is written by the gateway (`LLMCTL_DECIDE_LOG_STATE`, `LLMCTL_DECIDE_DECISION_LOG`), not by these commands.

## `llmctl cert`

| Command | Behaviour |
|---|---|
| `cert ensure` | Idempotent under lock; creates CA + leaf if absent; prints nothing secret. Called by every component before binding. |
| `cert show` | Paths, CA/leaf SHA-256 fingerprints, SANs, expiry, mode (`ca-leaf`/`selfsigned`/`byo`). |
| `cert export DEST` | Copies the **public** CA to DEST with mode 0644. |
| `cert renew [--reuse-key]` | Explicit: re-issues the leaf (new SAN set), swaps `current` atomically; never touches the CA. |
| `cert doctor` | Key/cert match, expiry (warn ≤ 30 d), SAN drift vs current interface addresses, permissions, OpenSSL flavour; macOS feature-detects `openssl`. |
| `cert reload` | Signals the gateway to re-read the pair (BYO/ACME rotation). |

## `llmctl key`

| Command | Behaviour |
|---|---|
| `key doctor` | Reports source (env/.env/none), shadowing, file mode, malformed values – never the value. |
| `key show` | The only command that prints the key; requires an explicit flag `--yes-print` to avoid accidents in scrollback. |
| `key rotate [--grace N]` | Generates a new key, writes `.env` atomically, prints the update checklist (clients, shell rc). |
| `key export [--file F] [--inline]` | Adds a managed block to the named startup file after showing exactly what it will write; idempotent; backup made; permission warning; reference form by default. |
| `key path` | Prints the `.env` path. |

## Existing commands (unchanged behaviour for chat profiles)

`llmctl plan [--json]` gains `decision_instances`. `llmctl auto decide` is new; `auto chat|coder|vision` unchanged. `llmctl models download <profile>` downloads and verifies decision profiles by the same rule (size + sha256, `.part` → atomic rename, evidence log) and reports a **skipped** smoke test as skipped, not verified. `llmctl doctor` gains checks for key, cert, venv, engine HTTPS, ports. `llmctl build onnx` prepares the hash-locked venv (never system-wide `pip`).

## Delta vs candidate

Candidate has `decide ask|capacity|status|interactive|serve` only; it takes the state on the command line, uses `LLMCTL_DECIDE_API_KEY`, quantises latency to seconds, has no `batch`, `scale`, `calibrate`, `probe-order`, `schema`, `completions`, `cert`, `key`. In the 3.1.0 binary `batch`, `schema`, `cert`, `key`, `mcp` and `smoke` exist; `calibrate`, `probe-order` and `completions` exist (OD-23); `scale` remains planned. Exit codes are 0/1/2 only.
