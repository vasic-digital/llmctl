#!/usr/bin/env bash
# test_decide_security_mutation.sh - paired mutations for the review-2 scope-A security fixes
# (Constitution §1.1, Helix 11.4.194(6)(d)). Every guard added or changed by the A-01..A-18 fixes is
# broken in a COPY of the sources (nothing in the repo tree is touched) and the Go tests of that
# package MUST go RED; the unmutated control copy MUST stay GREEN first. The first block replays the
# seven mutations the independent reviewer wrote (review-A-security.md, A-17).
# Each mutant runs with a test timeout so a mutation that makes a test HANG fails cleanly.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT
command -v go >/dev/null 2>&1 || { echo "SKIP-SUITE: go not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP-SUITE: python3 needed to apply mutations"; exit 0; }

W="${TEST_TMP}/work"
mkdir -p "${W}"
cp -R "${LLMCTL_ROOT}/cmd" "${LLMCTL_ROOT}/internal" "${LLMCTL_ROOT}/go.mod" "${LLMCTL_ROOT}/go.sum" "${W}/"
ln -s "${LLMCTL_ROOT}/submodules" "${W}/submodules"
cp -R "${LLMCTL_ROOT}/models" "${W}/"   # internal/gateway tests read ../../models/catalog.json
mkdir -p "${W}/specs/009-jev-decision-models"   # cmd/llmctl-decide tests read the CLI contract
cp -R "${LLMCTL_ROOT}/specs/009-jev-decision-models/contracts" "${W}/specs/009-jev-decision-models/"
[[ -f "${LLMCTL_ROOT}/helix-deps.yaml" ]] && cp "${LLMCTL_ROOT}/helix-deps.yaml" "${W}/"
# Repo files outside cmd/ + internal/ that the Go tests read by relative path. A missing one made the
# control RED and let mutants be "killed" by the open() error instead of by the test meant to catch them.
mkdir -p "${W}/lib" "${W}/docs" "${W}/specs/009-jev-decision-models/evidence/review-2"
cp "${LLMCTL_ROOT}/lib/decide.sh" "${W}/lib/"   # cmd/llmctl-decide TestFrontEndWordsMatchLibDecideSh
cp "${LLMCTL_ROOT}/docs/decide-gateway.md" "${LLMCTL_ROOT}/docs/registry-discovery.md" "${W}/docs/"   # internal/contract
cp "${LLMCTL_ROOT}/specs/009-jev-decision-models/evidence/review-2/ctx-measurements.json" \
   "${W}/specs/009-jev-decision-models/evidence/review-2/"   # internal/contract

PKGS=(./internal/server ./internal/keyring ./internal/certs ./internal/audit ./internal/placement ./internal/metrics ./internal/gateway ./internal/contract ./cmd/llmctl-decide)

# Fixture completeness, discovered mechanically: every "../../<path>" literal in a test of a mutated package
# must exist in the copy (a new relative read added later is caught here, not by a bogus kill).
missing=0; seen=0
while IFS= read -r rel; do
  seen=$((seen+1))
  [[ -e "${W}/${rel#../../}" ]] || { printf '  FAIL: test fixture missing from the scratch copy: %s\n' "${rel}" >&2; missing=$((missing+1)); }
done < <(cd "${LLMCTL_ROOT}" && grep -ohE '"\.\./\.\./[A-Za-z0-9_./-]+"' "${PKGS[@]/#.\//}" -r --include='*_test.go' | tr -d '"' | grep -v '/etc/passwd$' | sort -u)
[[ ${seen} -gt 0 ]] || { echo "  FAIL: fixture scan found no relative reads at all (instrument blind?)" >&2; missing=1; }   # control needle: the lib/decide.sh read exists
assert_eq "0" "${missing}" "every relative-path test fixture is present in the scratch copy (${seen} checked)"

