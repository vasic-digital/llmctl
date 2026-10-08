# Research briefs (decision-models feature)

**Revision:** 2
**Last modified:** 2026-10-06T00:00:00Z

Background research compiled (October 2026) before and during the
implementation of llmctl's decision-models feature. These are *inputs to
the design*, copied into the repo with attribution intact — where a brief
and the shipped code disagree, the code wins (see
[`docs/decision-models.md`](../decision-models.md) and
[`docs/decide-gateway.md`](../decide-gateway.md) for what exists).

| Brief | Contents |
|---|---|
| [`jev-ecosystem.md`](jev-ecosystem.md) | The Jev / TypeSafe AI "System One" ecosystem survey: official API wire format and SDKs, accuracy standings (with [VERIFIED]/[SECONDARY]/[VENDOR]/[UNVERIFIED] labels per claim), and the open-source local replications the shipped profiles were chosen from |
| [`decision-model-hashes.md`](decision-model-hashes.md) | **Decision Model Candidates — Verified HF Metadata**: the raw HF API (`hf-mirror.com`) filenames, byte sizes, sha256 values, revisions, and licenses used to pin the `decide-tiny` / `decide` / `decide-pro` catalog entries on 2026-10-06 |
| [`encoder-model-hashes.md`](encoder-model-hashes.md) | **Encoder-Class Decision Models — Verified HF Metadata**: the raw HF API values used to pin the iteration-2 entries `decide-nli` (DeBERTa-v3-large zeroshot NLI ONNX, `onnx` engine) / `decide-2b` / `decide-max` (JevK5 GGUFs) on 2026-10-06, plus the verification that `convaiinnovations/laya` ships no prebuilt ONNX (the basis for the documented BYO-ONNX path) |
| [`llmctl-architecture.md`](llmctl-architecture.md) | A map of this repo written for implementers; it was the implementation reference for the decision-models feature (header note inside records this) |
