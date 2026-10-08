#!/usr/bin/env bash
# test_regression_defects.sh - permanent regression guards for the defects that spec 009's P1 reproduction
# register (specs/009-jev-decision-models/evidence/p1-red-register.json) found in the second team's
# candidate. One assertion group per defect id, driving the REAL code (the Go llmctl-decide binary, the
# bash libraries, bin/llmctl, the shipped catalog). Each group was a RED test against the candidate
# (original results archived under specs/009-jev-decision-models/evidence/p1-red-original/) and is the
# GREEN regression test now: the OLD defect must be gone. Defects whose guard already exists elsewhere
# (a Go unit test, the onnx runtime contract, an endpoint-inventory row...) are not duplicated here; the
# complete id -> guard map is specs/009-jev-decision-models/evidence/red-to-green-map.json.
# Test-first discipline: every group below failed against the candidate before the fix it guards (the
# "red_result" of each id in the archive) - the groups were ported from that archive, not invented after.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

command -v go >/dev/null 2>&1 || { echo "SKIP-SUITE: go not installed"; exit 0; }
BIN="${TEST_TMP}/bin/llmctl-decide"
mkdir -p "${TEST_TMP}/bin"
( cd "${LLMCTL_ROOT}" && go build -o "${BIN}" ./cmd/llmctl-decide )

# Isolated installation for the binary (never the operator's real home or key).
export LLMCTL_HOME="${TEST_TMP}/home/llmctl" LLMCTL_ENV_FILE="${TEST_TMP}/root/.env"
mkdir -p "${TEST_TMP}/root"
unset LLMCTL_API_KEY LLMCTL_DECIDE_PORT LLMCTL_DECIDE_MAX_OPTIONS LLMCTL_SEED LLMCTL_ENDPOINT LLMCTL_CACERT

# no_trace <text> -> 0 when the text carries no Go panic / Python traceback signature.
no_trace() { if [[ "$1" == *"panic:"* || "$1" == *"goroutine "* || "$1" == *"Traceback"* ]]; then echo 1; else echo 0; fi; }

# --- D-03: no credential travels on a command line (the gateway has no --api-key flag) ---------------
out="$("${BIN}" serve --api-key SECRET-ON-ARGV 2>&1)" && rc=0 || rc=$?
assert_eq 2 "${rc}" "D-03: serve --api-key is refused (no key on argv, rc 2)"
assert_contains "${out}" "flag provided but not defined" "D-03: the flag does not exist"

# --- D-11 / D-29 (retired test seams): no backend host/port override, no fake-model flag, no second key variable
hits="$(cd "${LLMCTL_ROOT}" && grep -rln 'LLMCTL_DECIDE_BACKEND_HOST\|LLMCTL_DECIDE_BACKEND_PORT\|LLMCTL_ONNX_FAKE\|LLMCTL_DECIDE_API_KEY' lib bin cmd internal scripts 2>/dev/null | grep -v '_test\.go$' || true)"
assert_eq "" "${hits}" "D-11/D-29: no production file reads a retired seam variable (lib bin cmd internal scripts)"

# --- D-13: every decide-nli catalog file is hash-pinned (no trust-on-first-use) -----------------------
unpinned="$(python3 - "${LLMCTL_ROOT}/models/catalog.json" <<'PY'
import json, re, sys
c = json.load(open(sys.argv[1]))
bad = [f["name"] for p in c["profiles"].values() if "decide" in (p.get("capability") or [])
       for f in p.get("files", []) if not re.fullmatch(r"[0-9a-f]{64}", f.get("sha256", ""))]
print(",".join(bad))
PY
)"
assert_eq "" "${unpinned}" "D-13: every file of every decide profile carries a pinned sha256"

# --- D-22: the unused tokenizer.json is not downloaded for the sentencepiece model ---------------------
names="$(python3 - "${LLMCTL_ROOT}/models/catalog.json" <<'PY'
import json, sys
print(" ".join(f["name"] for f in json.load(open(sys.argv[1]))["profiles"]["decide-nli"]["files"]))
PY
)"
assert_contains "${names}" "spm.model" "D-22: decide-nli ships the sentencepiece model it loads"
if [[ " ${names} " == *"tokenizer.json"* ]]; then has_tj=1; else has_tj=0; fi
assert_eq 0 "${has_tj}" "D-22: decide-nli does not download an unused tokenizer.json"

# --- D-24: stale CLI text ---------------------------------------------------------------------------
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
out="$("${LLMCTL_ROOT}/bin/llmctl" auto bogus 2>&1)" && rc=0 || rc=$?
assert_contains "${out}" "decide" "D-24: 'auto <bogus>' lists decide among the capabilities"
help_out="$("${LLMCTL_ROOT}/bin/llmctl" --help 2>&1 || true)"
assert_contains "$(printf '%s\n' "${help_out}" | grep -E '^ *build ' | head -n1)" "onnx" "D-24: the build usage line names onnx"
if grep -q "when it lands" "${LLMCTL_ROOT}/lib/decide.sh"; then stale=1; else stale=0; fi
assert_eq 0 "${stale}" "D-24: lib/decide.sh no longer says serve is coming 'when it lands'"

