# Golden question set for decision models

Spec 009 (SC-003, FR-080, plan P4). A small, hash-pinned set of labelled questions that is run
through `POST /v1/systemone` to measure how well a decision profile answers, with the number
published next to its sample size, a confidence interval and the trivial baseline computed by the
same tool.

## What is in it

| File | Content |
|---|---|
| `tests/fixtures/golden/questions.jsonl` | 132 labelled items: 60 `noul` (yes/no), 41 `choice`, 31 `score` |
| `tests/fixtures/golden/probes.jsonl` | 23 adversarial probes (forged option lines, instruction injection, arithmetic, date reasoning, double negatives, irrelevant-state sensitivity, misleading options, minimal state) |
| `tests/fixtures/golden/MANIFEST.json` | sha256 of both files, counts per type / class / option count / scale, label balance |
| `scripts/golden/` | `run_golden.py`, `stats.py`, `similarity.py`, `build_manifest.py`, `verify_manifest.py` |

Coverage of the questions file:

* `choice` option counts 2 (6 items), 3 (7), 4 (7), 5 (6), 8 (6), 12 (5), 20 (4): the points of the
  accuracy-vs-option-count curve.
* `score` scales 2 to 10, between 3 and 5 items each.
* Realistic coding-workflow material: dangerous shell commands, urgent emails, spec-vs-code checks,
  security-review triage, department routing, model-tier choice, conventional commit types, language and
  shell-command identification, HTTP status codes, CI and test-log counting.
* **Imbalanced subsets on purpose.** `is_urgent` is 17 false / 3 true (85% majority) and
  `needs_security_review` is 9 / 3 (75%): an always-no model scores 85% and 75% there, which is the
  "79% majority baseline trap". The report therefore carries per-class accuracy and a per-family
  majority baseline, and a family only "clears" when the Wilson lower bound beats its own majority share.
* Genuinely ambiguous items were left out; every item has one defensible label.

Each item has `id`, `type`, `class` (the question family), `difficulty`, `state`, `instructions`,
`criteria`, `expected` (bool for noul, option key for choice, level index for score), plus `language`
(`en`), `source`, `license` and `labeled_by`. Choice items carry `option_count` and `perm_group`; score
items carry `scale`. Probes carry `probe_class`, `expected_behaviour` and, for irrelevant-state pairs,
`pair_id` / `pair_variant`.

## Limits (read before quoting a number)

* **Agent-authored, not human-labelled.** Every item says `labeled_by: agent-authored;
  human-review-pending`. Labels were written by an agent and have not been independently reviewed by a
  person yet. Treat accuracy as "agreement with the authored labels". `verify_manifest.py` refuses a set
  whose items do not carry an honest provenance string.
* **English only.** No other language is covered; nothing here says anything about multilingual behaviour.
* **Not a safety benchmark.** `dangerous_command` and `needs_security_review` are ordinary classification
  tasks over short texts. They do not qualify a model to gate real commands or reviews. The probes show
  failure modes; they are not a security assessment.
* **No calibration claim.** 132 labelled items are fewer than the 200 required. `stats.py` prints
  `insufficient for calibration` instead of ECE, MCE and Brier until at least 200 labelled items have
  been answered. Do not quote or infer a calibration figure from this set.
* **Small samples.** With 31 to 60 items per type the intervals are wide (for example 8 of 10 correct
  gives 0.49 to 0.94). Use the interval, not the point value.
* **Original content.** Every item was written for this project. No item of JevBench or any other third
  party benchmark is reproduced; the public JevBench tier is run separately through its own adapter and
  labelled as public-tier (contamination possible).
* **Position bias is measured, not removed.** The flip-rate probe shows sensitivity to option order for
  the tested profile; it does not fix it.

## JevBench public tier

`scripts/bench/jevbench_adapter.py` runs the upstream JevBench harness (`python -m jevbench.cli run --adapter typesafe
--endpoint URL --key-env LLMCTL_API_KEY --model PROFILE ...`) against the decide gateway and writes `RUN/summary.json`.
It is always labelled `tier: public-tier`, `contamination: possible`, `official_score: false`, and refuses to run without
`--public-tier`. It is not an official score: the public items may be in training data, and the licences of the upstream
easy (48) and hard (111) splits are UNCONFIRMED (only the harness and the 72 original public items are MIT).

```bash
git clone https://github.com/fstandhartinger/jevbench ~/jevbench   # outside this repository
python3 scripts/bench/jevbench_adapter.py --public-tier --verify-only --jevbench-dir ~/jevbench \
    --expect-commit bb05a335bc809e61b20c0f745d25499a82b326fc --run-dir /srv/runs/jb1          # provenance check only
LLMCTL_API_KEY=... python3 scripts/bench/jevbench_adapter.py --public-tier --jevbench-dir ~/jevbench \
    --expect-commit bb05a335bc809e61b20c0f745d25499a82b326fc --splits original \
    --endpoint https://127.0.0.1:8095 --model llmctl-default --ssl-cert-file ~/.config/llmctl/ca.pem \
    --run-dir /srv/runs/jb1 --evidence-dir specs/009-jev-decision-models/evidence/jevbench/llmctl-default
```

