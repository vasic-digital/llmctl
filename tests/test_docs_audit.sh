#!/usr/bin/env bash
# test_docs_audit.sh - T121 / SC-009: documentation audit. tests/py/docs_audit.py checks README.md + docs/ for
# stale counts, wrong ports, missing links, code/doc mismatch and literal keys. The audit is proven BEFORE it is
# trusted on the real tree:
#   * golden-good fixture MUST report 0 mismatches (no false positive);
#   * one golden-bad fixture per rule MUST be flagged by exactly that rule (control needles: a null from an
#     instrument that cannot see a planted defect says nothing);
#   * an empty tree MUST be BLIND (exit 2), never "clean";
#   * the real repository MUST report 0 mismatches and every rule MUST have examined something.
# shellcheck disable=SC2016  # fixture text deliberately contains literal backticks and $VAR
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT
command -v python3 >/dev/null 2>&1 || { echo "SKIP-SUITE: python3 not installed"; exit 0; }
AUDIT="${LLMCTL_ROOT}/tests/py/docs_audit.py"
assert_file_exists "${AUDIT}" "tests/py/docs_audit.py exists"

mk_good() { # <dir>
  local d="$1"
  mkdir -p "${d}/docs/integrations" "${d}/models" "${d}/lib"
  printf '# R\nSee [ports](docs/ports.md) and [guide](docs/guide.md#top).\nProfiles `fast` 8080 and `decide` (8093) run locally.\n' >"${d}/README.md"
  printf '# Ports\n\n| Port | Profile | Engine |\n|---|---|---|\n| 8080 | `fast` | llama |\n| 8093 | `decide` | llama |\n' >"${d}/docs/ports.md"
  printf '# Guide\nThere are 2 profiles and one decide profile. 2 CLI agents are supported. Set LLMCTL_FOO. Run `llmctl decide ask`.\nAuthorization: Bearer $LLMCTL_KEY\n' >"${d}/docs/guide.md"
  printf '{"ports":{"fast":8080,"decide":8093},"profiles":{"fast":{},"decide":{}}}\n' >"${d}/models/catalog.json"
  : >"${d}/docs/integrations/install_a.sh"
  : >"${d}/docs/integrations/install_b.sh"
  printf 'echo "${LLMCTL_FOO:-}${LLMCTL_KEY:-}"\n' >"${d}/lib/x.sh"
  printf 'cmd_decide() {\n  case "${1:-}" in\n    ask)  :;;\n    help|-h) :;;\n  esac\n}\n_DECIDE_FORWARDED="scale"\n' >"${d}/lib/decide.sh"
}
run_audit() { rc=0; out="$(python3 "${AUDIT}" --root "$1" 2>&1)" || rc=$?; }
examined_all() { # <label>
  local r
  for r in links ports counts code keys; do
    case "${out}" in
      *"examined ${r}="[1-9]*) printf '  ok: rule %s examined items on the %s\n' "${r}" "$1" ;;
      *) printf '  FAIL: rule %s examined nothing on the %s\n' "${r}" "$1" >&2; TEST_FAILS=$((TEST_FAILS+1)) ;;
    esac
  done
}

G="${TEST_TMP}/good"; mk_good "${G}"
run_audit "${G}"
assert_eq 0 "${rc}" "golden-good fixture: 0 mismatches"
examined_all "good fixture"

bad() { # <rule> <description> <mutation function>
  local rule="$1" what="$2" fn="$3"
  local d="${TEST_TMP}/bad_${rule}_${fn}"
  mk_good "${d}"; "${fn}" "${d}"
  run_audit "${d}"
  assert_eq 1 "${rc}" "golden-bad (${what}): exit 1"
  assert_contains "${out}" "MISMATCH ${rule} " "golden-bad (${what}): flagged by rule ${rule}"
}
m_link()  { printf 'see [gone](docs/nope.md)\n' >>"$1/docs/guide.md"; }
m_port()  { sed -i 's/| 8093 |/| 8099 |/' "$1/docs/ports.md"; }
m_port2() { printf 'Run `fast` 9999 now.\n' >>"$1/README.md"; }
m_cnt()   { printf 'All three decide profiles ship pinned.\n' >>"$1/docs/guide.md"; }
m_cnt2()  { printf 'all 7 CLI agents\n' >>"$1/docs/guide.md"; }
m_env()   { printf 'Set LLMCTL_NOT_IN_CODE=1.\n' >>"$1/docs/guide.md"; }
m_sub()   { printf 'Use `llmctl decide frobnicate` here.\n' >>"$1/docs/guide.md"; }
m_key()   { printf 'curl -H "Authorization: Bearer abcdEFGH1234abcdEFGH1234abcdEFGH1234abc"\n' >>"$1/docs/guide.md"; }
bad links "missing link" m_link
bad ports "table disagrees with catalog" m_port
bad ports "prose mention disagrees with catalog" m_port2
bad counts "stale decide-profile count" m_cnt
bad counts "stale CLI-agent count" m_cnt2
bad code "env var absent from code" m_env
bad code "unknown decide subcommand" m_sub
bad keys "literal bearer key" m_key

# negative controls: the allowed forms must NOT be flagged
N="${TEST_TMP}/neg"; mk_good "${N}"
printf 'Use `llmctl decide scale x 2`, `LLMCTL_PORT_<PROFILE>`, [web](https://example.org/x.md), [anchor](#top), --api-key "$KEY".\n' >>"${N}/docs/guide.md"
printf '```\n[fenced](docs/not-a-link.md) all 9 CLI agents\n```\n' >>"${N}/docs/guide.md"
mkdir -p "${N}/docs/research"
printf 'all 9 CLI agents [x](nope.md)\n' >"${N}/docs/research/old.md"
run_audit "${N}"
assert_eq 0 "${rc}" "negative controls (placeholders, urls, anchors, fences, historical dirs) are not flagged"

E="${TEST_TMP}/empty"; mkdir -p "${E}"
run_audit "${E}"
assert_eq 2 "${rc}" "empty tree is BLIND (exit 2), not clean"

echo "-- real repository --"
run_audit "${LLMCTL_ROOT}"
printf '%s\n' "${out}" | sed 's/^/    /'
assert_eq 0 "${rc}" "real README.md + docs/: 0 mismatches (SC-009)"
examined_all "real tree"
test_finish
