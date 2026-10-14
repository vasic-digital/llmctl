#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals (GW_*) are consumed by the sourcing test files
# gate_wiring_lib.sh - shared harness of the tests/test_gate_wiring_*.sh RED tests (sourced after helpers.sh and
# test_setup_env; NOT a test itself - run_tests.sh only runs test_*.sh).
#
# What is REAL: bin/llmctl dispatch, lib/scheduler.sh (lock, budget, reservations, stop path), lib/validate.sh
# (validate_after_start / validate_auto / require_validated / the real validate_profile when GW_REAL_VALIDATE=1),
# the production env-record writer. What is a stand-in, on purpose and only here:
#   * the service MANAGER: tests/fixtures/svc_backend_recording.sh (records verbs, no process, no systemd);
#   * validate_profile (default): a recorder whose verdict is injected (GW_VALIDATE_RC / GW_VALIDATE_RC_<profile>)
#     and which records whether the scheduler lock is HELD by its caller (the re-entrancy probe);
#   * hw_pressure_gate: a recorder whose verdict is injected (GW_GATE_RC), defined by a TEST OVERLAY of the
#     lib copy, so the interface is specified even on a branch that lacks the real function;
#   * every catalog port is rewritten to a fresh unused port (LLMCTL_CATALOG), so a probe can never reach a REAL
#     model server of the host.
# The overlay lives in a throw-away TREE (symlinks to the real checkout, copies of bin/llmctl, lib/validate.sh and
# lib/hardware.sh with the overlays appended). Nothing in the repository is modified.

set -euo pipefail
GW_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# gw_port_in_use <port> -> rc 0 when something accepts TCP on 127.0.0.1:<port>
gw_port_in_use() { ( exec 3<>"/dev/tcp/127.0.0.1/$1" ) 2>/dev/null; }

# gw_free_port -> an unused 127.0.0.1 port (never one something listens on)
gw_free_port() {
  local p i
  for (( i=0; i<50; i++ )); do
    p="$(python3 -I -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
    gw_port_in_use "${p}" || { echo "${p}"; return 0; }
  done
  return 1
}

# gw_make_catalog <out> [profile=port ...] - copy of the catalog with EVERY port moved to an unused one
# (explicit profile=port pairs win).
gw_make_catalog() {
  local out="$1"; shift
  python3 -I - "${LLMCTL_ROOT}/models/catalog.json" "${out}" "$@" <<'PY'
import json, random, socket, sys
src, out, *pairs = sys.argv[1:]
fixed = dict(p.split("=", 1) for p in pairs)
d = json.load(open(src))
used = set(int(v) for v in fixed.values())
def busy(port):
    s = socket.socket()
    s.settimeout(0.2)
    try:
        s.connect(("127.0.0.1", port)); return True
    except OSError:
        return False
    finally:
        s.close()
random.seed(7)
for name, prof in d["profiles"].items():
    if name in fixed:
        prof["port"] = int(fixed[name]); continue
    while True:
        port = random.randint(41000, 58999)
        if port not in used and not busy(port):
            used.add(port); prof["port"] = port; break
json.dump(d, open(out, "w"))
PY
}

# gw_touch_model <profile> - placeholder files for every catalog file of the profile (existence only)
gw_touch_model() {
  local p="$1" name
  while IFS='|' read -r name _ _ _; do
    mkdir -p "${LLMCTL_MODELS_DIR}/${p}"; : > "${LLMCTL_MODELS_DIR}/${p}/${name}"
  done < <(python3 -I - "${LLMCTL_CATALOG}" "${p}" <<'PY'
import json, sys
for f in json.load(open(sys.argv[1]))["profiles"][sys.argv[2]]["files"]:
    print("%s|%s|%s|%s" % (f["name"], f.get("size", 0), f.get("sha256", ""), f.get("role", "")))
PY
)
}

