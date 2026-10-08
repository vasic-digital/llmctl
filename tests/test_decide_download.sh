#!/usr/bin/env bash
# test_decide_download.sh - a decide-capable profile through the verified
# download pipeline against a LOCAL http fixture (python3 -m http.server),
# mirroring tests/test_download.sh exactly. Asserts the capability-based
# dispatch: the post-download validation must route through
# _dl_smoke_test_decision (never _dl_smoke_test_gguf) for a profile whose
# capability contains "decide", with the evidence log as proof.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

source "${LLMCTL_ROOT}/lib/common.sh"
source "${LLMCTL_ROOT}/lib/catalog.sh"
source "${LLMCTL_ROOT}/lib/decide.sh"
source "${LLMCTL_ROOT}/lib/download.sh"

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
WWW="${TEST_TMP}/www"
mkdir -p "${WWW}/toy/decide/resolve/main"
PAYLOAD="${WWW}/toy/decide/resolve/main/model.gguf"
printf 'llmctl tiny fixture decision-model payload - NOT a real GGUF\n' > "${PAYLOAD}"
SIZE="$(stat -c%s "${PAYLOAD}" 2>/dev/null || stat -f%z "${PAYLOAD}")"
SHA="$(llmctl_sha256 "${PAYLOAD}")"

make_catalog() {
  # make_catalog <sha256> > catalog file path
  cat > "${TEST_TMP}/catalog-decide-$1.json" <<EOF
{
  "version": 1,
  "notes": "test catalog",
  "ports": {"toy-decide": 9998},
  "profiles": {
    "toy-decide": {
      "engine": "llama",
      "capability": ["decide"],
      "min_tier": "below-minimum",
      "port": 9998,
      "hf_repo": "toy/decide",
      "hf_revision": "main",
      "desc": "tiny test decision profile",
      "defaults": {"ctx": 512, "ngl": 0, "parallel": 1, "flash_attn": "off", "kv_cache_type": "q8_0"},
      "files": [{"name": "model.gguf", "size": ${SIZE}, "sha256": "$1", "role": "model"}]
    }
  }
}
EOF
  echo "${TEST_TMP}/catalog-decide-$1.json"
}

# Serve the fixture.
python3 -m http.server "${PORT}" --bind 127.0.0.1 --directory "${WWW}" >/dev/null 2>&1 &
HTTP_PID=$!
trap 'kill ${HTTP_PID} 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
  curl -fsS "http://127.0.0.1:${PORT}/" >/dev/null 2>&1 && break
  sleep 0.1
done

export LLMCTL_HF_BASE="http://127.0.0.1:${PORT}"
LLMCTL_CATALOG="$(make_catalog "${SHA}")"
export LLMCTL_CATALOG

# --- 1. download with LLMCTL_SMOKE=0: the DECISION smoke path is taken ------
export LLMCTL_SMOKE=0
out="$(download_profile toy-decide 2>&1)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "download_profile toy-decide exit code"
printf '%s\n' "${out}" | sed 's/^/  /'
assert_file_exists "${LLMCTL_MODELS_DIR}/toy-decide/model.gguf" "model.gguf exists after download"
assert_eq "${SHA}" "$(llmctl_sha256 "${LLMCTL_MODELS_DIR}/toy-decide/model.gguf")" "downloaded file sha256 matches"
assert_file_contains "${LLMCTL_VERIFY_DIR}/toy-decide.log" "decision smoke test disabled via LLMCTL_SMOKE=0" \
  "evidence log records the DECISION smoke path (not the gguf smoke path)"
if grep -qF "RUN: _dl_smoke_test_gguf" "${LLMCTL_VERIFY_DIR}/toy-decide.log"; then took_gguf=1; else took_gguf=0; fi
assert_eq 0 "${took_gguf}" "gguf smoke path NOT taken for a decide-capable profile"
assert_file_contains "${LLMCTL_VERIFY_DIR}/toy-decide.log" "download toy-decide: SUCCESS" \
  "evidence log records overall success"

