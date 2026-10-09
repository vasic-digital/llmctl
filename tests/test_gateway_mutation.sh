#!/usr/bin/env bash
# test_gateway_mutation.sh - T042 paired mutations (FR-038..040): each guard of the gateway wiring is
# broken in a COPY of the sources (nothing in the repo tree is touched) and the Go tests MUST go RED;
# an unmutated control copy MUST stay GREEN first (a mutation test with a red baseline proves nothing).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT
command -v go >/dev/null 2>&1 || { echo "SKIP-SUITE: go not installed"; exit 0; }

W="${TEST_TMP}/work"
mkdir -p "${W}"
cp -R "${LLMCTL_ROOT}/cmd" "${LLMCTL_ROOT}/internal" "${LLMCTL_ROOT}/go.mod" "${LLMCTL_ROOT}/go.sum" "${W}/"
ln -s "${LLMCTL_ROOT}/submodules" "${W}/submodules"
cp -R "${LLMCTL_ROOT}/models" "${W}/"   # internal/gateway tests read ../../models/catalog.json
mkdir -p "${W}/lib" && cp "${LLMCTL_ROOT}/lib/decide.sh" "${W}/lib/"   # TestFrontEndWordsMatchLibDecideSh reads ../../lib/decide.sh
mkdir -p "${W}/specs/009-jev-decision-models"   # cmd tests check the CLI contract doc against the binary (B2-16)
cp -R "${LLMCTL_ROOT}/specs/009-jev-decision-models/contracts" "${W}/specs/009-jev-decision-models/"
[[ -f "${LLMCTL_ROOT}/helix-deps.yaml" ]] && cp "${LLMCTL_ROOT}/helix-deps.yaml" "${W}/"

gotest() { ( cd "${W}" && go test -count=1 "$@" ) >"${TEST_TMP}/out" 2>&1; }

echo "== control: unmutated copy is GREEN =="
rc=0; gotest ./internal/gateway ./cmd/llmctl-decide || rc=$?
assert_eq "0" "${rc}" "control run passes"

# mutate <name> <file> <python-old> <python-new> <go test args...>
mutate() {
  local name="$1" file="$2" old="$3" new="$4"; shift 4
  cp "${W}/${file}" "${TEST_TMP}/orig"
  python3 - "${W}/${file}" "${old}" "${new}" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
assert s.count(old) == 1, "mutation anchor found %d times" % s.count(old)
open(p, "w").write(s.replace(old, new))
PY
  # PRECONDITION (C3-14): the mutant must COMPILE, tests included. A mutation that fails to build is
  # "killed" by the compiler, not by a test, and proves nothing: report it INVALID, never as killed.
  local rc=0
  if ! ( cd "${W}" && go build ./... && go test -count=1 -run '^$' "$@" ) >"${TEST_TMP}/buildout" 2>&1; then
    cp "${TEST_TMP}/orig" "${W}/${file}"
    printf '  INVALID: mutation %s does not compile (fix the mutation):\n' "${name}" >&2
    sed 's/^/      /' "${TEST_TMP}/buildout" | head -5 >&2
    TEST_FAILS=$((TEST_FAILS+1))
    return 0
  fi
  gotest "$@" || rc=$?
  cp "${TEST_TMP}/orig" "${W}/${file}"
  if [[ ${rc} -ne 0 ]]; then printf '  ok: mutation %s -> tests RED\n' "${name}"; else printf '  FAIL: mutation %s survived (tests stayed GREEN)\n' "${name}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
}

echo "== mutations (each must turn the tests RED) =="
mutate "readout threshold ignored" internal/gateway/letter.go \
  'readout.ComputeRaw(top, letters, thr, temp)' 'readout.ComputeRaw(top, letters, 0.0001, temp)' ./internal/gateway
mutate "letter-logit request drops chat_template_kwargs.enable_thinking" internal/gateway/letter.go \
  '			"chat_template_kwargs": map[string]any{"enable_thinking": false},' '			"chat_template_kwargs": map[string]any{},' ./internal/gateway
mutate "deterministic seed dropped" internal/gateway/letter.go \
  '			body["seed"] = ResolveSeed(b.Seed)' '			_ = ResolveSeed(b.Seed)' ./internal/gateway