TO="${DECIDE_MUTATION_TIMEOUT:-300s}"
gotest() { ( cd "${W}" && go test -count=1 -timeout "${TO}" "$@" ) >"${TEST_TMP}/out" 2>&1; }

echo "== control: unmutated copy is GREEN =="
rc=0
if [[ -n "${DECIDE_MUTATION_ONLY:-}" ]]; then echo "  (DECIDE_MUTATION_ONLY set: full control skipped; each mutant's own target control still runs)"
else gotest "${PKGS[@]}" || rc=$?; assert_eq "0" "${rc}" "control run passes"; fi
[[ ${rc} -eq 0 ]] || { echo "--- control output (failing lines) ---" >&2; grep -E -- '--- FAIL|^FAIL|\.go:[0-9]+:' "${TEST_TMP}/out" | head -20 >&2; }

# A kill is attributed only when the IDENTICAL go test target (pkg + flags, incl. -run/-race) is GREEN on
# the unmutated copy: then the mutation is the only difference and the failure is caused by it. A build or
# setup failure is an invalid mutant, never a kill.
declare -A CONTROL_OK=()
control_for() {
  local key="$*"
  [[ -n "${CONTROL_OK[${key}]:-}" ]] && { [[ "${CONTROL_OK[${key}]}" == ok ]]; return; }
  local rc=0; gotest "$@" || rc=$?
  if [[ ${rc} -eq 0 ]] && grep -qE '^ok ' "${TEST_TMP}/out" && ! grep -q 'no tests to run' "${TEST_TMP}/out"; then
    CONTROL_OK[${key}]=ok
  else
    CONTROL_OK[${key}]=bad
    printf '  FAIL: control for target [%s] is not GREEN with tests run (no kill on it can be attributed): %s\n' \
      "${key}" "$(grep -m1 -E -- '--- FAIL|no tests to run|\[(build|setup) failed\]' "${TEST_TMP}/out")" >&2
    TEST_FAILS=$((TEST_FAILS+1))
  fi
  [[ "${CONTROL_OK[${key}]}" == ok ]]
}
KILL_LEDGER="${DECIDE_MUTATION_LEDGER:-${TEST_TMP}/kill_ledger.tsv}"
: >"${KILL_LEDGER}"

# kill <name> <file> <old> <new> <go test pkg> [-run regexp]
kill() {
  local name="$1" file="$2" old="$3" new="$4" pkg="$5"; shift 5
  # DECIDE_MUTATION_ONLY=<ERE>: run only the matching mutants (debugging aid; a full run leaves it unset)
  if [[ -n "${DECIDE_MUTATION_ONLY:-}" ]] && ! [[ "${name}" =~ ${DECIDE_MUTATION_ONLY} ]]; then return 0; fi
  control_for "${pkg}" "$@" || return 0
  cp "${W}/${file}" "${TEST_TMP}/orig"
  if ! python3 - "${W}/${file}" "${old}" "${new}" <<'PY' 2>"${TEST_TMP}/mut.err"
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) != 1:
    sys.exit("mutation did not apply (%d matches)" % s.count(old))
