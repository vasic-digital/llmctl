#!/usr/bin/env bash
# Unit test for run_profiles.sh ev_path: the evidence directory a driver names in its evpath file is
# accepted only when it really resolves (symlinks and '..' followed) to a directory under the
# evidence root that the user owns. Each mutation of the check (accept anything, drop the realpath
# step, drop the owner test) must turn one of these assertions red. Hermetic: temp dirs only.
# STRICT-EXEMPT: counts failures itself with ok/bad so no -e
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$ROOT/scripts/livetest/run_profiles.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
EVROOT="$T/evroot"; mkdir -p "$EVROOT/ok" "$T/outside"
ln -s "$T/outside" "$EVROOT/link"
# take the function text from the real script, not a copy
src="$(sed -n '/^ev_path() {/,/^}/p' "$RUN")"
[ -n "$src" ] || { echo "  FAIL: ev_path not found in run_profiles.sh"; exit 1; }
eval "$src"
try() {   # try <label> <path-line> <expect: accept|reject>
  local f="$T/f"; printf '%s\n' "$2" >"$f"
  local got; got="$(ev_path "$f")"
  if [ "$3" = accept ]; then [ -n "$got" ] && ok "$1" || bad "$1 (rejected, should be accepted)"
  else [ -z "$got" ] && ok "$1" || bad "$1 (accepted: $got)"; fi
}
try "a real directory under the root"           "$EVROOT/ok" accept
try "a '..' escape out of the root"             "$EVROOT/../outside" reject
try "a symlink pointing outside the root"       "$EVROOT/link" reject
try "a relative path"                           "ok" reject
try "the root itself"                           "$EVROOT" reject
try "a path outside the root"                   "$T/outside" reject
try "a missing directory under the root"        "$EVROOT/nope" reject
try "an empty line"                             "" reject
# owner test in isolation: a root-owned directory that IS under the (re-pointed) root, so only the ownership check can reject it
if [ "$(stat -c %u /usr/share)" != "$(id -u)" ] && [ -d /usr/share/doc ]; then
  EVROOT=/usr/share try "a directory under the root owned by another user" "/usr/share/doc" reject
else
  echo "  SKIP: ownership case (needs /usr/share/doc owned by another user than $(id -un)); the -O check is NOT exercised in this environment"
fi
printf '\nRESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -ne 0 ] || echo "  ok: all $PASS ev_path assertions passed"
[ "$FAIL" = 0 ]
