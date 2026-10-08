#!/usr/bin/env bash
# test_certs_go_mutation.sh - paired mutation check for internal/certs (Constitution §1.1).
#
# Each mutant breaks ONE security-relevant behaviour in a throw-away COPY of the
# package (a temp module; the working tree is never touched, so there is nothing
# to restore) and the package's own tests MUST then fail. A mutant that survives
# means a guard is decoration. A baseline (unmutated) run must pass first, so a
# failure is attributable to the mutation alone.
# Not mutated: the byte-compare inside exportOffline (a defensive check with no
# injectable fault: a copy written by this process always equals its source).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT
command -v go >/dev/null 2>&1 || { echo "SKIP-SUITE: go not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP-SUITE: python3 needed to apply mutations"; exit 0; }

SRC="${LLMCTL_ROOT}/internal/certs"
fresh() {
  rm -rf "${TEST_TMP}/mod"; mkdir -p "${TEST_TMP}/mod/internal/certs" "${TEST_TMP}/mod/internal/placement"
  printf 'module github.com/vasic-digital/llmctl\n\ngo 1.25.0\n' > "${TEST_TMP}/mod/go.mod"
  cp "${SRC}"/*.go "${TEST_TMP}/mod/internal/certs/"
  cp "${LLMCTL_ROOT}"/internal/placement/*.go "${TEST_TMP}/mod/internal/placement/"
}
gotest() { ( cd "${TEST_TMP}/mod" && timeout 300 go test -count=1 ./internal/certs/ >"${TEST_TMP}/out.txt" 2>&1 ); }

# mutate <file> <old> <new>  (exact, single occurrence required)
mutate() {
  python3 - "$1" "$2" "$3" "${TEST_TMP}/mod/internal/certs" <<'PY'
import sys
f, old, new, d = sys.argv[1:5]
p = (d + "/../" + f) if "/" in f else (d + "/" + f)  # a path with "/" is relative to internal/
s = open(p).read()
if s.count(old) != 1:
    sys.exit("mutation did not apply (%d matches): %s" % (s.count(old), old))
open(p, "w").write(s.replace(old, new))
PY
}

echo "== baseline: unmutated copy passes =="
fresh
if gotest; then printf '  ok: baseline green\n'; else printf '  FAIL: baseline red\n' >&2; tail -20 "${TEST_TMP}/out.txt" >&2; exit 1; fi

# kill <name> <file> <old> <new>
kill_mutant() {
  local name="$1"; shift
  fresh
  if ! mutate "$@" 2>"${TEST_TMP}/mut.err"; then
    printf '  FAIL: %s (%s)\n' "${name}" "$(cat "${TEST_TMP}/mut.err")" >&2; TEST_FAILS=$((TEST_FAILS+1)); return
  fi
  if gotest; then
    printf '  FAIL: mutant SURVIVED: %s\n' "${name}" >&2; TEST_FAILS=$((TEST_FAILS+1))
  else
    printf '  ok: killed - %s (%s)\n' "${name}" "$(grep -m1 -E '^--- FAIL' "${TEST_TMP}/out.txt" | sed 's/ (.*//')"
  fi
}

echo "== mutants =="
kill_mutant "M1 name constraints dropped from the CA" ca.go 'if in.constrained {' 'if false {'
kill_mutant "M2 flock removed (no serialisation)" placement.go 'err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil' 'err := error(nil); err != nil'
kill_mutant "M3 keys written world-readable" ca.go 'return os.Chmod(path, 0o600)' 'return os.Chmod(path, 0o644)'
kill_mutant "M4 git placement guard skipped" placement.go 'func CheckPlacement(certDir string) error {' 'func CheckPlacement(certDir string) error {
	return nil
}

func checkPlacementOriginal(certDir string) error {'
kill_mutant "M5 expiry not enforced" certs.go 'if enforce && now.After(leaf.NotAfter) {' 'if false && now.After(leaf.NotAfter) {'
kill_mutant "M6 current swapped non-atomically" leaf.go 'if err := os.Rename(tmp, filepath.Join(certDir, "current")); err != nil {' '_ = os.Remove(filepath.Join(certDir, "current")); time.Sleep(2 * time.Millisecond); if err := os.Rename(tmp, filepath.Join(certDir, "current")); err != nil {'
kill_mutant "M7 new leaf not verified against the CA" leaf.go 'return errf("the new leaf does not verify' '_ = errf("the new leaf does not verify'
kill_mutant "M8 leaf also valid for clientAuth" leaf.go 'ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},' 'ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},'
kill_mutant "M9 out-of-range addresses not filtered" sans.go 'if in.constrained && !ipPermitted(a.Unmap(), nets) {' 'if false && !ipPermitted(a.Unmap(), nets) {'
kill_mutant "M10 --reuse-key ignored" certs.go 'if o.ReuseKey && cur != "" {' 'if false && cur != "" {'
kill_mutant "M11 CA key not matched before signing" ca.go 'if !keyMatches(k, ca) {' 'if false && !keyMatches(k, ca) {'
kill_mutant "M13 mode switch accepted silently" certs.go 'case requested != "" && existing != "" && requested != existing:' 'case false:'
kill_mutant "M14 key/cert mismatch not detected" ca.go 'return ok && pub.Equal(c.PublicKey)' 'return ok && (true || pub.Equal(c.PublicKey))'

# --- review-2 A-04 / A-10 / A-11 hardening
kill_mutant "M15 placement guard fails OPEN on a git error" placement/placement.go '		return refuse("git gave an unexpected answer (exit %d) while checking whether %s is inside a git work tree; %s",
			r.code, abs, s.Fix)' '		return nil'
kill_mutant "M16 private-key owner/mode not enforced" secfile.go '	if strict {' '	if false {'
kill_mutant "M17 key file opened following symlinks" secfile.go 'os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK' 'os.O_RDONLY|syscall.O_NONBLOCK'
kill_mutant "M18 key file opened blocking (FIFO hangs)" secfile.go 'os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK' 'os.O_RDONLY|syscall.O_NOFOLLOW'
kill_mutant "M19 export publishes with rename (overwrites a racing file)" secfile.go '		err = linkFn(tmp, dest)' '		err = os.Rename(tmp, dest)'
kill_mutant "M20 forced export writes through a symlink" secfile.go '		err = os.Rename(tmp, dest)
	} else {' '		err = os.WriteFile(dest, data, 0o600)
	} else {'
kill_mutant "M21 weak BYO RSA key accepted" secfile.go 'if pub.N.BitLen() < 2048 {' 'if false {'
kill_mutant "M22 exported CA key created world-readable" secfile.go 'f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o600)' 'f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o644)'
kill_mutant "M22b exported CA key (no-hard-link fallback) created world-readable" secfile.go 'f, err := os.OpenFile(dest, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o600)' 'f, err := os.OpenFile(dest, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o644)'
# (Removing the up-front Lstat refusal in exportSecret is an EQUIVALENT mutant: the atomic link(2) refuses
#  the same destination with the same message; M19 proves the link is what guards the race.)

[[ ${TEST_FAILS} -eq 0 ]] && echo "test_certs_go_mutation: ALL MUTANTS KILLED" || { echo "test_certs_go_mutation: ${TEST_FAILS} FAILED" >&2; exit 1; }