open(p, "w").write(s.replace(old, new))
PY
  then
    printf '  FAIL: %s (%s)\n' "${name}" "$(cat "${TEST_TMP}/mut.err")" >&2; TEST_FAILS=$((TEST_FAILS+1)); return
  fi
  local rc=0
  gotest "${pkg}" "$@" || rc=$?
  cp "${TEST_TMP}/orig" "${W}/${file}"
  local by
  by="$(grep -E '^\s*--- FAIL: |^panic: test timed out' "${TEST_TMP}/out" | sed -E 's/^\s*--- FAIL: //; s/ \(.*//' | sort -u | paste -sd, -)" || true   # no FAIL line (survivor) must not trip set -e/pipefail
  if [[ ${rc} -eq 0 ]]; then
    printf '  FAIL: mutant SURVIVED: %s\n' "${name}" >&2; TEST_FAILS=$((TEST_FAILS+1))
    printf 'SURVIVED\t%s\t-\n' "${name}" >>"${KILL_LEDGER}"
  elif grep -qE '\[(build|setup) failed\]' "${TEST_TMP}/out"; then
    printf '  FAIL: invalid mutant (does not compile, no test ran): %s (%s)\n' "${name}" \
      "$(grep -m1 -E '\.go:[0-9]+:[0-9]+: ' "${TEST_TMP}/out")" >&2; TEST_FAILS=$((TEST_FAILS+1))
    printf 'INVALID\t%s\t-\n' "${name}" >>"${KILL_LEDGER}"
  elif [[ -z "${by}" ]]; then
    printf '  FAIL: mutant run failed without a failing test (setup error, not a kill): %s\n' "${name}" >&2; TEST_FAILS=$((TEST_FAILS+1))
    printf 'NOTEST\t%s\t-\n' "${name}" >>"${KILL_LEDGER}"
  else
    printf '  ok: killed - %s (%s)\n' "${name}" "${by}"
    printf 'KILLED\t%s\t%s\n' "${name}" "${by}" >>"${KILL_LEDGER}"
  fi
}

echo "== the reviewer's seven mutations (A-17) =="
kill "R-M1 duplicate Authorization guard removed" internal/server/handlers.go 'if len(vs) != 1 {' 'if false {' ./internal/server
kill "R-M2 session tickets enabled" internal/server/server.go '	c.SessionTicketsDisabled = true' '	c.SessionTicketsDisabled = false' ./internal/server
kill "R-M3 'serve' subcommand requirement dropped" internal/gateway/proc.go '	if len(argv) < 2 || argv[1] != "serve" {' '	if len(argv) < 2 {' ./internal/gateway
kill "R-M4 previous-key expiry ignored" internal/keyring/keyring.go 'now.Unix() < n {' 'true || now.Unix() < n {' ./internal/keyring
kill "R-M5 present-but-wrong key never reaches the throttle" internal/server/handlers.go '	if throttled {' '	if throttled && false {' ./internal/server
kill "R-M6 CGNAT range dropped from the CA name constraints" internal/certs/sans.go '100.64.0.0/10' '100.64.0.0/32' ./internal/certs
kill "R-M7 binary-name match dropped (the reviewer's run hung)" internal/gateway/proc.go '	named := filepath.Base(argv[0]) == binName' '	named := true' ./internal/gateway