* Fail closed: the checkout must be at `--expect-commit` (exactly 40 hex digits) with a clean tree, and the sha256 of each split must equal the
  upstream `datasets/manifest.json` value, otherwise exit 2 and nothing runs. "Clean" covers tracked, untracked AND gitignored files
  (a gitignored file can still change the harness); `__pycache__` / `*.pyc` are tolerated and the child runs with
  `PYTHONDONTWRITEBYTECODE=1`. The run directory and the checkout are compared by real path (a symlink into the checkout is refused).
  Duplicate task ids across the selected splits and empty `--allow-licence` entries are refused (exit 2).
* The child is started as `python -E -s -m jevbench.cli run ...` (argv list, no shell, no inherited `PYTHONPATH`). `SSL_CERT_FILE` is set in the
  child environment only. `--harness-cmd` replaces the launcher (tests only) and is recorded as `harness_override: true` in the summary.
* Tally table (every scored item lands in exactly one bucket): **answered** (200, valid distribution; then correct / wrong), **refused**
  (HTTP 422, 502, 503, 529 and timeouts, `refused_by_status` names the code, `timeout` for timeouts), **malformed** (the gateway answered 200
  but the answer could not be parsed or was invalid), **failed_other** (everything else: 401, 403, **429**, 5xx not listed, connection
  refused ...). 429 is deliberately `failed_other`, not a refusal: the caller was throttled, the gateway did not decline the item; the
  summary also names it in `access_stop`.
  Accuracy is reported over all scored items and over answered items, each with a Wilson interval, plus the majority/chance baseline.
* Calibration: only when at least 200 items are licence-clean (licence in `--allow-licence`, default MIT; expected not null; no
  exclude reason) and answered. Below that the summary says `insufficient: N<200` and no CSV is written; at 200 or more a
  `calibration.csv` (`p_pred,correct`) is written that `llmctl-decide calibrate --labels` accepts.
* An HTTPS gateway with a private CA: the harness uses urllib, which honours `SSL_CERT_FILE`; `--ssl-cert-file` sets it for the child only.
* The run directory (raw responses, ledger, results) stays outside git. Tracked evidence gets item ids and aggregates only, and a README
  saying raw outputs stay out of git unless every item is MIT.
* Verified against the upstream source at the pinned commit (`jevbench/cli.py`, `runner.py`, `adapters/typesafe.py`) and by
  `tests/py/test_jevbench_adapter.py::RealHarnessContractTests`, which runs the REAL stdlib harness against a stand-in gateway (skipped with a
  reason when `~/.cache/jb/jevbench` is not at the pinned commit; clone it shallow there to run it): the CLI flags, the result field names
  (`task_id ok valid correct predicted probs status_code model error`) and the exit code 3 of an incomplete harness run.
* The harness stops after 3 consecutive non-422 errors or right after a 401/403/429 answer (upstream `Runner.run_all`). The adapter then
  exits 3 explicitly: `summary.complete` is false when items are unattempted, and `summary.access_stop.status_codes` names the code, which also
  makes the exit 3 when the stop answer was the last item. An unparseable or duplicated line in `results.jsonl` also yields exit 3 with
  `results_unparseable_lines` / `results_duplicate_ids` and `complete: false` (the summary is still written).

## How to run

```bash
# shape check, no network, no state text printed
python3 scripts/golden/run_golden.py --base-url https://127.0.0.1:8095 --profile llmctl-default --dry-run

# smoke run
LLMCTL_API_KEY=... python3 scripts/golden/run_golden.py --base-url https://127.0.0.1:8095 \
    --cacert ~/.config/llmctl/ca.pem --profile llmctl-default --limit 6 --types noul,choice

# full run with the option-order flip probe, then the probes
LLMCTL_API_KEY=... python3 scripts/golden/run_golden.py --base-url https://127.0.0.1:8095 \
    --cacert ~/.config/llmctl/ca.pem --profile llmctl-default --permute-groups
LLMCTL_API_KEY=... python3 scripts/golden/run_golden.py --base-url https://127.0.0.1:8095 \
    --cacert ~/.config/llmctl/ca.pem --profile llmctl-default --set probes --run-id probes-1
```

* The key comes from the environment variable named by `--key-env` (default `LLMCTL_API_KEY`) or from
  `--key-file`; it is never taken as an argument value, never logged and never written. A response
  containing the key is redacted, and a results file containing it is refused.
