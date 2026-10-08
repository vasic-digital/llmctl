# Catalog schema additions — `models/catalog.json`

**Status**: draft contract. Validated by `tests/test_catalog_json.sh` (extended). Existing chat profiles are unchanged.

## Top level

`{ version, notes, ports, profiles }` as today. `ports` gains one entry per decision profile (unique values; collisions with other catalog ports fail the test; collisions with **host** listeners are detected at start, not in the catalog – this host already uses 8099/8100/8102).

## New / widened values

| Field | New allowed values | Notes |
|---|---|---|
| `engine` | `onnx` (new) | `llama` and `colibri` unchanged |
| `capability[]` | `decide` (new) | A profile carrying `decide` must not carry any chat capability |
| `min_tier` | `below-minimum` (new) | recommend-only, never blocks |
| `files[].role` | `tokenizer`, `config`, `head`, `mmproj` (new) | `model` unchanged |
| `files[].sha256` | **non-null** for every decision-profile file | the candidate's three `null`s are replaced by computed hashes (research/web-candidate-models §3.4) |
| `hf_revision` | 40-hex commit for decision profiles | `main` is not allowed for decision profiles |
| `decision` (new object) | see below | present iff `capability` contains `decide` |
| `license` (new) | SPDX string on an allow-list | weights licence; `cc-by-nc*`, missing, `NOASSERTION`, `other` are rejected |
| `provenance` (new) | `{ "benchmark": { "value": "…", "class": "vendor-measured\|independent\|llmctl-measured\|unverified" } }` | FR-052 |

### `decision` object

```json
"decision": {
  "protocol": "letter-logit",          // letter-logit | systemone-native | nli-onnx
  "max_options": 20,                   // practical cap for this profile (<=255; letter-logit <=26)
  "score_levels": [2, 10],
  "readout": { "n_probs": 32, "mass_threshold": 0.5, "spellings": ["A"," A"], "cache_prompt": false },   // letter-logit only
  "template_hash": "<64 hex>",         // DO NOT SET: the gateway computes it (see below); the catalog field is read only by `calibrate`
  "experimental": ["choice","score"],  // optional: types that are documented as experimental for this profile
  "release_date": "2026-10-07"         // optional YYYY-MM-DD shown as `release_date` in GET /v1/models (SDK listing); absent = the gateway's fixed default 2026-10-07; malformed = the gateway refuses the catalog
}
```
The profile's top-level `desc` is the SDK listing's `description`.

**`decision.template_hash` is computed, not stored (T137).** The gateway computes it in Go (`gateway.TemplateHash`) and publishes it per profile on `GET /v1/models`; it never reads a catalog value. It is the lowercase-hex SHA-256 of a canonical document holding the template version tag, the protocol and: *letter-logit* - the prompt the gateway really sends (`contract.RenderPrompt` of a fixed canonical question and state), the readout `spellings` (in order), `n_probs` and the effective `LLMCTL_DECIDE_TEMPERATURE` (unset = 1); *systemone-native* - the hosted-shape request body the gateway forwards for a fixed canonical request (a noul, a choice and a score question); *nli-onnx* - the premise/hypothesis construction (`DefaultHypothesis`) and the scorer convention. `mass_threshold`, `cache_prompt`, the profile id and the model file are **not** hashed (the model file is bound separately by `files[role=model].sha256`). Any change to the prompt template or the hashed parameters changes the hash and therefore invalidates every calibration profile bound to the old one - deliberately; `internal/gateway/templatehash_test.go` pins the three values so such a change is a conscious edit.

## Example 1 – existing candidate profile with the new fields (pins copied from the candidate catalog, re-verified on huggingface.co 2026-10-07)

```json
"decide-tiny": {
  "capability": ["decide"],
  "min_tier": "below-minimum",
  "port": 8092,
  "defaults": { "ctx": 4096, "ngl": 99, "parallel": 1, "flash_attn": "auto", "kv_cache_type": "q8_0" },
  "engine": "llama",
  "hf_repo": "chaoliangUNSW/Jev-Style-0.8B-Decision-v3-GGUF",
  "hf_revision": "edf37c26a1098f83cf4264b8adbe0dca2d2ebb0c",
  "license": "Apache-2.0",
  "provenance": { "benchmark": { "value": "79.2% on 2,000 typed decisions per model card", "class": "vendor-measured" } },
  "decision": { "protocol": "letter-logit", "max_options": 20, "score_levels": [2,10],
                "readout": { "n_probs": 32, "mass_threshold": 0.5, "spellings": ["A"," A"], "cache_prompt": false },
                "template_hash": "sha256:<generated at build>" },
  "files": [
    { "name": "Jev-Style-0.8B-Decision-v3-Q4_K_M.gguf", "size": 529296864,
      "sha256": "0a19bc29bacc33e0d871146c8612b24dd14c2ed2e61cedeb7a928b0852628bac", "role": "model" }
  ]
}
```
(`parallel` changes from the candidate's 4 to 1: deterministic mode, FR-074; a `throughput` mode raises it.)

## Example 2 – native-protocol candidate (status: ADMIT-CANDIDATE, **not shipped** until the engine gate and a real run pass)

```json
"decide-laya": {
  "capability": ["decide"],
  "min_tier": "below-minimum",
  "engine": "llama",
  "hf_repo": "ggml-org/Laya-GGUF",
  "hf_revision": "22265007700297ba9e128297e82540cf28c5d7d4",
  "license": "Apache-2.0",
  "decision": { "protocol": "systemone-native", "max_options": 255, "score_levels": [2,10] },
  "files": [ { "name": "Laya-Q8_0.gguf", "size": 449397600,
               "sha256": "c06528c5746d3bb8baa72a27938be95abbfd0b226f8471e8a9e365ed0bb066d2", "role": "model" } ]
}
```
Port is assigned from the free range at admission; requires engine build ≥ b11361 (FR-085).

## Validation rules (all enforced by `test_catalog_json.sh`)

1. Unique ports; every profile with `decide` has a `decision` object with a legal `protocol` matching its `engine` (`onnx` ⇒ `nli-onnx`).
2. Decision profiles never list a chat capability; `auto chat|coder|vision` ranking functions never return one (tested).
3. Every file of a decision profile has `size` and non-null 64-hex `sha256`; `hf_revision` matches `^[0-9a-f]{40}$`.
4. `license` is on the allow-list; `provenance.benchmark.class` is in the closed set.
5. Profile names contain no `.`.
6. A mutation test removes one sha256 / changes one revision / adds `cc-by-nc-4.0` and requires the validator to FAIL (paired mutation, FR-041).