echo "== A-01 admission =="
kill "eviction removed: a full pool refuses the newcomer again" internal/server/slots.go '		v := t.pickVictim()
		if v == nil {' '		var v *slotEntry
		if v == nil {' ./internal/server
kill "unauthenticated budget not enforced (no reserve)" internal/server/slots.go 'if t.unauth >= t.maxUnauth || t.total >= t.max {' 'if t.total >= t.max {' ./internal/server
kill "authenticated connections can be evicted" internal/server/slots.go '		if e.authed {
			continue
		}' '		if false {
			continue
		}' ./internal/server
kill "victim taken from the LIGHTEST source" internal/server/slots.go '			if t.perU[e.src] > t.perU[best.src] {' '			if t.perU[e.src] < t.perU[best.src] {' ./internal/server
kill "IPv6 /48 aggregate cap off" internal/server/slots.go '	for t.aggU[agg] >= t.maxUnauthAgg {' '	for false {' ./internal/server
kill "a valid key never promotes the connection" internal/server/handlers.go '				sc.markAuthed() // leaves the unauthenticated pool: it can no longer be evicted or reaped' '				_ = sc' ./internal/server
kill "pre-auth timer never armed" internal/server/conn.go '			sc.armPreAuth(l.preAuth)' '			_ = l.preAuth' ./internal/server
kill "pre-auth timer not stopped on authentication" internal/server/conn.go '	if c.timer != nil {
		c.timer.Stop()
	}
	c.authMu.Unlock()
	if c.entry != nil {
		c.entry.promote()' '	c.authMu.Unlock()
	if c.entry != nil {
		c.entry.promote()' ./internal/server
kill "unauthenticated per-source cap off" internal/server/slots.go ' || t.perU[src] >= t.maxUnauthPer {' ' {' ./internal/server

echo "== A2-03 / A2-04 / A2-T1 admission (review 3) =="
kill "A2-03 victim ranking ignores the /48 aggregate" internal/server/slots.go '		case t.aggU[e.agg] != t.aggU[best.agg]:' '		case false:' ./internal/server
kill "A2-03 victim taken from the LIGHTEST aggregate" internal/server/slots.go '			if t.aggU[e.agg] > t.aggU[best.agg] {' '			if t.aggU[e.agg] < t.aggU[best.agg] {' ./internal/server
kill "A2-04 per-source cap refuses the newcomer instead of evicting its own oldest" internal/server/slots.go '		v := t.oldestUnauth(func(e *slotEntry) bool { return e.src == src })
		if v == nil {' '		var v *slotEntry
		if v == nil {' ./internal/server
kill "A2-04 the source-cap victim may be an authenticated connection" internal/server/slots.go '		if e.authed || !in(e) {' '		if !in(e) {' ./internal/server
kill "A2-T1 removeLocked never returns the aggregate share (IPv4 locked out forever)" internal/server/slots.go '		if t.aggU[e.agg]--; t.aggU[e.agg] <= 0 {
			delete(t.aggU, e.agg)
		}
	}
}

// release frees' '	}
}

// release frees' ./internal/server
kill "A2-T1 promote never returns the aggregate share" internal/server/slots.go '	if t.aggU[e.agg]--; t.aggU[e.agg] <= 0 {
		delete(t.aggU, e.agg)
	}
	return true' '	return true' ./internal/server

echo "== A-06 / A-09 / A-14 server =="
kill "failed auth never delayed" internal/server/handlers.go '		s.sleep(c.Request.Context(), d) // progressive: slows guessing, never touches the valid key' '		_ = d' ./internal/server
kill "throttled sources evicted for a newcomer" internal/server/throttle.go '		if e.n > t.limit {
			continue // actively throttled: never evicted for a newcomer
		}' '		if false {
			continue
		}' ./internal/server
kill "full table of throttled sources admits a newcomer" internal/server/throttle.go 'if len(t.m) >= t.max && !t.makeRoom(now) {' 'if false && !t.makeRoom(now) {' ./internal/server
kill "GetConfigForClient result not hardened" internal/server/server.go '			return hardenTLS(c.Clone()), nil' '			return c, nil' ./internal/server
kill "audit write failure not counted" internal/server/handlers.go '		s.metrics.Inc(metrics.AuditWriteFailure)' '		_ = metrics.AuditWriteFailure' ./internal/server
# (the earlier form of this mutant, '_ = s.auditErr; func() {', never compiled - unbalanced braces and a
#  copied sync.Once - so it was "killed" by the build failure, not by a test; both forms below compile)
kill "audit write failure never reported" internal/server/handlers.go '		s.auditErr.Do(func() {' '		s.auditErr.Do(func() { return;' ./internal/server
kill "audit write failure reported on every failure (once-guard dropped)" internal/server/handlers.go '		s.auditErr.Do(func() {' '		func(f func()) { f() }(func() {' ./internal/server
kill "credential gate shorter than the longest key" internal/server/handlers.go 'const maxCredentialBytes = keyring.MaxKeyLen' 'const maxCredentialBytes = keyring.MaxKeyLen - 12' ./internal/server   # (keeps the keyring import used: the old '= 500' form did not compile)

