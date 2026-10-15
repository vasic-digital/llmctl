#!/usr/bin/env bash
# test_validation_served_launch.sh - review 2026-10-15 finding 11 (served-model identity): served_model_info compared the
# PATH on the probed process's command line only. It now also checks, for a listening process that names a model:
#   * its --mmproj lies next to the model file (the profile's projector, not another one);
#   * the model file it MAPS is the file on disk now (a model replaced after it was loaded is a mismatch: the served
#     bytes are not the validated ones);
#   * with --expect-launch-env, its command line is the launch of that env record (the record binds that launch).
# A tiny fixture "engine" (python, listens on 127.0.0.1, maps its --model file) stands in for llama-server; this user's
# own process only (Constitution 11.4.174).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
JUDGE="${JUDGE_UNDER_TEST:-${LLMCTL_ROOT}/lib/validate_judge.py}"
# start_engine runs inside $(...): its pids go to a FILE outside TEST_TMP (an array append would die with the subshell)
PIDS_FILE="$(mktemp)"
trap 'while read -r p; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done < "${PIDS_FILE}"; rm -f "${PIDS_FILE}"; test_teardown_env' EXIT
D="${TEST_TMP}/models/vision"; O="${TEST_TMP}/other"; mkdir -p "${D}" "${O}"
printf 'model bytes A\n' > "${D}/model.gguf"; printf 'proj\n' > "${D}/mmproj.gguf"; printf 'proj\n' > "${O}/mmproj.gguf"
ENG="${TEST_TMP}/engine.py"
cat > "${ENG}" <<'PY'
import mmap, socket, sys, time
a = sys.argv[1:]
model = a[a.index("--model") + 1]
f = open(model, "rb"); m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(5)
open(a[a.index("--port-file") + 1], "w").write(str(s.getsockname()[1]))
time.sleep(120)
PY
PY3="$(command -v python3)"
start_engine() { # start_engine <args...> -> port
  local pf; pf="$(mktemp -u "${TEST_TMP}/pf.XXXXXX")"
  "${PY3}" -I "${ENG}" "$@" --port-file "${pf}" >/dev/null 2>&1 & echo "$!" >> "${PIDS_FILE}"
  local i; for (( i=0; i<100; i++ )); do [[ -s "${pf}" ]] && break; sleep 0.1; done
  cat "${pf}"
}
envrec() { # envrec <file> <args...> - an env record of the launch python3 <engine> <args...>
  { printf 'LLMCTL_EXEC=%q\n' "${PY3}"; printf 'LLMCTL_ARGS='; printf '%q ' -I "${ENG}" "${@:2}"; printf '\n'; } > "$1"
}
sm() { # sm <port> [launch-env] -> mismatch text, or OK
  python3 -I - "${JUDGE}" "http://127.0.0.1:$1" "${D}/model.gguf" "${2:-}" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("vj", sys.argv[1]); vj = importlib.util.module_from_spec(spec); spec.loader.exec_module(vj)
i = vj.served_model_info(sys.argv[2], sys.argv[3], [], 5, sys.argv[4] or None)
print(i.get("mismatch") or ("OK" if i["confirmed"] else "UNCONFIRMED"))
PY
}

echo "== control: the profile's model and projector, the launch of the env record -> confirmed"
P1="$(start_engine --model "${D}/model.gguf" --mmproj "${D}/mmproj.gguf")"
envrec "${TEST_TMP}/ok.env" x --model "${D}/model.gguf" --mmproj "${D}/mmproj.gguf" --port-file X
assert_eq OK "$(sm "${P1}")" "same model, projector next to it -> confirmed"

echo "== a projector from another directory -> mismatch"
P2="$(start_engine --model "${D}/model.gguf" --mmproj "${O}/mmproj.gguf")"
assert_contains "$(sm "${P2}")" "--mmproj" "another projector is a mismatch"

echo "== the model file replaced on disk after it was loaded -> mismatch"
P3="$(start_engine --model "${D}/model.gguf" --mmproj "${D}/mmproj.gguf")"
sleep 0.3
printf 'model bytes B (replaced)\n' > "${D}/model.gguf.new"; mv -f "${D}/model.gguf.new" "${D}/model.gguf"
assert_contains "$(sm "${P3}")" "replaced after it was loaded" "the served bytes are not the file on disk"

echo "== a launch that is not the env record's -> mismatch; the env record's own launch -> confirmed"
P4="$(start_engine --model "${D}/model.gguf" --mmproj "${D}/mmproj.gguf" --seed 7)"
envrec "${TEST_TMP}/a.env" x --model "${D}/model.gguf" --mmproj "${D}/mmproj.gguf"
assert_contains "$(sm "${P4}" "${TEST_TMP}/a.env")" "not the launch of" "a process run with --seed 7 is not the launch the env record describes"
PF4="$(tr '\0' '\n' < "/proc/$(sed -n 4p "${PIDS_FILE}")/cmdline" | tail -1)"
{ printf 'LLMCTL_EXEC=%q\n' "${PY3}"; printf 'LLMCTL_ARGS='; printf '%q ' -I "${ENG}" --model "${D}/model.gguf" --mmproj "${D}/mmproj.gguf" --seed 7 --port-file "${PF4}"; printf '\n'; } > "${TEST_TMP}/b.env"
assert_eq OK "$(sm "${P4}" "${TEST_TMP}/b.env")" "control: the env record of exactly that launch -> confirmed"
test_finish