mutate "unverified pid is signalled" internal/gateway/proc.go \
  'if err := VerifyServeProcessInfo(info, binName); err != nil {
		return StopRefused, fmt.Errorf("pid %d is alive' 'if false {
		return StopRefused, fmt.Errorf("pid %d is alive' ./internal/gateway ./cmd/llmctl-decide
mutate "pid <= 1 guard removed" internal/gateway/proc.go \
  'if pid <= 1 {
		return fmt.Errorf("refusing pid %d", pid)' 'if pid < 0 {
		return fmt.Errorf("refusing pid %d", pid)' ./internal/gateway
mutate "bind default changed" cmd/llmctl-decide/cmd_serve.go \
  'defaultBind = "0.0.0.0"' 'defaultBind = "127.0.0.1"' ./cmd/llmctl-decide
mutate "global bind host ignored" cmd/llmctl-decide/cmd_serve.go \
  'env["LLMCTL_DECIDE_BIND"], env["LLMCTL_BIND_HOST"]}' 'env["LLMCTL_DECIDE_BIND"]}' ./cmd/llmctl-decide
mutate "loopback-only engine check removed" internal/gateway/resolver.go \
  'if ip := net.ParseIP(h); ip != nil && ip.IsLoopback() {' 'if ip := net.ParseIP(h); ip != nil {' ./internal/gateway
mutate "LLMCTL_PORT_<PROFILE> override ignored by the static resolver" internal/gateway/resolver.go \
  'port = p' '_ = p' ./internal/gateway
mutate "LLMCTL_PORT_<PROFILE> port range unchecked" internal/gateway/resolver.go \
  'err == nil && p >= 1 && p <= 65535 {' 'err == nil {' ./internal/gateway
mutate "cache_prompt forced on" internal/gateway/letter.go \
  '"cache_prompt": spec.Readout.CachePrompt && b.Mode == Throughput, // never in deterministic mode (B2-12)' '"cache_prompt": true,' ./internal/gateway
mutate "engine error text echoed" internal/gateway/driver.go \
  '	if status != http.StatusOK {
		return nil, classifyEngineStatus(ep, path, status, b) // engine text (b) never reaches a client' '	if status != http.StatusOK {
		return nil, &contract.ContractError{Status: 502, ErrorType: contract.ErrTypeBackendFailed, Message: string(b)} // MUTANT' ./internal/gateway
mutate "silent NLI truncation" internal/gateway/nli.go \
  'if !n.Truncate {' 'if false {' ./internal/gateway
mutate "overflow in deterministic mode ignores primary" internal/gateway/router.go \
  '	for _, e := range eps {
		if s := r.slotFor(e.URL); r.tryAcquire(s) {
			return e, s, nil
		}
	}
	e := eps[0]' '	for i := len(eps) - 1; i >= 0; i-- {
		if s := r.slotFor(eps[i].URL); r.tryAcquire(s) {
			return eps[i], s, nil
		}
	}
	e := eps[0]' ./internal/gateway
mutate "NLI entailment read from a fixed column" internal/gateway/nli.go \
  'ent[i] = row[cols.entail]' 'ent[i] = row[len(row)-1-0*cols.entail-0*cols.contra]' ./internal/gateway
mutate "NLI generic label_source accepted" internal/gateway/nli.go \
  'if strings.HasPrefix(src, "generic-config") || strings.HasPrefix(src, "none") {' 'if false && src != "" {' ./internal/gateway
mutate "NLI not_entailment accepted beside a third label" internal/gateway/nli.go \
  'if len(labels) != 2 || cols.entail < 0 {' 'if cols.entail < 0 {' ./internal/gateway
mutate "NLI two-label head without an entailment column accepted (decoder panic)" internal/gateway/nli.go \
  'if len(labels) != 2 || cols.entail < 0 {' 'if len(labels) != 2 {' ./internal/gateway
mutate "NLI binary entailment/not_entailment head refused again" internal/gateway/nli.go \
  'if seen["not_entailment"] > 0 {' 'if false {' ./internal/gateway
mutate "NLI truncation not reported to the gateway" internal/gateway/nli.go \
  '			server.NoteTruncated(ctx)' '			_ = server.NoteTruncated' ./internal/gateway
mutate "key file permission check removed" internal/gateway/keyfile.go \
  'if fi.Mode().Perm()&^0o600 != 0 {' 'if false {' ./internal/gateway
# both symlink guards go together: the Lstat refusal AND O_NOFOLLOW (either alone still refuses, C3-14)
mutate "symlinked key file followed (Lstat refusal and O_NOFOLLOW removed)" internal/gateway/keyfile.go \
  '	if st.Mode()&os.ModeSymlink != 0 {
		return "", fmt.Errorf("key file %s: a symlink is refused", path)
	}
	// O_NOFOLLOW closes the lstat/open race: the file opened is the file checked.
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)' '	_ = st
	f, err := os.OpenFile(path, os.O_RDONLY|(syscall.O_NOFOLLOW&0), 0)' ./internal/gateway