echo "== A-03 / A-06 / A-07 / A-12 keyring =="
kill "rotate refuses a well-formed weak old key (the remedy fails)" internal/keyring/keyring.go '	if hadOld && !keyRE.MatchString(old) {' '	if hadOld {' ./internal/keyring
kill "rotate keeps a weak old key as PREVIOUS" internal/keyring/keyring.go ' && WeakKey(old) == "" // a weak key was never accepted' ' // MUTANT' ./internal/keyring
kill "rotate --grace keeps a key the environment shadowed" internal/keyring/keyring.go '	accepted := hadOld && old != "" && old == effective' '	accepted := hadOld && old != "" && (old == effective || effective != "")' ./internal/keyring   # (keeps "effective" used: the old form did not compile)
kill "A2-01 PREVIOUS accepted although the key comes from the environment (CLI and gateway environments differ)" internal/keyring/keyring.go '	if res.Source != "file" {' '	if false {' ./internal/keyring
kill "A2-01 a weak PREVIOUS is accepted" internal/keyring/keyring.go ' && WeakKey(prev) == "" && isDigits(exp)' ' && isDigits(exp)' ./internal/keyring
kill "entropy floor off" internal/keyring/keyring.go '	if why := WeakKey(value); why != "" {' '	if why := WeakKey(value); false && why != "" {' ./internal/keyring   # (the old 'if false {' left "why" undefined: did not compile)
kill "comparison on raw (variable-length) bytes" internal/keyring/keyring.go '		ok |= ctEqual(cand, digest(k.Reveal()))' '		_ = cand; ok |= ctEqual([]byte(candidate), []byte(k.Reveal()))' ./internal/keyring   # (keeps "cand" used: the old form did not compile)
kill "env file opened following symlinks" internal/keyring/env.go 'os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK' 'os.O_RDONLY|syscall.O_NONBLOCK' ./internal/keyring
kill "env file opened blocking (FIFO hangs)" internal/keyring/env.go 'os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK' 'os.O_RDONLY|syscall.O_NOFOLLOW' ./internal/keyring
kill "tighten chmods the PATH, not the checked descriptor" internal/keyring/env.go 'fchmodFn   = func(f *os.File, m os.FileMode) error { return f.Chmod(m) }' 'fchmodFn   = func(f *os.File, m os.FileMode) error { return os.Chmod(f.Name(), m) }' ./internal/keyring
kill "key length bound removed" internal/keyring/keyring.go '{32,512}$`)' '{32,}$`)' ./internal/keyring

echo "== A-04 / A-05 placement and log key =="
kill "placement guard fails OPEN on a git error" internal/placement/placement.go '		return refuse("git gave an unexpected answer (exit %d) while checking whether %s is inside a git work tree; %s",
			r.code, abs, s.Fix)' '		return nil' ./internal/placement
