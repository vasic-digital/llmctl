# anton decide (Mapika decider-4b v2.1 Q4_K_M) after the thinking fix - SMOKE FAILED, full matrix NOT run (2026-10-09)

- Host anton, CPU engine (`-ngl 0`), GGUF `decider-4b-v2.1-Q4_K_M.gguf` (downloaded this run, size+sha256 verified). Tree: HEAD `c5301defb73a949536fe741b597d3bd089df4109` + UNCOMMITTED letter.go/resolver.go; binary sha256 `0c16f65a...a50f`. Run under `bounded-run -m 10G -t 500 -T 5400`, PSI watchdog (never fired; max full avg10 0.00).
- Smoke (3 choice questions): **1/3 well-formed** (`smoke.log`, `smoke/`): C-001, C-002 -> HTTP 422 `readout_failed` ("The model produced no usable answer for this question."), C-003 -> 200 success p=0.998. The run was stopped after smoke (golden/probes NOT run; `golden/` here is empty). The built-in `llmctl models download decide` smoke at ctx 512 also failed 2/2 (`~/.local/state/llmctl/verify/decide.log`) - a separate, pre-existing observation.
- 422 reason code: `{"error_type":"readout_failed"}`; it is a model/readout failure, not a max_options refusal (2 options only).

## Root cause (diag/, first-token top_logprobs captured from the engine for the exact gateway request bodies `diag/gateway-to-engine-bodies.jsonl`)

| request | variant | content / reasoning_content | letter mass in top-32 (A+B) | top-32 total mass |
|---|---|---|---|---|
| C-001 (expected A) | with `chat_template_kwargs.enable_thinking=false` (what the gateway sends) | `A` / none; A -0.84 (0.43), `<think>` -5.7 | 0.44 | 0.47 |
| C-001 | without kwargs | empty / `A` (reasoning); A -2.16, `We` -2.2, `The` -2.7 | 0.12 | 0.36 |
| C-002 (expected B) | with kwargs | `B` / none; B -0.79 (0.46) | 0.47 | 0.49 |
| C-002 | without kwargs | empty / `B`; B -2.06 | 0.13 | 0.32 |

The thinking fix works for this model too (letters move from 0.12 to 0.44-0.47 of the mass and the answer is delivered in `content`), but the model spreads >50% of first-token mass over tokens outside the top 32, so the combined option-letter mass (0.44-0.47) is below the catalog `mass_threshold` 0.5 and the gateway refuses (422 readout_failed). C-003 (mass ~1.0) passes. Conclusion: decide is a diffuse-first-token model for this prompt format, not a wiring defect; options (not applied, catalog untouched): lower mass_threshold for this profile with evidence, or a different prompt/readout. Raw: `diag/top_logprobs.json`, `diag/engine-diag.log`.

Caveats: n=3 smoke only; no accuracy figure exists for this profile. Nothing committed.
