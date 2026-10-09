#!/usr/bin/env bash
# test_decide_timeout_adapt.sh - G-156: the launcher-side CPU-adaptive gateway deadline.
#
# The Go default LLMCTL_DECIDE_TIMEOUT stays 8 s (contract: below the hosted SDK's 10 s). The
# LAUNCHERS (lib/svc_hook.sh run-gateway = systemd unit / launchd agent, lib/decide.sh decide_serve =
# `llmctl decide serve`) export a larger documented default ONLY when no explicit LLMCTL_DECIDE_TIMEOUT is
# in the environment AND at least one served (running or enabled) decision instance has a CPU-only
# placement (llama.cpp --n-gpu-layers 0 / onnx engine). An explicit env always wins; a pure-GPU host keeps 8 s.
#
# Stand-ins (on purpose): the gateway binary is a stub that records the environment it was exec'd with;
# the instances are env records exactly as svc_write_env writes them. The launch wrappers are real.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT

command -v python3 >/dev/null 2>&1 || { echo "SKIP-SUITE: python3 not installed"; exit 0; }

mkdir -p "${LLMCTL_SERVICES_DIR}" "${LLMCTL_RUNTIME_DIR}" "${TEST_TMP}/bin"
STUB="${TEST_TMP}/bin/llmctl-decide"
cat > "${STUB}" <<'EOF'
#!/usr/bin/env bash
# records what the launcher handed the gateway
{
  printf 'TIMEOUT=%s\n' "${LLMCTL_DECIDE_TIMEOUT-<unset>}"
  printf 'SOURCE=%s\n' "${LLMCTL_DECIDE_TIMEOUT_SOURCE-<unset>}"
  printf 'NOTE=%s\n' "${LLMCTL_DECIDE_TIMEOUT_NOTE-<unset>}"
  printf 'ARGS=%s\n' "$*"
} > "${STUB_OUT:?}"
EOF
chmod +x "${STUB}"
export LLMCTL_DECIDE_BIN="${STUB}"
export STUB_OUT="${TEST_TMP}/stub.out"
unset LLMCTL_DECIDE_TIMEOUT LLMCTL_DECIDE_TIMEOUT_SOURCE LLMCTL_DECIDE_TIMEOUT_NOTE