# --- D-25: compiled caches are ignored and never tracked ---------------------------------------------
( cd "${LLMCTL_ROOT}" && git check-ignore -q lib/__pycache__/x.pyc && git check-ignore -q tests/fixtures/__pycache__/y.pyc ) && ign=0 || ign=1
assert_eq 0 "${ign}" "D-25: __pycache__/*.pyc are gitignored"
tracked="$(cd "${LLMCTL_ROOT}" && git ls-files | grep -c '__pycache__\|\.pyc$' || true)"
assert_eq 0 "${tracked}" "D-25: no compiled cache is tracked"

# --- D-19b: the gateway is a boot-time service unit ---------------------------------------------------
source "${LLMCTL_ROOT}/lib/common.sh"
source "${LLMCTL_ROOT}/lib/os_detect.sh"
source "${LLMCTL_ROOT}/lib/service_linux.sh"
unit="$(_decide_gateway_unit_body /bin/true 1024 1024)"
assert_contains "${unit}" "llmctl decision gateway" "D-19b: a decision-gateway systemd unit body exists"
assert_contains "${unit}" "Restart=always" "D-19b: the unit restarts the gateway"

# --- N-05 / N-16: malformed numeric configuration -> clean rc 2, one line, no traceback ----------------
for v in LLMCTL_SEED LLMCTL_DECIDE_MAX_OPTIONS LLMCTL_DECIDE_PORT; do
  out="$(env "${v}=abc" "${BIN}" serve --foreground 2>&1)" && rc=0 || rc=$?
  assert_eq 2 "${rc}" "N-05/N-16: ${v}=abc is refused at start with rc 2"
  assert_eq 0 "$(no_trace "${out}")" "N-05/N-16: ${v}=abc leaves no traceback / panic"
  assert_contains "${out}" "${v}" "N-05/N-16: the message names ${v}"
done
out="$(LLMCTL_DECIDE_MAX_OPTIONS=abc "${BIN}" ask --type noul --state s --instructions q 2>&1)" && rc=0 || rc=$?
assert_eq 0 "$(no_trace "${out}")" "N-16: decide ask with a malformed LLMCTL_DECIDE_MAX_OPTIONS: no traceback"
assert_contains "${out}" "LLMCTL_DECIDE_MAX_OPTIONS" "N-16: decide ask names the malformed variable"
assert_eq 0 "$([[ "${rc}" -ne 0 ]] && echo 0 || echo 1)" "N-16: decide ask with a malformed variable fails"

# --- the bash front end ------------------------------------------------------------------------------
source "${LLMCTL_ROOT}/lib/hardware.sh"
source "${LLMCTL_ROOT}/lib/catalog.sh"
source "${LLMCTL_ROOT}/lib/decide.sh"
source "${LLMCTL_ROOT}/lib/scheduler.sh"

# --- N-06: end of input at a prompt is rc 2 + a message, and the SOURCING shell survives ---------------
# (the original harness could not pass under `set -e`; the AFTER marker is printed with `|| echo AFTER rc=$?`.)
out="$( ( decide_interactive --interactive --profile decide --type noul --state s --instructions 'q?' </dev/null 2>&1 || echo "AFTER rc=$?" ) )"
assert_contains "${out}" "AFTER rc=2" "N-06: EOF at a prompt returns rc 2 and the calling shell keeps running"
assert_contains "${out}" "end of input" "N-06: EOF at a prompt explains itself"

# --- N-07: a misspelled flag is rejected ---------------------------------------------------------------
decide_status --jsno >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq 2 "${rc}" "N-07: decide status --jsno -> rc 2"
decide_capacity --jsno >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq 2 "${rc}" "N-07: decide capacity --jsno -> rc 2"

# --- N-08: every function the documentation names exists ------------------------------------------------
missing=""
for fn in $(grep -o '`decide_[a-z_]*`' "${LLMCTL_ROOT}/docs/scripts/decide.md" | tr -d '`' | sort -u); do
  declare -F "${fn}" >/dev/null 2>&1 || missing+=" ${fn}"
done
assert_eq "" "${missing}" "N-08: docs/scripts/decide.md names only defined functions"
assert_contains "$(grep -o '`decide_ask`' "${LLMCTL_ROOT}/docs/scripts/decide.md" | head -n1)" "decide_ask" "N-08: control - the doc scan sees decide_ask"

# --- N-09: wizard prompts are visible on piped stdin ----------------------------------------------------
out="$(printf 'q?\n\n\nn\n' | decide_interactive --interactive --profile decide --type noul --state s 2>&1 >/dev/null)" && rc=0 || rc=$?
assert_contains "${out}" "Description for 'yes'" "N-09: prompt text reaches stderr with piped stdin"

