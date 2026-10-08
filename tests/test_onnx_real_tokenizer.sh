#!/usr/bin/env bash
# test_onnx_real_tokenizer.sh - D-01 / G-017 regression guard with the REAL DeBERTa-v3
# SentencePiece tokenizer (the hermetic suite test_onnx_runtime.sh only has a stub tokenizer).
# Property: with a ~600-token premise the shipped runtime keeps the whole hypothesis and
# both [SEP] tokens, cuts only the premise, and reports truncated=true. Paired mutation:
# a runtime variant that truncates the pair from the end (the candidate's original defect)
# MUST FAIL the same check, otherwise the guard is decoration.
# SKIPs the whole suite (printed) when the tokenizer file or a Python with sentencepiece is
# not available; provide the file with LLMCTL_REAL_SPM or run `llmctl models download decide-nli`.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

RUNNER="${LLMCTL_ROOT}/lib/onnx_server.py"
CHECK="${LLMCTL_ROOT}/tests/fixtures/onnx_real_tokenizer_check.py"
DATA="${LLMCTL_DATA_DIR:-${XDG_DATA_HOME:-${HOME}/.local/share}/llmctl}"

SPM=""
for cand in "${LLMCTL_REAL_SPM:-}" "${DATA}/models/decide-nli/onnx/spm.model" "${DATA}/models/decide-nli/spm.model"; do
  [[ -n "${cand}" && -f "${cand}" ]] && { SPM="${cand}"; break; }
done
[[ -n "${SPM}" ]] || skip_suite "real DeBERTa spm.model not present (set LLMCTL_REAL_SPM or run: llmctl models download decide-nli)"

# the pinned file must be the pinned file: size + sha256 from the catalog (never a stale/other tokenizer)
WANT_SHA="$(python3 -c 'import json,sys;c=json.load(open(sys.argv[1]));print(next(f["sha256"] for f in c["profiles"]["decide-nli"]["files"] if f["role"]=="tokenizer"))' "${LLMCTL_ROOT}/models/catalog.json")"
GOT_SHA="$(sha256sum "${SPM}" | cut -d' ' -f1)"
[[ "${WANT_SHA}" == "${GOT_SHA}" ]] || skip_suite "tokenizer ${SPM} does not match the catalog sha256 (${GOT_SHA} != ${WANT_SHA}); refusing to assert on an unpinned file"

PY=""
for cand in "${LLMCTL_ONNX_PY:-}" "${DATA}/venv-onnx/bin/python" python3; do
  [[ -n "${cand}" ]] || continue
  command -v "${cand}" >/dev/null 2>&1 || continue
  if "${cand}" -c 'import sentencepiece, numpy' 2>/dev/null; then PY="${cand}"; break; fi
done
[[ -n "${PY}" ]] || skip_suite "no python with sentencepiece+numpy (run: llmctl build onnx, or set LLMCTL_ONNX_PY)"

test_setup_env

out="$("${PY}" -I "${CHECK}" "${RUNNER}" "${SPM}" 2>&1)" && rc=0 || rc=$?
printf '%s\n' "${out}" | sed 's/^/    /'
assert_eq "0" "${rc}" "shipped runtime keeps hypothesis + both [SEP], truncates only the premise (real tokenizer)"
assert_contains "${out}" "ok   hypothesis tokens intact before the final [SEP]" "hypothesis-intact check actually ran"

# paired mutation: premise-only -> end-truncation (the candidate's defect). Replacement must really happen.
MUT="${TEST_TMP}/onnx_server_mutant.py"
python3 - "${RUNNER}" "${MUT}" <<'PY'
import sys
src = open(sys.argv[1]).read()
old = "            p_ids = p_ids[:budget]\n            ids = [self.cls_id] + p_ids + [self.sep_id] + h_ids + [self.sep_id]\n"
new = "            ids = ([self.cls_id] + p_ids + [self.sep_id] + h_ids + [self.sep_id])[:self.max_tokens]\n            p_ids = p_ids[:budget]\n"
if src.count(old) != 1:
    sys.exit("mutation anchor not found exactly once; update the mutation with the code")
open(sys.argv[2], "w").write(src.replace(old, new))
PY
mout="$("${PY}" -I "${CHECK}" "${MUT}" "${SPM}" 2>&1)" && mrc=0 || mrc=$?
assert_eq "1" "${mrc}" "mutant (end-truncation, candidate defect D-01) FAILS the real-tokenizer guard"
assert_contains "${mout}" "FAIL hypothesis tokens intact" "mutant is caught by the hypothesis-intact check"

test_finish