# --- 2. LLMCTL_SMOKE=1 without a built llama-server: SKIP-with-reason -------
export LLMCTL_SMOKE=1
hostdep_begin "section 2 branches on whether a real llama-server is built on this host"
if ! _dl_llama_server_bin >/dev/null 2>&1; then
  out="$(download_profile toy-decide 2>&1)" && rc=0 || rc=$?
  assert_eq 0 "${rc}" "download with smoke enabled but no llama-server: still rc 0 (skip-warn precedent)"
  assert_file_contains "${LLMCTL_VERIFY_DIR}/toy-decide.log" "decision smoke test SKIPPED: llama-server not built" \
    "evidence log records the decision smoke SKIP-with-reason"
  assert_contains "${out}" "skipping decision smoke test" "operator-facing skip warning"
else
  # A real llama-server exists, but this toy payload is not a real GGUF, so
  # launching the real llama-server against it cannot prove anything; section 3 drives
  # the same smoke path with a Go fake engine instead.
  assert_skip "llama-server is built but the toy payload is not a real GGUF; section 3 exercises the smoke path with a fake engine" \
    "full decision smoke against a real llama-server"
fi
hostdep_end

# --- 3. the smoke path through the REAL Go binary against a fake llama engine -
# The post-download decision smoke is `llmctl-decide smoke` (the production letter-logit driver).
# The engine is a test-only Go fake (internal/gateway/internal/fakebackends) started by a fake
# `llama-server` wrapper on the fixed smoke port; the binary, the driver, the prompt template and
# the readout are the real implementations.
hostdep_begin "section 3 runs only when the go toolchain is installed"
if command -v go >/dev/null 2>&1; then
  BIN="${TEST_TMP}/bin/llmctl-decide"; FAKE="${TEST_TMP}/bin/fakebackends"
  mkdir -p "${TEST_TMP}/bin"
  ( cd "${LLMCTL_ROOT}" && go build -o "${BIN}" ./cmd/llmctl-decide && go build -o "${FAKE}" ./internal/gateway/internal/fakebackends )
  SMOKE_PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
  cat > "${TEST_TMP}/bin/fake-llama-server" <<WRAP
