# Live `llmctl vision validate` run - 2026-10-12

| Field | Value |
|---|---|
| Revision | 1 |
| Date | 2026-10-12 |
| Status | **PENDING - no real-model run has been performed** |
| Subject | `llmctl vision validate` / `llmctl validate <profile>` against a real llama-server |

## What this document is

The evidence page for the first live run of the model validation gate ([validation](../validation.md#model-validation-gate)). It exists so the gap is
written down; it is **not** a pass.

## Honest status

* **No real model has been run through any validation suite yet.** No `llama-server` was started, no vision model was loaded, no screenshot was sent to
  a real model, for this page or for any commit that introduced the gate. There is no captured model answer, no verdict and no state record from a real
  model anywhere in the repository.
* What exists is hermetic evidence against a fixture OpenAI-compatible server that answers from a table (`tests/test_vision_validate.sh`,
  `tests/test_validation_suites.sh`, `tests/test_validation_gate_defects.sh`). That proves the judge, the controls, the exit codes, the state record and
  the hooks behave as specified when an endpoint answers; it says nothing about whether `gemma-3-4b-it` (profile `vision`), `vision-pro`, `fast`,
  `coder` or any other profile gives the right answers.

## UNKNOWN / PENDING

| Question | Status |
|---|---|
| Does the `vision` profile (Gemma 3 4B + mmproj) pass all 18 probes, both golden-bad controls and the determinism repeat? | UNKNOWN |
| Is the answer byte-identical on a repeated request with the real engine build (temperature 0, seed 42, top_k 1)? | UNKNOWN |
| Do the probe prompts and `max_tokens` (200) fit the real model's answer style (no false FAIL from verbosity, no truncation)? | UNKNOWN |
| Do `chat-v1` / `coder-v1` pass on a real chat and a real reasoning model (budget 2048)? | UNKNOWN |
| Does `embedding-v1` pass on a real embedding profile? | UNKNOWN - no catalog profile serves embeddings |
| Do the typed-decision profiles have any validation? | No suite; reported UNDETERMINED by design (catalog `validation.reason`) |

## How the run is to be recorded (when it happens)

1. Host safety first: `head -2 /proc/pressure/memory` must show every `some avg10` at or below 5; run one profile at a time.
2. `llmctl models verify vision` (checksums), then `llmctl vision validate --keep` against the downloaded profile.
3. Paste the raw command output, the exit status, the contents of `$LLMCTL_VERIFY_DIR/validate-vision.log` and `$LLMCTL_STATE_DIR/validation/vision.json`
   into this page, with the engine build tag and the model file sha256. A wrong answer is recorded as a FAIL with the model's raw answer - never edited
   to pass, never excused by loosening a check.

Until that section is filled with a captured run, treat every profile as **not validated**: `llmctl require-validated <profile>` refuses, which is
the correct answer.
