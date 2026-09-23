#!/usr/bin/env bash
# test_scheduler_wait_ready.sh - RED-then-GREEN regression test for a real,
# live-reproduced defect (2026-09-23): `llmctl switch <profile>` (and
# `start`) reported SUCCESS the instant `svc_start` (systemctl start /
# launchctl kickstart) returned - which for a Type=simple/exec unit fires
# right after fork/exec, WELL BEFORE llama-server/colibri finishes mmapping
# and loading the model weights and is actually able to answer its
# OpenAI-compatible endpoint. "Started" never meant "ready".
#
# Live symptom: running claude_toolkit's sync-all-llmctl sweep against the
# real running llmctl instance, 4 of 10 catalog profiles (fast, vision,
# vision-pro, colibri-qwen36) reported FAIL immediately after `llmctl
# switch <profile>` itself reported success - claude_toolkit's own
# verification probe (a single curl with a 3-second timeout, no retry)
# raced real, multi-second model-load time and lost. `small` happened to
# pass only because it loaded fast enough / was already warm - the same
# race exists for EVERY caller of `llmctl switch`/`start`, not just this
# one sweep, so the correct fix is llmctl's own start/switch contract:
# "started" MUST mean "actually serving", checked here via
# _sched_wait_ready polling http://127.0.0.1:<port>/v1/models on loopback
# (readiness is always checked over loopback regardless of the configured
# LLMCTL_BIND_HOST - a service bound to 0.0.0.0 or any other address always
# also accepts loopback connections).
#
# LLMCTL_READY_TIMEOUT=0 disables the wait entirely (the sanctioned
# test-injection escape valve, defaulted for every OTHER hermetic test in
# tests/helpers.sh's test_setup_env - none of them bind a real port) - this
# file explicitly overrides it per-assertion to exercise the real behavior
# against a real, deliberately-delayed local HTTP fixture (the SAME
# "python3 -m http.server, no mocks" pattern already established in
# test_download.sh / test_cluster_request_checked.sh).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

source "${LLMCTL_ROOT}/lib/common.sh"
source "${LLMCTL_ROOT}/lib/scheduler.sh"

# --- fixture 1: a real HTTP server that does NOT start listening until
# DELAY seconds have elapsed - genuinely reproduces "connection refused,
# then eventually answers", the exact shape of a loading-then-ready model
# server, with zero mocking. ------------------------------------------------
start_delayed_server() {
  local port="$1" delay="$2"
  python3 - "${port}" "${delay}" >/dev/null 2>&1 <<'PY' &
import http.server, sys, time

port = int(sys.argv[1])
delay = float(sys.argv[2])
time.sleep(delay)

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'{"data":[{"id":"fixture-model"}]}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass

http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
  echo $!
}

# --- Test 1: the server becomes ready WELL WITHIN the timeout (a delayed
# bind simulating real model-load time) - _sched_wait_ready MUST wait for
# it and then report success, never giving up early. ------------------------
PORT1=18761
SRV1_PID="$(start_delayed_server "${PORT1}" 2)"
trap 'kill "${SRV1_PID}" 2>/dev/null || true' EXIT
t0="$(date +%s)"
rc1=0
LLMCTL_READY_TIMEOUT=10 LLMCTL_READY_POLL_INTERVAL=1 _sched_wait_ready "${PORT1}" || rc1=$?
t1="$(date +%s)"
assert_eq 0 "${rc1}" "_sched_wait_ready succeeds once the delayed server actually binds"
elapsed=$(( t1 - t0 ))
[[ "${elapsed}" -ge 1 && "${elapsed}" -le 9 ]] && ok=0 || ok=1
assert_eq 0 "${ok}" "wait genuinely blocked until readiness (elapsed=${elapsed}s, expected roughly the 2s delay, well under the 10s timeout)"
kill "${SRV1_PID}" 2>/dev/null || true

# --- Test 2: nothing EVER listens on this port - _sched_wait_ready MUST
# give up within its bounded timeout, not hang forever. ---------------------
PORT2=18762
t0="$(date +%s)"
rc2=0
LLMCTL_READY_TIMEOUT=2 LLMCTL_READY_POLL_INTERVAL=1 _sched_wait_ready "${PORT2}" || rc2=$?
t1="$(date +%s)"
assert_eq 1 "${rc2}" "_sched_wait_ready fails when nothing ever becomes ready"
elapsed2=$(( t1 - t0 ))
[[ "${elapsed2}" -ge 2 && "${elapsed2}" -le 6 ]] && ok=0 || ok=1
assert_eq 0 "${ok}" "wait is bounded by its own timeout, not open-ended (elapsed=${elapsed2}s for a 2s timeout)"

# --- Test 3: LLMCTL_READY_TIMEOUT=0 disables the wait entirely - the
# sanctioned escape valve every OTHER hermetic scheduler test relies on via
# tests/helpers.sh's test_setup_env default. Nothing listens on this port
# either, yet the call MUST succeed immediately (current, pre-fix trust of
# svc_start's own signal, deliberately preserved as an opt-out). ------------
PORT3=18763
rc3=0
LLMCTL_READY_TIMEOUT=0 _sched_wait_ready "${PORT3}" || rc3=$?
assert_eq 0 "${rc3}" "LLMCTL_READY_TIMEOUT=0 disables the wait entirely (opt-out for hermetic tests with no real listener)"

# --- Test 4: real end-to-end wiring through _sched_start_impl's own
# codepath is intentionally NOT re-derived here with a second fake-systemd
# harness (test_scheduler_switch_safety.sh already owns that fixture, and
# rewiring it to spawn a real delayed listener would duplicate this file's
# job) - the live re-run of claude_toolkit's real sync-all-llmctl sweep
# against the real, unmodified running llmctl instance is this fix's
# integration-level proof, captured separately as this session's own live
# evidence. ------------------------------------------------------------------

test_finish