#!/usr/bin/env bash
# stands in for llama-server: honours --port, serves /health and /v1/chat/completions
port=""
while [[ \$# -gt 0 ]]; do case "\$1" in --port) port="\$2"; shift 2;; *) shift;; esac; done
exec "${FAKE}" -llama-port "\${port}" \${FAKE_ARGS:-}
WRAP
  chmod +x "${TEST_TMP}/bin/fake-llama-server"
  export LLMCTL_LLAMA_SERVER="${TEST_TMP}/bin/fake-llama-server" LLMCTL_DECIDE_BIN="${BIN}"
  export LLMCTL_SMOKE=1 LLMCTL_SMOKE_PORT="${SMOKE_PORT}" LLMCTL_SMOKE_TIMEOUT=20
  rm -rf "${LLMCTL_MODELS_DIR}/toy-decide"

  out="$(download_profile toy-decide 2>&1)" && rc=0 || rc=$?
  assert_eq 0 "${rc}" "download with a fake engine: decision smoke passes through llmctl-decide smoke"
  assert_file_contains "${LLMCTL_VERIFY_DIR}/toy-decide.log" "RUN: _dl_decision_probe_choice" \
    "evidence log records the Go-backed smoke probe"
  assert_file_contains "${LLMCTL_VERIFY_DIR}/toy-decide.log" "smoke ok: protocol=letter-logit choice=billing" \
    "evidence log records the typed billing answer"
  assert_file_contains "${LLMCTL_VERIFY_DIR}/toy-decide.log" "decision smoke PASSED" "evidence log records the smoke PASS"

  # Negative: an engine that answers 500 must FAIL the smoke and the download (no false PASS).
  rm -rf "${LLMCTL_MODELS_DIR}/toy-decide"
  out="$(FAKE_ARGS="-chat-status 500" download_profile toy-decide 2>&1)" && rc=0 || rc=$?
  if [[ "${rc}" -ne 0 ]]; then failed=0; else failed=1; fi
  assert_eq 0 "${failed}" "download with a failing engine: decision smoke FAILS the download (rc=${rc})"
  assert_file_contains "${LLMCTL_VERIFY_DIR}/toy-decide.log" "decision smoke FAILED" "evidence log records the smoke FAIL"

  # Negative: an unusable decision binary is an explicit, actionable failure.
  rm -rf "${LLMCTL_MODELS_DIR}/toy-decide"
  out="$(LLMCTL_DECIDE_BIN="${TEST_TMP}/no-such-binary" download_profile toy-decide 2>&1)" && rc=0 || rc=$?
  if [[ "${rc}" -ne 0 ]]; then failed=0; else failed=1; fi
  assert_eq 0 "${failed}" "download with an unusable LLMCTL_DECIDE_BIN fails (no silent skip)"
  assert_contains "${out}" "LLMCTL_DECIDE_BIN" "unusable binary: the error names LLMCTL_DECIDE_BIN"

  # --- 3b. a NATIVE (systemone-native) decision profile: the smoke speaks /v1/systemone -------------
  # The post-download smoke must follow the profile's decision protocol (G-116): the letter-logit
  # probe would call /v1/chat/completions on a native model and fail. The native smoke asserts a
  # VALID typed answer only (no --expect-choice: a smoke answer is not quality evidence).
  cat > "${TEST_TMP}/catalog-native.json" <<EOF
{
  "version": 1, "notes": "test catalog", "ports": {"toy-native": 9997},
  "profiles": {
    "toy-native": {
      "engine": "llama", "capability": ["decide"], "min_tier": "below-minimum", "port": 9997,
      "hf_repo": "toy/decide", "hf_revision": "main", "desc": "tiny native test profile",
      "defaults": {"ctx": 8192, "ngl": 0, "parallel": 1, "flash_attn": "off"},
      "decision": {"protocol": "systemone-native", "max_options": 255, "score_levels": [2, 10]},
      "files": [{"name": "model.gguf", "size": ${SIZE}, "sha256": "${SHA}", "role": "model"}]
    }
  }
}
EOF
  cat > "${TEST_TMP}/bin/fake-llama-server-rec" <<WRAP
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "${TEST_TMP}/smoke-args.log"
exec "${TEST_TMP}/bin/fake-llama-server" "\$@"
WRAP
  chmod +x "${TEST_TMP}/bin/fake-llama-server-rec"
  mkdir -p "${WWW}/toy/decide/resolve/main"
  ( export LLMCTL_CATALOG="${TEST_TMP}/catalog-native.json" LLMCTL_LLAMA_SERVER="${TEST_TMP}/bin/fake-llama-server-rec"
    rm -rf "${LLMCTL_MODELS_DIR}/toy-native"; : > "${TEST_TMP}/smoke-args.log"
    out="$(download_profile toy-native 2>&1)" && rc=0 || rc=$?
    printf '%s\n' "${out}" | sed 's/^/  /' | tail -8
    echo "${rc}" > "${TEST_TMP}/native.rc" )
  assert_eq 0 "$(cat "${TEST_TMP}/native.rc")" "3b native profile: download + decision smoke through /v1/systemone passes"
  assert_file_contains "${LLMCTL_VERIFY_DIR}/toy-native.log" "smoke ok: protocol=systemone-native choice=billing" \
    "3b native profile: the evidence log records a typed answer from the NATIVE protocol"
  assert_file_contains "${LLMCTL_VERIFY_DIR}/toy-native.log" "decision smoke PASSED" "3b native profile: smoke PASS recorded"
  assert_file_contains "${TEST_TMP}/smoke-args.log" "--ctx-size 4096" "3b native profile: smoke engine gets a 4096 context (a native state is scored in one batch)"
else
  assert_skip "go is not installed; llmctl-decide cannot be built for the smoke-path section" "decision smoke through llmctl-decide"
fi
hostdep_end


# --- 4. C-06: readiness is proven against THIS test's own process, not "something answers" -------
# A foreign server on the port answers /health 200 the whole time. The old logic trusted that answer
# (fixed port 18090 + curl) and ran the probes against the foreign server.
FOREIGN_PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
cat > "${TEST_TMP}/foreign.py" <<'PY'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
python3 "${TEST_TMP}/foreign.py" "${FOREIGN_PORT}" & FOREIGN_PID=$!
sleep 600 & IDLE_PID=$!
trap 'kill "${FOREIGN_PID}" "${IDLE_PID}" 2>/dev/null || true; test_teardown_env' EXIT
for _ in $(seq 1 50); do _dl_port_in_use "${FOREIGN_PORT}" && break; sleep 0.1; done
assert_eq 0 "$(_dl_pid_owns_port "${FOREIGN_PID}" "${FOREIGN_PORT}"; echo $?)" "_dl_pid_owns_port: the listener's own pid owns its port"
assert_eq 1 "$(_dl_pid_owns_port "${IDLE_PID}" "${FOREIGN_PORT}"; echo $?)" "_dl_pid_owns_port: another pid does NOT own it"
LLMCTL_SMOKE_TIMEOUT=3
rc=0; _dl_smoke_wait "${IDLE_PID}" "${FOREIGN_PORT}" /health || rc=$?
assert_eq 1 "${rc}" "a foreign server answering /health is NOT accepted as the launched server's readiness"
assert_contains "${_DL_SMOKE_WHY}" "not from the server this test launched" "...and the reason names it"
rc=0; _dl_smoke_wait "${FOREIGN_PID}" "${FOREIGN_PORT}" /health || rc=$?
assert_eq 0 "${rc}" "control: the real owner of the answering port IS ready"
kill "${IDLE_PID}" 2>/dev/null || true; wait "${IDLE_PID}" 2>/dev/null || true
rc=0; _dl_smoke_wait "${IDLE_PID}" "${FOREIGN_PORT}" /health || rc=$?
assert_eq 1 "${rc}" "a launched process that died is never ready, whatever else answers"
assert_contains "${_DL_SMOKE_WHY}" "exited" "...with the exit reason"
# the port choice: auto = a free ephemeral port; a pinned port that is in use is refused
assert_eq "auto" "$(env -u LLMCTL_SMOKE_PORT bash -c 'source "$1/lib/common.sh"; source "$1/lib/catalog.sh"; source "$1/lib/download.sh"; echo "${LLMCTL_SMOKE_PORT}"' _ "${LLMCTL_ROOT}")" "the default smoke port is 'auto' (no fixed port that a foreign server can occupy)"
unset LLMCTL_SMOKE_PORT; LLMCTL_SMOKE_PORT=auto
pp="$(_dl_smoke_pick_port)"
assert_eq 1 "$([[ "${pp}" =~ ^[0-9]+$ && "${pp}" != 18090 ]] && echo 1 || echo 0)" "auto picks an ephemeral port (not the old fixed 18090): ${pp}"
rc=0; LLMCTL_SMOKE_PORT="${FOREIGN_PORT}" _dl_smoke_pick_port >/dev/null 2>"${TEST_TMP}/pick.err" || rc=$?
assert_eq 1 "${rc}" "a pinned LLMCTL_SMOKE_PORT already in use is refused"
assert_file_contains "${TEST_TMP}/pick.err" "already in use" "...with the reason"
if command -v go >/dev/null 2>&1 && [[ -x "${TEST_TMP}/bin/fake-llama-server" ]]; then
  # end to end: a foreign server on a port + the smoke with the default (auto) port still passes against the REAL launched engine
  rm -rf "${LLMCTL_MODELS_DIR}/toy-decide"
  export LLMCTL_SMOKE=1 LLMCTL_SMOKE_PORT=auto LLMCTL_SMOKE_TIMEOUT=20 LLMCTL_DECIDE_BIN="${TEST_TMP}/bin/llmctl-decide" LLMCTL_LLAMA_SERVER="${TEST_TMP}/bin/fake-llama-server"
  out="$(download_profile toy-decide 2>&1)" && rc=0 || rc=$?
  assert_eq 0 "${rc}" "auto smoke port: the decision smoke passes with a foreign server answering elsewhere"
  used="$(sed -n 's/.*starting llama-server for toy-decide on 127.0.0.1:\([0-9]*\).*/\1/p' <<<"${out}" | head -1)"
  assert_eq 1 "$([[ -n "${used}" && "${used}" != "${FOREIGN_PORT}" ]] && echo 1 || echo 0)" "...on its own port (${used}), never the foreign server's (${FOREIGN_PORT})"
fi

test_finish
