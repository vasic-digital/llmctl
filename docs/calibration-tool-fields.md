# Fields a calibration tool may rely on

**Revision:** 1 - 2026-10-08. Source of truth: `specs/009-jev-decision-models/contracts/openapi.yaml` (contract version `3.1.0-draft`) and the
gateway/calibrate code it describes. This page lists which response fields an external calibration or evaluation tool can read, what each one
means, and what is **not** promised. Related: [decide-gateway](decide-gateway.md), [decision-models](decision-models.md), [limitations](limitations.md),
[golden-set](golden-set.md).

## Fields on a typed answer (`POST /v1/systemone`)

| Field | On | Meaning (from the contract) | Use for calibration |
|---|---|---|---|
| `probabilities` | choice, score | Option key (or level index) to probability; sums to 1 within 1e-6. **Never changed by calibration** | The raw readout: the input a recalibrator fits on (`p_pred` = its largest value) |
| `choice` / `score` / `noul` | per type | The winner / expected level / yes-probability | The answer being judged. `noul` has no `confidence` |
| `confidence` | choice, score | Shaping convention `(p_max - 1/n) / (1 - 1/n)` (chance level 0). When `calibration` is present it is instead the calibrated probability of being right (chance level 1/n) | Do not mix the two scales; check `calibration` first |
| `confidence_raw` | choice, score | The shaped value before calibration; present only with `calibration` | Audit; it is **not** a probability of being right |
| `calibration` | choice, score | `{method, n, profile_id}`; present only when a profile was applied | Tells you the answer is already calibrated, so refitting on `confidence` would double-calibrate |
| `flags`, `upper_bounds` | all | `flags:["option_missing"]` plus per-option upper bounds when the engine did not list an option letter; probabilities are then the worst case | Treat flagged answers separately; absent options are upper bounds, never an exact 0 |
| `legend` | score | Level index to description | Level labels |

Response headers on 200: `x-llmctl-request-id` and `x-llmctl-decide-mode` (`deterministic` or `throughput`) are always present;
`x-llmctl-decide-instance` (which engine instance answered; byte-identity is promised per instance only) is present only when the backend reports one; `x-llmctl-decide-truncated: true`
only when the opt-in state-shortening setting shortened the state.

## Fields on `GET /v1/models`

`data[].id`, `aliases`, `protocol` (`letter-logit`, `systemone-native`, `nli-onnx`), `status`, `limits`, `notes`, `template_hash` (SHA-256 of the
rendered prompt template and the readout parameters; the gateway computes it) and `calibration`, which appears only when a profile file exists for the model (`{applied:true, method, n, profile_id}` or
`{applied:false, reason}` with reason one of `mismatch|unbound|invalid|insecure|model_unresolved`). A calibration tool should record
`template_hash` with every label set: a changed prompt, readout parameter or `LLMCTL_DECIDE_TEMPERATURE` changes it and invalidates earlier fits.

## Files a calibration tool may read or write

`llmctl-decide calibrate` reads a labels file (CSV or `run_golden.py` JSON) and writes `$STATE/decide/calibration/<profile>.json` (mode 0600; an unbound profile is `<name>.unbound.json` and must never be applied)
with `version, profile, bound, model_sha256, template_hash, method, params, n_samples, fitted_at, labels_source, labels_sha256, metrics`
(`contracts/cli.md`). The gateway loads it at start and on `SIGHUP` only if it is bound, owned by the gateway user, not group/other-writable,
and both hashes match. Fewer than 200 labelled pairs supports no ECE claim (SC-003); the tooling prints none.

## Stability statement

* The field names above are the ones the OpenAPI document declares; its objects use `additionalProperties: false`, so a client can rely on
  the listed names and types for the contract version it was written against.
* Fields marked `[HOSTED]` mirror the hosted API's documented shape; fields marked `[LLMCTL]` (`confidence_raw`, `calibration`, `flags`,
  `upper_bounds`, `template_hash`, the `x-llmctl-*` headers) are llmctl additions and are additive.
* The contract is versioned `3.1.0-draft`. **No deprecation policy or semantic-versioning guarantee for these fields has been published**:
  UNKNOWN beyond that. Pin the llmctl version you calibrate against and re-check `template_hash` and `calibration.applied` after an upgrade
  ([runbooks](runbooks.md#upgrade-and-rollback)).
* Calibration recalibrates confidence only; it never changes which option wins, and it is not a safety guardrail ([limitations](limitations.md)).
