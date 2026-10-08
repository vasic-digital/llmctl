#!/usr/bin/env bash
# test_go_unit.sh - Go unit tier for the decision layer (Gin gateway, client, keyring, certs...).
# Stand-ins are allowed only in this tier (spec FR-039). Uses the pinned go.sum; fails if the
# module graph does not verify. Bytecode/binaries are never written into the work tree.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
if ! command -v go >/dev/null 2>&1; then echo "SKIP-SUITE: go toolchain not installed (decision layer unit tier not run)"; exit 0; fi
export GOFLAGS="-mod=readonly"
go mod verify
go vet ./...
go test -count=1 -cover ./...
echo "  ok: go mod verify, go vet ./... and go test ./... all passed"
echo "go unit tier OK"
