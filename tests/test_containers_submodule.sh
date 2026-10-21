#!/usr/bin/env bash
# test_containers_submodule.sh - T069 / FR-091 / Helix §11.4.76: the Containers submodule is the
# one implementation of port allocation, service registry and health probing. Asserts:
#   1. containers is NOT a submodule of llmctl any more: it is resolved (lib/resolve_deps.sh) and linked (scripts/link_deps.sh)
#   2. go.mod requires digital.vasic.containers and replaces it with ./submodules/containers (the link)
#   3. internal/registry really depends on the submodule packages it claims to use
#   4. a grep gate finds no own port-allocator / registry reimplementation markers in internal/ and cmd/
#      (the gate is itself validated against a golden-bad and a golden-good fixture tree)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
cd "${LLMCTL_ROOT}"

assert_not_contains() { if [[ "$1" != *"$2"* ]]; then printf '  ok: %s\n' "$3"; else printf '  FAIL: %s\n' "$3" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi; }

echo "== 1. containers is resolved, not vendored (single source of truth, owner mandate 2026-10-21) =="
if grep -qF 'submodules/containers' .gitmodules; then
  printf '  FAIL: .gitmodules must NOT declare submodules/containers (it is resolved from the hub by lib/resolve_deps.sh)\n' >&2; TEST_FAILS=$((TEST_FAILS+1))
else
  printf '  ok: .gitmodules does not declare submodules/containers\n'
fi
assert_eq "" "$(git ls-files -s submodules/containers | awk '$1==160000')" "no gitlink for submodules/containers in the index"
assert_eq "" "$(awk '/name: containers/{f=1} f&&/pinned:/{print $2; exit}' helix-deps.yaml)" "helix-deps.yaml records no private pin for containers (the hub copy is the one source)"
assert_file_contains helix-deps.yaml "layout: hub-resolved" "helix-deps.yaml marks containers as hub-resolved"
if ! resolved="$(bash lib/resolve_deps.sh containers 2>/dev/null)"; then
  skip_suite "containers cannot be resolved on this host (set LLMCTL_CONTAINERS_DIR or nest llmctl in the constitution hub; see docs/dependency-layout.md)"
fi
bash scripts/link_deps.sh >/dev/null
assert_file_exists "${resolved}/go.mod" "resolved containers tree is checked out (go.mod present)"
assert_file_contains "${resolved}/go.mod" "module digital.vasic.containers" "resolved module path is digital.vasic.containers"
assert_eq "$(cd "${resolved}" && pwd -P)" "$(cd submodules/containers && pwd -P)" "submodules/containers (go.mod replace target) points at the resolved copy"

echo "== 2. go.mod wiring =="
assert_file_contains go.mod "digital.vasic.containers v0.0.0" "go.mod requires digital.vasic.containers"
assert_file_contains go.mod "replace digital.vasic.containers => ./submodules/containers" "go.mod replaces it with the vendored submodule"

echo "== 3. internal/registry builds on the submodule packages =="
if command -v go >/dev/null 2>&1; then
  deps="$(GOFLAGS=-mod=readonly go list -deps ./internal/registry)"
  for pkg in pkg/network pkg/serviceregistry pkg/health; do
    assert_contains "${deps}" "digital.vasic.containers/${pkg}" "go list -deps ./internal/registry includes ${pkg}"
  done
  assert_contains "$(grep -rhE 'network\.NewPortAllocator|serviceregistry\.New\(|health\.NewDefaultChecker' internal/registry --include='*.go' --exclude='*_test.go')" "NewPortAllocator" "the allocator in use is network.PortAllocator"
else
  echo "  SKIP: go not installed (dependency-graph assertions not run)"
fi

echo "== 4. no parallel implementation of what the submodule provides =="
# markers of a hand-rolled allocator / registry in non-test Go code (an ephemeral `Listen(...:0)` is
# NOT a marker: servers legitimately bind :0; only the free-port-finder shapes are)
reimpl_markers() { # <dir...>
  grep -rnE --include='*.go' --exclude='*_test.go' \
    -e 'func +(\([^)]*\) +)?[A-Za-z]*([Ff]ind|[Pp]ick|[Nn]ext|[Gg]et|[Ii]s)[A-Za-z]*(Free|Available|Unused)[A-Za-z]*Port' \
    -e 'func +(\([^)]*\) +)?[A-Za-z]*FreePort' \
    -e 'type +[A-Za-z]*PortAllocator +struct' \
    -e 'type +[A-Za-z]*(Service|Port)Registry +struct' \
    "$@" 2>/dev/null || true
}
fx="$(mktemp -d)"; trap 'rm -rf "${fx}"' EXIT
mkdir -p "${fx}/bad" "${fx}/good"
cat > "${fx}/bad/alloc.go" <<'GO'
package bad

import "net"

func findFreePort() int {
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	defer ln.Close()
	return ln.Addr().(*net.TCPAddr).Port
}

type ServiceRegistry struct{ m map[string]int }
GO
cat > "${fx}/good/ok.go" <<'GO'
package good

import "digital.vasic.containers/pkg/network"

func pick() (int, error) { return network.NewPortAllocator(20000, 20100).Allocate("x") }
GO
assert_eq "yes" "$([[ -n "$(reimpl_markers "${fx}/bad")" ]] && echo yes || echo no)" "gate flags the golden-bad fixture (own allocator + registry)"
assert_eq "no" "$([[ -n "$(reimpl_markers "${fx}/good")" ]] && echo yes || echo no)" "gate passes the golden-good fixture (submodule allocator)"
found="$(reimpl_markers internal cmd)"
assert_eq "" "${found}" "no own port-allocator/registry reimplementation in internal/ and cmd/"
[[ -z "${found}" ]] || printf '%s\n' "${found}" >&2

[[ ${TEST_FAILS} -eq 0 ]] && echo "test_containers_submodule: ALL PASS" || { echo "test_containers_submodule: ${TEST_FAILS} FAILED" >&2; exit 1; }
