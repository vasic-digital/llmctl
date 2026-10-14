#!/usr/bin/env bash
# validation_local_lib.sh - shared hermetic fixture for the LOCAL validation path (sourced by test_validation_*.sh after
# helpers.sh + test_setup_env). Nothing here is a model: the "model files" are small byte strings, the catalog is a COPY
# of models/catalog.json whose `vision` file pins are re-pinned to those bytes (so the catalog-pin check is exercised for
# real), the engine is a stub that only prints a version line, and the endpoint is tests/fixtures/validation/fake_openai.py
# (an answer table). No real llama-server, no real profile, no real unit is started or stopped.
#
#   vl_setup                     catalog copy + model files + stub engine + hermetic machine id
#   vl_fake_start <answers> [args...]   start the fixture server (model id = the vision model PATH); prints the URL
#   vl_mark_running <port>       write the vision reservation (.run) on <port>
#   vl_rc <cmd...>               run, capture output in ${TEST_TMP}/last.out, echo the exit code
VL_FIX="${LLMCTL_ROOT}/tests/fixtures/validation"
VL_LLMCTL="${LLMCTL_ROOT}/bin/llmctl"
VL_PIDS_FILE="${VL_PIDS_FILE:-$(mktemp)}"

vl_cleanup() {
  local p
  if [[ -f "${VL_PIDS_FILE}" ]]; then
    while read -r p; do [[ -n "${p}" ]] && kill "${p}" 2>/dev/null || true; done < "${VL_PIDS_FILE}"
    rm -f "${VL_PIDS_FILE}"
  fi
}

vl_setup() {
  export LLMCTL_VALIDATE_TIMEOUT=20 LLMCTL_VALIDATE_HERMETIC=1
  export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
  mkdir -p "${LLMCTL_MODELS_DIR}/vision" "${TEST_TMP}/bin"
  printf 'fixture gguf bytes: gemma-3-4b-it-Q4_K_M\n' > "${LLMCTL_MODELS_DIR}/vision/gemma-3-4b-it-Q4_K_M.gguf"
  printf 'fixture gguf bytes: mmproj-model-f16\n' > "${LLMCTL_MODELS_DIR}/vision/mmproj-model-f16.gguf"
  VL_MODEL="${LLMCTL_MODELS_DIR}/vision/gemma-3-4b-it-Q4_K_M.gguf"
  export LLMCTL_CATALOG="${TEST_TMP}/catalog.json"
  python3 -I - "${LLMCTL_ROOT}/models/catalog.json" "${LLMCTL_CATALOG}" "${LLMCTL_MODELS_DIR}/vision" <<'PY'
import hashlib, json, os, sys
d = json.load(open(sys.argv[1]))
for f in d["profiles"]["vision"]["files"]:
    b = open(os.path.join(sys.argv[3], f["name"]), "rb").read()
    f["sha256"], f["size"] = hashlib.sha256(b).hexdigest(), len(b)
json.dump(d, open(sys.argv[2], "w"))
PY
  printf '#!/usr/bin/env bash\necho "version: 0.0.0 (build 4242, commit deadbeef)"\n' > "${TEST_TMP}/bin/llama-server"
  chmod +x "${TEST_TMP}/bin/llama-server"
  export LLMCTL_LLAMA_SERVER="${TEST_TMP}/bin/llama-server"
  printf '0123456789abcdef0123456789abcdef\n' > "${TEST_TMP}/machine-id.A"
  printf 'fedcba9876543210fedcba9876543210\n' > "${TEST_TMP}/machine-id.B"
  export LLMCTL_MACHINE_ID_FILE="${TEST_TMP}/machine-id.A"
}

vl_fake_start() {
  local answers="$1"; shift
  local pf; pf="$(mktemp -u "${TEST_TMP}/port.XXXXXX")"
  python3 -I "${VL_FIX}/fake_openai.py" --suite "${LLMCTL_ROOT}/validation/suites/vision-golden-v1" \
    --suite "${LLMCTL_ROOT}/validation/suites/chat-v1" --suite "${LLMCTL_ROOT}/validation/suites/coder-v1" \
    --answers "${answers}" --port-file "${pf}" --model-id "${VL_MODEL}" "$@" >/dev/null 2>&1 &
  echo "$!" >> "${VL_PIDS_FILE}"
  local i
  for (( i=0; i<100; i++ )); do [[ -s "${pf}" ]] && break; sleep 0.1; done
  printf 'http://127.0.0.1:%s\n' "$(cat "${pf}")"
}

vl_mark_running() {
  printf 'profile=vision\nmode=gpu\nport=%s\nram_mb=1\nvram_mb=1\nstarted_epoch=%s\n' "$1" "$(date +%s)" > "${LLMCTL_RUNTIME_DIR}/vision.run"
}

vl_answers_with() {
  local out; out="$(mktemp "${TEST_TMP}/answers.XXXXXX")"
  python3 -I - "${VL_FIX}/answers_good.json" "$1" "$2" "${out}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d[sys.argv[2]] = sys.argv[3]; json.dump(d, open(sys.argv[4], "w"))
PY
  printf '%s\n' "${out}"
}

vl_rc() { local rc=0; "$@" >"${TEST_TMP}/last.out" 2>&1 || rc=$?; echo "${rc}"; }

# vl_json <file> <python-expr over d> - read one value of a JSON file
vl_json() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }
