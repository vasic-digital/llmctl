#!/usr/bin/env bash
# test_containers_optin.sh - meta-check (review round 5, I-2): a tests/*.sh suite that runs the Go toolchain on a package which
# imports digital.vasic.containers (internal/gateway, internal/registry, cmd/llmctl-decide, ./...) FAILS with a misleading
# "FAIL: control run passes" or a 600 s timeout when the containers dependency is unresolvable, unless it calls
# `require_containers_or_skip` (tests/helpers.sh) at the top. This test scans every tests/test_*.sh: a NON-COMMENT line holding
# `go build|test|list|vet|run` requires an un-commented `require_containers_or_skip` line, or an entry (with its reason) in
# tests/containers_optin_exempt.txt for suites whose go packages do not depend on containers. Stale exemptions fail.
# The scanner is control-needled first: a planted suite without the opt-in MUST be flagged, one with it and a comment-only
# mention MUST NOT be.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

GO_RE='(^|[^[:alnum:]_/.-])go (build|test|list|vet|run)([[:space:]]|$)'
# NOTE: no `grep -q` at the end of a pipeline under pipefail: -q exits at the first match, the upstream grep gets SIGPIPE (141) and a
# LARGE file with an early match reads as "no go line" (found live: it hid test_decide_security_mutation.sh). Count instead.
has_go() { local n; n="$(grep -vE '^[[:space:]]*#' "$1" | grep -cE "${GO_RE}" || true)"; [[ "${n:-0}" -gt 0 ]]; }
has_optin() { grep -qE '^require_containers_or_skip([[:space:]]|$)' "$1"; }

W="$(mktemp -d "${TMPDIR:-/tmp}/llmctl-optin.XXXXXX")"; trap 'rm -rf -- "${W}"' EXIT
printf 'x=1\n( cd r && go test ./internal/gateway/ )\n' > "${W}/planted_missing.sh"
printf 'require_containers_or_skip\n( cd r && go test ./internal/gateway/ )\n' > "${W}/planted_optin.sh"
printf '# run go build ./... later\necho hi\n' > "${W}/planted_comment.sh"
{ printf '( cd r && go test ./internal/gateway/ )\n'; for _i in $(seq 1 6000); do printf 'echo filler line number %s to make this file larger than a pipe buffer\n' "${_i}"; done; } > "${W}/planted_big.sh"
if has_go "${W}/planted_big.sh" && ! has_optin "${W}/planted_big.sh"; then echo "  ok: control needle: an EARLY go line in a LARGE file is still seen (the SIGPIPE/pipefail trap)"; else printf '  FAIL: large-file go line missed\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
if has_go "${W}/planted_missing.sh" && ! has_optin "${W}/planted_missing.sh"; then echo "  ok: control needle: a planted suite with a go line and no opt-in is flagged"; else printf '  FAIL: the scanner is blind to a missing opt-in\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
if has_go "${W}/planted_optin.sh" && has_optin "${W}/planted_optin.sh"; then echo "  ok: control: a planted suite with the opt-in passes"; else printf '  FAIL: opt-in not recognised\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
if ! has_go "${W}/planted_comment.sh"; then echo "  ok: control: a comment-only mention is not a go line"; else printf '  FAIL: comment counted as a go line\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); fi

EX="${TESTS_DIR}/containers_optin_exempt.txt"
declare -A exempt=()
while IFS=$'\t' read -r f reason; do
  [[ -z "${f}" || "${f}" == \#* ]] && continue
  [[ -n "${reason}" ]] || { printf '  FAIL: exemption %s has no reason\n' "${f}" >&2; TEST_FAILS=$((TEST_FAILS+1)); }
  exempt["${f}"]=1
done < "${EX}"

missing=""; stale=""
for t in "${TESTS_DIR}"/test_*.sh; do
  n="$(basename "${t}")"
  if has_go "${t}"; then
    if has_optin "${t}"; then
      [[ -z "${exempt[${n}]:-}" ]] || stale+="${n}(opted in but exempt) "
    elif [[ -z "${exempt[${n}]:-}" ]]; then
      missing+="${n} "
    fi
  else
    [[ -z "${exempt[${n}]:-}" ]] || stale+="${n}(no go line) "
  fi
done
for n in "${!exempt[@]}"; do [[ -f "${TESTS_DIR}/${n}" ]] || stale+="${n}(file gone) "; done
assert_eq "" "${missing}" "every suite with a go build|test|list|vet|run line opts in (or is exempt with a reason)"
assert_eq "" "${stale}" "no stale exemption"
test_finish