mutate "401 retry reuses the same key" internal/gateway/keyfile.go \
  'if err != nil || key == ep.Key {' 'if err != nil {' ./internal/gateway
mutate "SDK model listing dropped" internal/server/handlers.go \
  '	}{"list", data, models})' '	}{"list", data, nil})' ./internal/server
mutate "lingering drain removed" internal/server/handlers.go \
  '	_, _ = io.Copy(io.Discard, io.LimitReader(r.Body, lingerMaxBytes))' '	_ = lingerMaxBytes' ./internal/server

# T137 (FR-080): calibration application and the decision log
mutate "router no longer applies the calibration profile" internal/gateway/router.go \
  '		answers[i].Answer = r.cfg.Calibrations.Apply(spec.ID, answers[i].Answer)' '		_ = i' ./internal/gateway
mutate "calibration may raise a flagged answer above its worst case" internal/gateway/calibration.go \
  'len(a.Flags) > 0 && v > pmax' 'false' ./internal/gateway
mutate "calibration ignores the readout temperature in the template hash" internal/gateway/calibration.go \
  'th, err := TemplateHash(spec, temperature)' 'th, err := TemplateHash(spec, 1)' ./internal/gateway
mutate "calibration profile file permission check removed" internal/gateway/calibration.go \
  '!fi.Mode().IsRegular() || fi.Mode().Perm()&0o022 != 0' '!fi.Mode().IsRegular()' ./internal/gateway
mutate "calibration refusal logged on every reload" internal/gateway/calibration.go \
  'if s.logged[spec.ID] != key && logf != nil' 'if logf != nil' ./internal/gateway
mutate "decision log keeps state text without consent" internal/audit/decision.go \
  '	if f.Consent {
		st := f.State' '	if true {
		st := f.State' ./internal/audit
mutate "decision log keeps question text without consent" internal/audit/decision.go \
  '		if f.Consent {
			n, q := a.Name, a.Question' '		if true {
			n, q := a.Name, a.Question' ./internal/audit
mutate "decision log not written" internal/server/handlers.go \
  '	s.logDecision(c, status, d)' '	_ = status' ./internal/server
mutate "SIGHUP no longer reloads the calibration profiles" cmd/llmctl-decide/cmd_serve.go \
  '			p.reloadCalibration() // the same signal re-reads the calibration profiles' '			_ = p' ./cmd/llmctl-decide
mutate "decision log consent flag ignored" cmd/llmctl-decide/cmd_serve.go \
  'Decisions: p.decisionWriter(), DecisionState: p.decState,' 'Decisions: p.decisionWriter(), DecisionState: true,' ./cmd/llmctl-decide

# 502 reason headers: a deadline expiry must stay distinguishable from an engine fault (a slow CPU
# engine must not be retried as if it had failed)
mutate "deadline expiry no longer reported as deadline_exceeded" internal/server/handlers.go \
  'if errors.Is(reqCtx.Err(), context.DeadlineExceeded) && parent.Err() == nil {' 'if false {' ./internal/server
mutate "engine fault reported as deadline_exceeded" internal/server/handlers.go \
  '	h.Set("x-llmctl-decide-reason", "engine_error")' '	h.Set("x-llmctl-decide-reason", "deadline_exceeded")' ./internal/server

test_finish