# write_inst <instance> <kind> <engine> <args...> - an env record as svc_write_env writes it
write_inst() {
  local inst="$1" kind="$2" engine="$3"; shift 3
  {
    printf 'LLMCTL_PROFILE=%q\nLLMCTL_ENGINE=%q\nLLMCTL_EXEC=%q\n' "${inst%%.*}" "${engine}" "/x/bin"
    printf 'LLMCTL_ARGS='; printf '%q ' "$@"; printf '\n'
    printf 'LLMCTL_PORT=9100\nLLMCTL_REG_KIND=%q\nLLMCTL_REG_PROFILE=%q\n' "${kind}" "${inst%%.*}"
  } > "${LLMCTL_SERVICES_DIR}/${inst}.env"
}
mark_enabled() { : > "${LLMCTL_SERVICES_DIR}/$1.enabled"; }
mark_running() { printf 'profile=%s\nmode=cpu\n' "$1" > "${LLMCTL_RUNTIME_DIR}/$1.run"; }
reset_state() { rm -f "${LLMCTL_SERVICES_DIR}"/* "${LLMCTL_RUNTIME_DIR}"/*; }

# run_wrapper <wrapper:hook|serve> [VAR=VAL...] -> prints the stub record
run_wrapper() {
  local which="$1"; shift
  rm -f "${STUB_OUT}"
  if [[ "${which}" == "hook" ]]; then
    env "$@" LLMCTL_PORTREG=0 bash "${LLMCTL_ROOT}/lib/svc_hook.sh" run-gateway >/dev/null 2>&1 || true
  else
    env "$@" LLMCTL_PORTREG=0 bash -c 'source "$LLMCTL_ROOT/lib/decide.sh"; decide_serve --foreground' >/dev/null 2>&1 || true
  fi
  cat "${STUB_OUT}" 2>/dev/null || echo "NO-OUTPUT"
}

for W in hook serve; do
  echo "== ${W}: CPU-only llama decision instance (enabled) -> cpu-adaptive 120 s =="
  reset_state
  write_inst decide-pro decide llama --model m.gguf --n-gpu-layers 0 --ctx-size 4096
  mark_enabled decide-pro
  out="$(run_wrapper "${W}")"
  assert_contains "${out}" "TIMEOUT=120" "${W}: the CPU placement raises the launcher default to 120 s"
  assert_contains "${out}" "SOURCE=cpu-adaptive" "${W}: ...and labels its source"
  assert_contains "${out}" "NOTE=decide-pro" "${W}: ...naming the CPU-placed instance(s)"

  echo "== ${W}: explicit LLMCTL_DECIDE_TIMEOUT always wins =="
  out="$(run_wrapper "${W}" LLMCTL_DECIDE_TIMEOUT=8)"
  assert_contains "${out}" "TIMEOUT=8" "${W}: an explicit 8 is not overridden"
  assert_contains "${out}" "SOURCE=<unset>" "${W}: no adaptive label on an explicit value"
  out="$(run_wrapper "${W}" LLMCTL_DECIDE_TIMEOUT=300)"
  assert_contains "${out}" "TIMEOUT=300" "${W}: an explicit 300 is passed through"

  echo "== ${W}: pure GPU instance keeps the Go default (nothing exported) =="
  reset_state
  write_inst decide-pro decide llama --model m.gguf --n-gpu-layers 99 --ctx-size 4096
  mark_enabled decide-pro
  out="$(run_wrapper "${W}")"
  assert_contains "${out}" "TIMEOUT=<unset>" "${W}: GPU placement leaves the 8 s Go default"
  assert_contains "${out}" "SOURCE=<unset>" "${W}: no label"

  echo "== ${W}: the onnx NLI encoder alone does NOT adapt (measured median 433 ms, p95 1585 ms, max 2837 ms on CPU) =="
  reset_state
  write_inst decide-nli decide onnx --model m.onnx
  mark_enabled decide-nli
  out="$(run_wrapper "${W}")"
  assert_contains "${out}" "TIMEOUT=<unset>" "${W}: an onnx decision instance alone leaves the 8 s Go default"
  assert_contains "${out}" "SOURCE=<unset>" "${W}: ...and sets no adaptive label"
  echo "== ${W}: onnx + a GPU llama profile stays at the Go default (the encoder must not raise a GPU host's deadline) =="
  write_inst decide-2b decide llama --model m.gguf --n-gpu-layers 99
  mark_enabled decide-2b
  out="$(run_wrapper "${W}")"
  assert_contains "${out}" "TIMEOUT=<unset>" "${W}: onnx + GPU llama => no adaptation"

  echo "== ${W}: a running (not enabled) instance counts; a stale env record does not =="
  reset_state
  write_inst decide-max decide llama --model m.gguf --n-gpu-layers 0
  out="$(run_wrapper "${W}")"
  assert_contains "${out}" "TIMEOUT=<unset>" "${W}: a stale record (neither enabled nor running) is ignored"
  mark_running decide-max
  out="$(run_wrapper "${W}")"
  assert_contains "${out}" "TIMEOUT=120" "${W}: a running instance counts"

  echo "== ${W}: a CPU CHAT instance does not widen the DECISION deadline =="
  reset_state
  write_inst small chat llama --model m.gguf --n-gpu-layers 0
  mark_enabled small
  out="$(run_wrapper "${W}")"
  assert_contains "${out}" "TIMEOUT=<unset>" "${W}: only kind=decide instances count"

  echo "== ${W}: a scale instance (decide-pro.2) is found through its profile's marker =="
  reset_state
  write_inst decide-pro.2 decide llama --model m.gguf --n-gpu-layers 0
  mark_running decide-pro.2
  out="$(run_wrapper "${W}")"
  assert_contains "${out}" "TIMEOUT=120" "${W}: instance keys with a scale suffix are scanned"
done

echo "== scale instance enabled through its own or its profile's marker (T-3) =="
reset_state
write_inst decide-pro.2 decide llama --model m.gguf --n-gpu-layers 0
mark_enabled decide-pro
out="$(run_wrapper hook)"
assert_contains "${out}" "TIMEOUT=120" "a scale instance is served when its PROFILE's <base>.enabled marker exists"
reset_state
write_inst decide-pro.2 decide llama --model m.gguf --n-gpu-layers 0
mark_enabled decide-pro.2
out="$(run_wrapper hook)"
assert_contains "${out}" "TIMEOUT=120" "a scale instance is served when its own <inst>.enabled marker exists"
reset_state
write_inst decide-pro.2 decide llama --model m.gguf --n-gpu-layers 0
out="$(run_wrapper hook)"
assert_contains "${out}" "TIMEOUT=<unset>" "a scale instance with no marker at all is ignored"

echo "== -ngl spellings recognised (T-4): value 0 => CPU, last occurrence wins, partial offload is not CPU =="
ngl_case() { # <expect:120|unset> <label> <args...>
  local expect="$1" label="$2"; shift 2
  reset_state
  write_inst decide-pro decide llama --model m.gguf "$@"
  mark_enabled decide-pro
  out="$(run_wrapper hook)"
  if [[ "${expect}" == "120" ]]; then assert_contains "${out}" "TIMEOUT=120" "ngl: ${label}"
  else assert_contains "${out}" "TIMEOUT=<unset>" "ngl: ${label}"; fi
}
ngl_case 120 "--n-gpu-layers 0" --n-gpu-layers 0
ngl_case 120 "--n-gpu-layers=0" --n-gpu-layers=0
ngl_case 120 "--gpu-layers 0" --gpu-layers 0
ngl_case 120 "--gpu-layers=0" --gpu-layers=0
ngl_case 120 "-ngl 0" -ngl 0
ngl_case 120 "-ngl=0" -ngl=0
ngl_case 120 "leading zeros -ngl 00" -ngl 00
ngl_case 120 "leading zeros --n-gpu-layers=000" --n-gpu-layers=000
ngl_case 120 "repeated flag, last is 0 (-ngl 99 -ngl 0)" -ngl 99 -ngl 0
ngl_case 120 "mixed spellings, last is 0 (-ngl 99 --n-gpu-layers=0)" -ngl 99 --n-gpu-layers=0
ngl_case unset "repeated flag, last is 99 (-ngl 0 -ngl 99)" -ngl 0 -ngl 99
ngl_case unset "partial offload -ngl 20" -ngl 20
ngl_case unset "partial offload --n-gpu-layers=10" --n-gpu-layers=10
ngl_case unset "-ngl 10 is not 0 (no substring match)" -ngl 10
ngl_case unset "-ngl 99" -ngl 99
ngl_case unset "no ngl flag at all (llama.cpp default offloads on CUDA builds)" --ctx-size 4096
ngl_case unset "flag spelled like a different option (--ngl-extra 0)" --ngl-extra 0

echo "== an inherited LLMCTL_DECIDE_TIMEOUT_SOURCE cannot mislabel an explicit value (T-6) =="
reset_state
write_inst decide-pro decide llama --model m.gguf --n-gpu-layers 0
mark_enabled decide-pro
out="$(run_wrapper hook LLMCTL_DECIDE_TIMEOUT=8 LLMCTL_DECIDE_TIMEOUT_SOURCE=cpu-adaptive LLMCTL_DECIDE_TIMEOUT_NOTE=stale)"
assert_contains "${out}" "TIMEOUT=8" "explicit value kept"
assert_contains "${out}" "SOURCE=<unset>" "inherited SOURCE is dropped when the value is explicit"
assert_contains "${out}" "NOTE=<unset>" "inherited NOTE is dropped when the value is explicit"
reset_state
out="$(run_wrapper serve LLMCTL_DECIDE_TIMEOUT_SOURCE=cpu-adaptive)"
assert_contains "${out}" "SOURCE=<unset>" "an inherited SOURCE without any CPU instance is dropped too"

echo "== mixed GPU + CPU decision instances -> adaptive (the slowest bounds the deadline) =="
reset_state
write_inst decide-2b decide llama --model m.gguf --n-gpu-layers 99
write_inst decide-pro decide llama --model m.gguf --n-gpu-layers 0
mark_enabled decide-2b; mark_enabled decide-pro
out="$(run_wrapper hook)"
assert_contains "${out}" "TIMEOUT=120" "mixed placement raises the deadline"
assert_contains "${out}" "NOTE=decide-pro" "only the CPU-placed profile is named"

echo "== the Go default itself is unchanged (contract) =="
assert_file_contains "${LLMCTL_ROOT}/internal/server/limits.go" "Timeout: 8 * time.Second" "Go default stays 8 s"

[[ "${TEST_FAILS}" -eq 0 ]] || { printf 'FAILED: %d assertion(s)\n' "${TEST_FAILS}" >&2; exit 1; }
echo "ALL PASS"