kill "placement guard fails OPEN on a git timeout" internal/placement/placement.go '	case r.timedOut:
		return refuse("could not determine whether' '	case r.timedOut:
		return nil
		return refuse("could not determine whether' ./internal/placement
kill "ambient GIT_DIR not scrubbed" internal/placement/placement.go '"GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OPTIONAL_LOCKS",' '"GIT_OPTIONAL_LOCKS",' ./internal/placement
kill "log key created without the placement guard" internal/audit/logkey.go '	if statErr != nil {
		// FR-087: the log key is a secret too.' '	if false {
		// FR-087: the log key is a secret too.' ./internal/audit
kill "log key opened blocking (FIFO hangs the start)" internal/audit/logkey.go 'os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK' 'os.O_RDONLY|syscall.O_NOFOLLOW' ./internal/audit

echo "== B2-11 / B2-15 (merged into FIX-E) =="
kill "B2-11 the instance header is never set" internal/server/handlers.go 'if inst := instance(); inst != "" {' 'if inst := instance(); false && inst != "" {' ./internal/server -run 'InstanceHeader'
kill "B2-15 R2 legacy pidfile older than the process accepted" internal/gateway/proc.go 'if started.After(info.Start.Add(2 * time.Second)) {' 'if false && started.After(info.Start.Add(2 * time.Second)) {' ./internal/gateway -run 'LegacyPidfileOlder'

echo "== A2-05 / A2-06 / A2-08 certs =="
kill "A2-05 placement guard consulted on every start/reload/renew" internal/certs/placement.go '	if _, err := os.Lstat(certDir); err != nil {' '	if true {' ./internal/certs
kill "A2-06 no fallback where link(2) is unsupported" internal/certs/secfile.go '		if err != nil && linkUnsupported(err) {' '		if false {' ./internal/certs
kill "A2-06 every link error triggers the fallback" internal/certs/secfile.go '	case syscall.EPERM, syscall.ENOTSUP, syscall.EXDEV, syscall.ENOSYS, syscall.EMLINK:
		return true' '	case syscall.EPERM, syscall.ENOTSUP, syscall.EXDEV, syscall.ENOSYS, syscall.EMLINK, syscall.EACCES:
		return true' ./internal/certs
kill "A2-06 the key copy is left on the medium after a failed verification" internal/certs/ca.go 'if rmErr := os.Remove(dest); rmErr != nil && !os.IsNotExist(rmErr) {' 'if rmErr := error(nil); rmErr != nil {' ./internal/certs
kill "A2-06 verification judges the medium's mode bits" internal/certs/ca.go 'return readPrivate(dest, false) }' 'return readPrivate(dest, true) }' ./internal/certs
kill "A2-08 the served key is re-read by path" internal/certs/certs.go '	pair, err := tls.X509KeyPair(certPEM, c.keyPEM)' '	kb, _ := os.ReadFile(c.LeafKey)
	pair, err := tls.X509KeyPair(certPEM, kb)' ./internal/certs

echo "== A2-07 pidfd =="
kill "A2-07 raw hard-coded pidfd_open syscall number in the linux file" internal/gateway/proc_linux.go '	return unix.PidfdOpen(pid, 0)' '	fd, _, e := syscall.Syscall(434, uintptr(pid), 0, 0)
	if e != 0 {
		return -1, e
	}
	return int(fd), nil' ./internal/gateway -run 'NoRawSyscall'
# the non-linux fallback must exist and the package must cross-build for every target. A "_linux.go" file
# suffix is itself a constraint, so the mutation drops the //go:build line of the NON-linux file instead:
# its declarations then collide with proc_linux.go on a linux build.
xbuild() { ( cd "${W}" && GOOS="$1" GOARCH="$2" go build ./internal/gateway/ ) >"${TEST_TMP}/xout" 2>&1; }
for target in "darwin arm64" "darwin amd64" "linux arm64" "linux mips"; do
  set -- ${target}; rc=0; xbuild "$1" "$2" || rc=$?
  assert_eq "0" "${rc}" "control: internal/gateway cross-builds for $1/$2"
done
cp "${W}/internal/gateway/proc_other.go" "${TEST_TMP}/orig"
sed -i '1d' "${W}/internal/gateway/proc_other.go"   # drop the //go:build !linux line
rc=0; xbuild linux arm64 || rc=$?
cp "${TEST_TMP}/orig" "${W}/internal/gateway/proc_other.go"
if [[ ${rc} -eq 0 ]]; then printf '  FAIL: mutant SURVIVED: the non-linux pidfd fallback without its build constraint still builds for linux\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else echo "  ok: killed - proc_other.go without //go:build !linux does not build for linux"; fi
# macOS must not reach any raw syscall: the darwin build of the package may not contain syscall.Syscall
rc=0; ( cd "${W}" && GOOS=darwin GOARCH=arm64 go list -f '{{.GoFiles}}' ./internal/gateway/ | grep -q proc_linux.go ) || rc=$?
assert_eq "1" "${rc}" "the darwin build does not include proc_linux.go"

echo "== A2-02 serve start check =="
kill "A2-02 the start no longer reads the accepted-key set once" cmd/llmctl-decide/cmd_serve.go 'if ks, kerr := p.readKeys(); kerr != nil || len(ks) == 0 {' 'if ks, kerr := p.readKeys(); false && (kerr != nil || len(ks) == 0) {' ./cmd/llmctl-decide

echo "== A-13 / A-15 serve =="
kill "key cache keeps the last good set forever" cmd/llmctl-decide/serve_hardening.go '	if now.Sub(c.goodAt) > keyStaleGrace {' '	if false {' ./cmd/llmctl-decide
kill "key source failure not counted" cmd/llmctl-decide/serve_hardening.go '			c.reg.Inc(metrics.KeySourceError)' '			_ = c.reg' ./cmd/llmctl-decide
kill "key source failure not reported" cmd/llmctl-decide/serve_hardening.go '		if prob != c.lastProb {' '		if false {' ./cmd/llmctl-decide
kill "pidfile removed even when it names another process" cmd/llmctl-decide/serve_hardening.go 'err == nil && info.PID == pid {' 'err == nil || info.PID == pid {' ./cmd/llmctl-decide
kill "detached child inherits the legacy key variable" cmd/llmctl-decide/serve_hardening.go '	cmd.Env = childEnviron(os.Environ())' '	cmd.Env = os.Environ()' ./cmd/llmctl-decide

echo "== A3 (review 4) =="
kill "A3-T1/N13 Accept passes the source as its own /48 aggregate" internal/server/conn.go 'l.slots.admitInto(src, agg, sc.abort, func(e *slotEntry) { sc.entry = e }) == nil {' 'l.slots.admitInto(src, src, sc.abort, func(e *slotEntry) { sc.entry = e; _ = agg }) == nil {' ./internal/server -run 'TestAccept'
kill "A3-02 the entry is stored after it is visible (data race between two listeners)" internal/server/slots.go '	if set != nil {
		set(e)
	}
	t.mu.Unlock()' '	t.mu.Unlock()
	if set != nil {
		set(e)
	}' ./internal/server -race -run 'TestTwoListeners'
kill "A3-T2/N5 AcceptedKeys reads PREVIOUS when the key source is none" internal/keyring/keyring.go '	if res.Source != "file" {
		return keys, nil' '	if res.Source == "env" {
		return keys, nil' ./internal/keyring
kill "A3-T3/N7 an empty accepted-key set no longer refuses the start" cmd/llmctl-decide/cmd_serve.go 'kerr != nil || len(ks) == 0 {' 'kerr != nil || len(ks) < 0 {' ./cmd/llmctl-decide -run 'TestPrepareRefuses'
kill "A3-T4/N12 the instance label length bound removed" internal/contract/instance.go '	if len(label) <= InstanceLabelMax {' '	if true {' ./internal/contract -run 'TestInstanceNote'
kill "A3-01 placement guard never armed for key creation (pre-existing cert dir)" internal/certs/placement.go '	if currentDir(certDir) != "" {
		return nil
	}
	p := certDir' '	if true {
		return nil
	}
	p := certDir' ./internal/certs
kill "A3-01 placement guard armed on every start/reload/renew again (provisioned install stopped by a git fault)" internal/certs/placement.go '	if currentDir(certDir) != "" {
		return nil
	}
	p := certDir' '	p := certDir' ./internal/certs
kill "A3-01 symlinked cert dir not resolved before asking git" internal/certs/placement.go '	if r, err := filepath.EvalSymlinks(certDir); err == nil {
		p = r
	}' '' ./internal/certs
kill "A3-03 rotate does not say an environment-sourced gateway is unaffected" internal/keyring/cli.go 'It does not affect a gateway that takes LLMCTL_API_KEY from its own environment' 'It affects every gateway' ./internal/keyring

test_finish