# --- N-25: the download tests bind no fixed port literal ---------------------------------------------------
fixed="$(grep -lE '^PORT=[0-9]+[[:space:]]*$' "${LLMCTL_ROOT}/tests/test_decide_download.sh" "${LLMCTL_ROOT}/tests/test_onnx_download.sh" || true)"
assert_eq "" "${fixed}" "N-25: test_decide_download.sh / test_onnx_download.sh pick a free port (no PORT=<literal>)"

# --- N-26: no download test asserts SUCCESS inside/after a skipped-smoke branch ------------------------------
hits=0
for f in test_onnx_download.sh test_decide_download.sh; do
  while IFS= read -r n; do
    ctx="$(sed -n "$(( n > 8 ? n - 8 : 1 )),${n}p" "${LLMCTL_ROOT}/tests/${f}")"
    if [[ "${ctx,,}" == *"skip"* ]]; then hits=$((hits+1)); fi
  done < <(grep -n 'assert_file_contains.*SUCCESS' "${LLMCTL_ROOT}/tests/${f}" | cut -d: -f1)
done
assert_eq 0 "${hits}" "N-26: no SUCCESS assertion sits in a skipped-smoke context"
assert_eq 1 "$([[ "$(grep -c 'assert_file_contains' "${LLMCTL_ROOT}/tests/test_onnx_download.sh")" -gt 0 ]] && echo 1 || echo 0)" "N-26: control - the scanner sees assert_file_contains"

# --- N-28: no CONFIRMED hash claim rests on the mirror alone ------------------------------------------------------
bad=""
for f in encoder-model-hashes.md decision-model-hashes.md; do
  t="${LLMCTL_ROOT}/docs/research/${f}"
  if grep -q CONFIRMED "${t}" && grep -q 'hf-mirror.com' "${t}" && ! grep -q 'huggingface.co' "${t}"; then bad+=" ${f}"; fi
done
assert_eq "" "${bad}" "N-28: CONFIRMED hash claims cite huggingface.co, not only hf-mirror.com"

# --- N-27: documented assertion counts equal the measured ones (generated, never hand-typed) ------------------------
cnt="$(bash "${LLMCTL_ROOT}/scripts/doc_counts.sh" --check decide decide_download onnx_download onnx_server 2>&1)" && rc=0 || rc=$?
if [[ "${cnt}" == *"status=stale"* ]]; then stale=1; else stale=0; fi
assert_eq 0 "${stale}" "N-27: scripts/doc_counts.sh --check reports no stale documented count"

# G-084: host-dependent branches are bracketed (hostdep_begin/end) and excluded from the documented count,
# so the figure is identical on a host that takes the other branch. Proven on a scratch tree: the same
# suite run in "host A" (4 ok + 2 hostdep) and "host B" (4 ok + 0 hostdep + a skip) yields the same ok=4,
# a page claiming 4 is `match` in both, and a page claiming 6 is `stale` (a SKIP does not excuse it).
SCR="${TEST_TMP}/dc"; mkdir -p "${SCR}/tests" "${SCR}/docs/scripts"
cat >"${SCR}/tests/test_x.sh" <<'XS'
echo "  ok: a"; echo "  ok: b"; echo "  ok: c"; echo "  ok: d"
echo "HOSTDEP-BEGIN: branch"
if [[ "${HOST_B:-0}" == 1 ]]; then echo "  SKIP: other branch" >&2; else echo "  ok: e"; echo "  ok: f"; fi
echo "HOSTDEP-END"
XS
printf '**4 passing assertions\n' >"${SCR}/docs/scripts/test_x.md"
a="$(DOC_COUNTS_ROOT="${SCR}" bash "${LLMCTL_ROOT}/scripts/doc_counts.sh" --check x 2>&1)" || true
b="$(HOST_B=1 DOC_COUNTS_ROOT="${SCR}" bash "${LLMCTL_ROOT}/scripts/doc_counts.sh" --check x 2>&1)" || true
assert_contains "${a}" "ok=4 " "N-27/G-084: host A counts only the host-independent assertions"
assert_contains "${a}" "hostdep=2" "N-27/G-084: host A reports its 2 host-dependent assertions separately"
assert_contains "${a}" "status=match" "N-27/G-084: host A: a page claiming 4 matches"
assert_contains "${b}" "ok=4 " "N-27/G-084: host B (other branch, SKIP) yields the same count"
assert_contains "${b}" "status=match" "N-27/G-084: host B: the same page matches"
printf '**6 passing assertions\n' >"${SCR}/docs/scripts/test_x.md"
b2="$(HOST_B=1 DOC_COUNTS_ROOT="${SCR}" bash "${LLMCTL_ROOT}/scripts/doc_counts.sh" --check x 2>&1)" || true
assert_contains "${b2}" "status=stale" "N-27/G-084: a wrong claim is stale even on a host that SKIPs (no env-dependent excuse)"

test_finish