# gw_make_tree - builds $GW_TREE (see header)
gw_make_tree() {
  GW_TREE="${TEST_TMP}/tree"
  mkdir -p "${GW_TREE}/bin" "${GW_TREE}/lib"
  local e b
  for e in "${LLMCTL_ROOT}"/* "${LLMCTL_ROOT}"/.[!.]*; do
    [[ -e "${e}" ]] || continue
    b="$(basename "${e}")"
    case "${b}" in bin|lib|.git) ;; *) ln -s "${e}" "${GW_TREE}/${b}" ;; esac
  done
  for e in "${LLMCTL_ROOT}"/lib/* "${LLMCTL_ROOT}"/lib/.[!.]*; do
    [[ -e "${e}" ]] || continue
    b="$(basename "${e}")"
    case "${b}" in validate.sh|hardware.sh|svc_hook.sh) ;; *) ln -s "${e}" "${GW_TREE}/lib/${b}" ;; esac
  done
  for e in "${LLMCTL_ROOT}"/bin/*; do
    b="$(basename "${e}")"
    if [[ "${b}" == llmctl ]]; then cp "${e}" "${GW_TREE}/bin/${b}"; else ln -s "${e}" "${GW_TREE}/bin/${b}"; fi
  done
  cp "${LLMCTL_ROOT}/lib/svc_hook.sh" "${GW_TREE}/lib/svc_hook.sh"
  cp "${LLMCTL_ROOT}/lib/hardware.sh" "${GW_TREE}/lib/hardware.sh"
  cp "${LLMCTL_ROOT}/lib/validate.sh" "${GW_TREE}/lib/validate.sh"
  cat >> "${GW_TREE}/lib/hardware.sh" <<'OVERLAY'

# ---- TEST OVERLAY (tests/gate_wiring_lib.sh): recorder around hw_pressure_gate -------------------------------------
if declare -F hw_pressure_gate >/dev/null 2>&1; then
  eval "$(declare -f hw_pressure_gate | sed '1s/^hw_pressure_gate/_gw_orig_hw_pressure_gate/')"
fi
hw_pressure_gate() {
  printf 'hw_pressure_gate %s\n' "$*" >> "${GW_CALLS:?}"
  if [[ "${GW_GATE_MODE:-shim}" == real ]] && declare -F _gw_orig_hw_pressure_gate >/dev/null 2>&1; then
    _gw_orig_hw_pressure_gate "$@"; return
  fi
  return "${GW_GATE_RC:-0}"
}
OVERLAY
  cat >> "${GW_TREE}/lib/validate.sh" <<'OVERLAY'

# ---- TEST OVERLAY (tests/gate_wiring_lib.sh): recorder around validate_profile ---------------------------------------
eval "$(declare -f validate_profile | sed '1s/^validate_profile/_gw_orig_validate_profile/')"
# _gw_lock_held -> "yes" when ANOTHER open file description holds the scheduler lock (i.e. our caller is inside
# scheduler::with_lock): a real validate_profile -> sched_start would then deadlock on the non-reentrant flock.
_gw_lock_held() {
  local rc=0
  ( flock -n 9 ) 9>"${LLMCTL_RUNTIME_DIR}/.scheduler.lock" 2>/dev/null || rc=$?
  if [[ "${rc}" -ne 0 ]]; then echo yes; else echo no; fi
}
validate_profile() {
  printf 'validate_profile %s lock_held=%s\n' "$*" "$(_gw_lock_held)" >> "${GW_CALLS:?}"
  if [[ "${GW_REAL_VALIDATE:-0}" == 1 ]]; then _gw_orig_validate_profile "$@"; return; fi
  local a p="" v rc
  for a in "$@"; do case "${a}" in -*) ;; *) p="${a}"; break ;; esac; done
  printf 'validate_profile_begin %s %s\n' "${p}" "$(date +%s.%N)" >> "${GW_CALLS}"
  [[ -z "${GW_VALIDATE_SLEEP:-}" ]] || sleep "${GW_VALIDATE_SLEEP}"
  v="GW_VALIDATE_RC_${p//[-.]/_}"
  rc="${!v:-${GW_VALIDATE_RC:-0}}"
  printf 'validate_profile_end %s rc=%s %s\n' "${p}" "${rc}" "$(date +%s.%N)" >> "${GW_CALLS}"
  return "${rc}"
}
# Freshness of the recorder world: the recorder writes no record, so "a fresh PASS record exists" is modelled as GW_FRESH
# listing the profile, or a recorded verdict 0 in this call log (a real PASS writes a signed record). The real record
# path is tested with real records in tests/test_validation_record_integrity.sh.
if [[ "${GW_REAL_VALIDATE:-0}" != 1 ]]; then
_val_fresh() {
  [[ " ${GW_FRESH:-} " == *" $1 "* ]] && return 0
  grep -q "^validate_profile_end $1 rc=0 " "${GW_CALLS:?}" 2>/dev/null
}
fi
OVERLAY
}

# gw_init [profile=port ...] - call right after test_setup_env.
gw_init() {
  GW_CALLS="${TEST_TMP}/calls.log"; : > "${GW_CALLS}"; export GW_CALLS
  export GW_ACTIVE_DIR="${TEST_TMP}/active"; mkdir -p "${GW_ACTIVE_DIR}"
  export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
  export LLMCTL_SERVICE_BACKEND_FILE="${LLMCTL_ROOT}/tests/fixtures/svc_backend_recording.sh"
  export LLMCTL_CATALOG="${TEST_TMP}/catalog.json"
  gw_make_catalog "${LLMCTL_CATALOG}" "$@"
  mkdir -p "${TEST_TMP}/bin"
  printf '#!/usr/bin/env bash\necho "version: 0.0.0 (build 4242, commit deadbeef)"\n' > "${TEST_TMP}/bin/llama-server"
  chmod +x "${TEST_TMP}/bin/llama-server"
  export LLMCTL_LLAMA_SERVER="${TEST_TMP}/bin/llama-server"
  export LLMCTL_VALIDATE_TIMEOUT=10
  export LLMCTL_VALIDATE_ON_START=1
  export LLMCTL_GATE_PSI_DUMMY=
  unset LLMCTL_GATE_PSI_DUMMY
  unset GW_VALIDATE_RC GW_GATE_RC GW_REAL_VALIDATE GW_GATE_MODE GW_SVC_START_FAIL GW_VALIDATE_SLEEP LLMCTL_VALIDATE_STRICT
  local p
  for p in small vision fast decide-tiny; do gw_touch_model "${p}"; done
  gw_make_tree
  GW_LLMCTL="${GW_TREE}/bin/llmctl"
}

# gw_run <cmd...> -> rc; stdout+stderr of the command in ${TEST_TMP}/last.out (never aborts the test under set -e)
gw_run() { local rc=0; "$@" >"${TEST_TMP}/last.out" 2>&1 || rc=$?; echo "${rc}"; }
gw_out() { cat "${TEST_TMP}/last.out"; }
gw_calls_reset() { : > "${GW_CALLS}"; }
# gw_count <extended-regex> -> number of GW_CALLS lines matching
gw_count() { grep -cE -- "$1" "${GW_CALLS}" 2>/dev/null || true; }
# gw_line <extended-regex> -> line number of the FIRST match (0 when none)
gw_line() { awk -v re="$1" '$0 ~ re {print NR; f=1; exit} END{if(!f) print 0}' "${GW_CALLS}"; }
# gw_line_after <regex> <after-line> -> first matching line number > after-line (0 when none)
gw_line_after() { awk -v re="$1" -v a="$2" 'NR>a && $0 ~ re {print NR; f=1; exit} END{if(!f) print 0}' "${GW_CALLS}"; }

# gw_mark_running <profile> <port> -> a reservation + active marker, as if the profile were up (no process)
gw_mark_running() {
  mkdir -p "${LLMCTL_RUNTIME_DIR}" "${GW_ACTIVE_DIR}"
  printf 'profile=%s\nmode=gpu\nport=%s\nram_mb=1\nvram_mb=1\nstarted_epoch=%s\n' "$1" "$2" "$(date +%s)" > "${LLMCTL_RUNTIME_DIR}/$1.run"
  : > "${GW_ACTIVE_DIR}/$1"
}
gw_is_running() { [[ -f "${LLMCTL_RUNTIME_DIR}/$1.run" ]]; }

# gw_http_server <reqlog> -> starts a counting HTTP fixture on a free port; sets GW_HTTP_PORT, GW_HTTP_PID.
# Answers 200 {} to everything and appends "METHOD path" to <reqlog> for every request. Never a model.
gw_http_server() {
  local reqlog="$1" pf="${TEST_TMP}/http.port.$RANDOM" i
  : > "${reqlog}"
  python3 -I - "${reqlog}" "${pf}" "${GW_HTTP_DELAY:-0}" "${GW_HTTP_FIXED_PORT:-0}" > /dev/null 2>&1 <<'PY' &
import http.server, json, sys, time
log, pf, delay, want = sys.argv[1], sys.argv[2], float(sys.argv[3]), int(sys.argv[4])
class H(http.server.BaseHTTPRequestHandler):
    def _go(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n: self.rfile.read(n)
        with open(log, "a") as f: f.write("%s %s\n" % (self.command, self.path))
        body = json.dumps({"data": [{"id": "fixture"}], "status": "ok"}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    do_GET = do_POST = _go
    def log_message(self, *a): pass
time.sleep(delay)
srv = http.server.ThreadingHTTPServer(("127.0.0.1", want), H)
open(pf + ".ts", "w").write("%.6f" % time.time())
open(pf, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
  GW_HTTP_PID=$!
  GW_BG_PIDS+=("${GW_HTTP_PID}")
  if [[ "${GW_HTTP_FIXED_PORT:-0}" -gt 0 && "${GW_HTTP_NOWAIT:-0}" == 1 ]]; then GW_HTTP_PORT="${GW_HTTP_FIXED_PORT}"; GW_HTTP_UP_FILE="${pf}.ts"; return 0; fi
  for (( i=0; i<150; i++ )); do [[ -s "${pf}" ]] && break; sleep 0.1; done
  GW_HTTP_PORT="$(cat "${pf}" 2>/dev/null || true)"; GW_HTTP_UP_FILE="${pf}.ts"
}
GW_BG_PIDS=()
gw_cleanup_bg() {
  local p
  for p in ${GW_BG_PIDS[@]+"${GW_BG_PIDS[@]}"}; do [[ -n "${p}" ]] && kill "${p}" 2>/dev/null || true; done
  GW_BG_PIDS=()
}