* Each item is one request with one question named `q`. Retries are bounded (`--retries`, default 2) and
  only for 429, 502, 503, 529 and transport errors, honouring a capped `Retry-After`.
* Stdout and logs carry item ids, status and latency only, never state text.
* `--permute-groups` re-asks every choice item with a deterministic permutation (`--seed`) whose option
  order differs from the original and moves the labelled answer to another position.
* Evidence class defaults to `real-model`. Use `--evidence-class stand-in` for any run not against the
  real model; stand-in records are excluded from real-behaviour summaries by `tests/evidence/writer.py`.

Output directory (default `docs/qa/009-jev-decision-models/<run-id>/`):
`results.json` (meta, report, every record), `raw/responses.jsonl` (raw answers with request ids and
latency), `evidence.jsonl` (hash-chained records per `contracts/evidence-schema.md`), `MANIFEST.json` and
`SHA256SUMS`. Verify with `python3 tests/evidence/manifest.py verify DIR` and
`python3 tests/evidence/writer.py verify-chain DIR/evidence.jsonl`. Re-print a report with
`python3 scripts/golden/stats.py DIR/results.json`.

## How results are judged

`stats.py` computes everything from the same records:

1. **Well-formed rate.** SC-003 first clause: every item must produce a well-formed typed answer
   (right type, probability in range, choice is one of the options, probabilities sum to 1, score within
   0 to n-1). A malformed answer counts as wrong and fails the first evidence record.
2. **Accuracy with a Wilson 95% interval**, per type. Score accuracy is exact level after rounding; a
   within-one-level figure is shown beside it.
3. **Baselines from the same tool.** Per type the larger of the majority-class share of the expected
   answers and the chance level (mean of 1/options). Verdict: the interval's **lower bound must exceed
   the baseline**. A profile that does not clear it is not shipped, or ships labelled experimental with
   its measured numbers; the evidence record for this check is `fail` with the reason.
4. **Per-class accuracy** (class = expected answer) and **per-family accuracy** with the family's own
   majority share, to expose models that win by always answering the common class.
5. **Option-order flip rate** (FR-080): of the permutation groups with at least two well-formed answers,
   the share whose answer changes with the order. Recorded `not-exercised` when `--permute-groups` was not used.
6. **Accuracy vs option count** (choice) and vs scale (score) with intervals, for the "practical option
   limit" finding.
7. **Calibration** (ECE, MCE, Brier over ten equal-width confidence bins) only when at least 200 labelled
   items were answered; otherwise the literal text `insufficient for calibration`. The probability fed
   to it is always `p_pred`, the winner's own **raw** probability. When the gateway under test applies a
   calibration profile (FR-080) each record also keeps `confidence` (what it served, calibrated),
   `confidence_raw` and `calibration`; they are recorded for inspection and are never used for ECE, so a
   calibrated gateway cannot flatter its own evaluation. `stats.py` prints `calibrated gateway: N records
   ...` (JSON: `calibrated_records`, `calibration_input`) when any record carries a profile. These
   result files can be given to `llmctl decide calibrate --labels`: `p_pred` is the raw source, so the
   file is accepted; a file lacking it is refused unless `--assume-uncalibrated` is passed.
8. **Probes** are reported separately (`--set probes`): accuracy where a label exists, well-formedness
   for the rest (misleading-option probes have no label by design), and pair agreement for the
   irrelevant-state pairs. Probe failures are findings about the model, not harness faults.

## Adding or changing items

1. Edit `questions.jsonl` (or `probes.jsonl`) by hand. One JSON object per line, all required fields,
   a unique `id`, `labeled_by` kept honest (change it only when a named human has reviewed that item,
   for example `human-reviewed: <initials> <date>`). Do not template items from each other and never copy
   third-party benchmark items.
2. Keep an unambiguous label. If two reasonable readers could disagree, drop the item.
3. `python3 scripts/golden/similarity.py tests/fixtures/golden/questions.jsonl tests/fixtures/golden/probes.jsonl`
   must pass: same-label pairs stay below 0.80 and no pair reaches 0.92 (character 4-gram Jaccard of the
   state text). Deliberate minimal contrast pairs with different labels are listed, not failed.
4. `python3 scripts/golden/build_manifest.py` then `python3 scripts/golden/verify_manifest.py`.
5. Run the unit tests: `python3 -B -m unittest tests.py.test_golden_stats tests.py.test_golden_runner tests.py.test_golden_manifest`.
6. A changed set invalidates earlier results: reports quote the fixture sha256 stored in `results.json`.

Current reference values (recorded, not typed by hand elsewhere): see `MANIFEST.json`. The maximum
pairwise similarity at the time of writing is 0.890 overall (an intentional contrast pair) and 0.213
among pairs sharing a label.

## Licence

CC0-1.0 / the project licence, as stated in every item.
