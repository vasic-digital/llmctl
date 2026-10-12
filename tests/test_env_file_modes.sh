#!/usr/bin/env bash
# test_env_file_modes.sh - RED-first (security audit L6). The service env record holds key-file paths and LLMCTL_REG_TOKEN;
# it (and every temp file produced while rewriting it, and the new memory drop-ins) must never be wider than 0600 at any
# observable point, under a restrictive AND a permissive umask. A background watcher polls the services dir and the
# drop-in dirs every ~2 ms while svc_write_env runs repeatedly.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
export LLMCTL_DRY_RUN=1 LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
# shellcheck disable=SC1090
for l in common os_detect hardware catalog portreg service_linux; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
WATCH_OUT="${TEST_TMP}/watch.out"
run_case() { # <umask>
  local um="$1"; rm -rf "${LLMCTL_SERVICES_DIR}" "${LLMCTL_UNIT_DIR}"; mkdir -p "${LLMCTL_SERVICES_DIR}" "${LLMCTL_UNIT_DIR}"
  python3 - "${LLMCTL_SERVICES_DIR}" "${LLMCTL_UNIT_DIR}" "${WATCH_OUT}" <<'PY' &
import os, stat, sys, time
roots, out = sys.argv[1:3], sys.argv[3]
wide, end = [], time.time() + 25
open(out + ".ready", "w").close()
while time.time() < end and not os.path.exists(out + ".stop"):
    for root in roots:
        for dp, dns, fns in os.walk(root):
            for n in fns + dns:
                p = os.path.join(dp, n)
                try:
                    m = os.lstat(p).st_mode
                except OSError:
                    continue
                if stat.S_ISLNK(m):
                    continue
                if stat.S_ISREG(m) and (m & 0o077):
                    wide.append("%s %o" % (p, m & 0o777))
    time.sleep(0.002)
open(out, "w").write("\n".join(sorted(set(wide))))
PY
  local w=$!; rm -f "${WATCH_OUT}.stop"
  for _ in $(seq 1 100); do [[ -e "${WATCH_OUT}.ready" ]] && break; sleep 0.05; done
  ( umask "${um}"
    for _ in $(seq 1 15); do svc_write_env vision llama /bin/true --port 18990 >/dev/null 2>&1; done )
  touch "${WATCH_OUT}.stop"; wait "${w}" 2>/dev/null || true; rm -f "${WATCH_OUT}.ready"
  local wide; wide="$(cat "${WATCH_OUT}" 2>/dev/null || true)"
  if [[ -z "${wide}" ]]; then echo "  ok: umask ${um}: no regular file under the service/unit dirs was ever wider than 0600"
  else printf '  FAIL: umask %s: files wider than 0600 observed:\n%s\n' "${um}" "${wide}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
  assert_eq "600" "$(stat -c %a "${LLMCTL_SERVICES_DIR}/vision.env")" "umask ${um}: final env record is 0600"
  assert_file_exists "${LLMCTL_UNIT_DIR}/llmctl-llama@vision.service.d/05-memory.conf" "umask ${um}: drop-in written (so the check above covered it)"
}
run_case 077
run_case 000
test_finish
