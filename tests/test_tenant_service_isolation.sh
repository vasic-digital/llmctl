#!/usr/bin/env bash
# test_tenant_service_isolation.sh - per-tenant systemd --user scope wiring
# for lib/service_linux.sh (Clarification 18, FR-049; closes the disclosed
# T072 gap: internal/isolation/cgroup.go's real isolation mechanism for
# THIS project's systemd-unit-based service model is a per-instance
# Slice= drop-in, not a systemd-run wrapper around the short-lived
# `bin/llmctl` CLI invocation - see lib/service_linux.sh's own
# _svc_ensure_tenant_slice_dropin doc comment for the full investigation).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

export LLMCTL_DRY_RUN=1
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"

# --- untenanted path is byte-identical to every prior behavior ---------------
(
  source "${LLMCTL_ROOT}/lib/common.sh"
  source "${LLMCTL_ROOT}/lib/service_linux.sh"
  svc_write_env fast llama /opt/llmctl/submodules/llama.cpp/build/bin/llama-server \
    --model /models/fast/m.gguf --port 8080
)
assert_file_exists "${LLMCTL_SERVICES_DIR}/fast.env" "untenanted: env file uses the bare profile name"
UNTENANTED_UNIT="$(
  source "${LLMCTL_ROOT}/lib/common.sh"
  source "${LLMCTL_ROOT}/lib/service_linux.sh"
  _svc_unit_for fast
)"
assert_eq "llmctl-llama@fast.service" "${UNTENANTED_UNIT}" "untenanted: unit name unchanged (no LLMCTL_TENANT_ID)"

# --- tenant-scoped path: distinct unit instance per tenant -------------------
(
  export LLMCTL_TENANT_ID=tenant-a
  source "${LLMCTL_ROOT}/lib/common.sh"
  source "${LLMCTL_ROOT}/lib/service_linux.sh"
  svc_write_env fast llama /opt/llmctl/submodules/llama.cpp/build/bin/llama-server \
    --model /models/fast/m.gguf --port 8081
)
assert_file_exists "${LLMCTL_SERVICES_DIR}/tenant-a--fast.env" "tenant-a: env file is tenant-qualified, not a bare profile name"
assert_file_contains "${LLMCTL_SERVICES_DIR}/tenant-a--fast.env" "--port 8081" "tenant-a: env file carries its own real launch args"

(
  export LLMCTL_TENANT_ID=tenant-b
  source "${LLMCTL_ROOT}/lib/common.sh"
  source "${LLMCTL_ROOT}/lib/service_linux.sh"
  svc_write_env fast llama /opt/llmctl/submodules/llama.cpp/build/bin/llama-server \
    --model /models/fast/m.gguf --port 8082
)
assert_file_exists "${LLMCTL_SERVICES_DIR}/tenant-b--fast.env" "tenant-b: SAME profile name resolves to a DIFFERENT env file than tenant-a"
assert_file_contains "${LLMCTL_SERVICES_DIR}/tenant-b--fast.env" "--port 8082" "tenant-b: its own env file carries its own real launch args (not tenant-a's)"
# tenant-a's file must be COMPLETELY unaffected by tenant-b's write - the
# real cross-tenant-collision failure mode this whole feature exists to
# prevent (mirrors T073's HTTP-layer isolation test at the bash-unit layer).
assert_file_contains "${LLMCTL_SERVICES_DIR}/tenant-a--fast.env" "--port 8081" "tenant-a: env file still carries ITS OWN args after tenant-b registered the same profile name"

TENANT_A_UNIT="$(
  export LLMCTL_TENANT_ID=tenant-a
  source "${LLMCTL_ROOT}/lib/common.sh"
  source "${LLMCTL_ROOT}/lib/service_linux.sh"
  _svc_unit_for fast
)"
assert_eq "llmctl-llama@tenant-a--fast.service" "${TENANT_A_UNIT}" "tenant-a: unit instance is tenant-qualified"

TENANT_B_UNIT="$(
  export LLMCTL_TENANT_ID=tenant-b
  source "${LLMCTL_ROOT}/lib/common.sh"
  source "${LLMCTL_ROOT}/lib/service_linux.sh"
  _svc_unit_for fast
)"
assert_eq "llmctl-llama@tenant-b--fast.service" "${TENANT_B_UNIT}" "tenant-b: unit instance is tenant-qualified, distinct from tenant-a's"

# --- svc_start/svc_enable dry-run output shows the tenant-qualified unit ----
captured="$(
  export LLMCTL_TENANT_ID=tenant-a
  source "${LLMCTL_ROOT}/lib/common.sh"
  source "${LLMCTL_ROOT}/lib/os_detect.sh"
  source "${LLMCTL_ROOT}/lib/hardware.sh"
  source "${LLMCTL_ROOT}/lib/service_linux.sh"
  svc_enable fast
)"
assert_contains "${captured}" "[dry-run] systemctl --user enable llmctl-llama@tenant-a--fast.service" "tenant-a: dry-run enable targets the tenant-qualified unit"
assert_contains "${captured}" "[dry-run] systemctl --user start llmctl-llama@tenant-a--fast.service" "tenant-a: dry-run start targets the tenant-qualified unit"

# --- the REAL isolation mechanism: a per-instance Slice= drop-in -------------
# This is the load-bearing assertion this whole feature exists for: since
# `systemctl --user start` hands the unit off to systemd's OWN user
# manager (never inheriting the calling process's cgroup), the ONLY way to
# place a tenant's model-server process under a per-tenant cgroup slice is
# a property carried BY THE UNIT ITSELF - a real drop-in file, not merely
# an environment variable passed to whatever short-lived process happened
# to invoke `systemctl --user start`.
DROPIN="${LLMCTL_UNIT_DIR}/llmctl-llama@tenant-a--fast.service.d/tenant-slice.conf"
assert_file_exists "${DROPIN}" "tenant-a: real systemd drop-in file was written for the tenant-qualified unit"
assert_file_contains "${DROPIN}" "Slice=llmctl-tenant-tenant-a.slice" "tenant-a: drop-in sets the real per-tenant Slice= property"

# tenant-b's drop-in must be independently correct and never collide with
# tenant-a's, even though svc_enable was never called for tenant-b above -
# svc_start alone (the more common runtime path) must ALSO ensure the
# drop-in exists, not only svc_enable's first-time-install path.
(
  export LLMCTL_TENANT_ID=tenant-b
  source "${LLMCTL_ROOT}/lib/common.sh"
  source "${LLMCTL_ROOT}/lib/os_detect.sh"
  source "${LLMCTL_ROOT}/lib/hardware.sh"
  source "${LLMCTL_ROOT}/lib/service_linux.sh"
  svc_start fast
) >/dev/null
DROPIN_B="${LLMCTL_UNIT_DIR}/llmctl-llama@tenant-b--fast.service.d/tenant-slice.conf"
assert_file_exists "${DROPIN_B}" "tenant-b: svc_start alone (not just svc_enable) also ensures the drop-in exists"
assert_file_contains "${DROPIN_B}" "Slice=llmctl-tenant-tenant-b.slice" "tenant-b: its own drop-in names its own slice, never tenant-a's"

# --- fail-closed on a malicious/malformed tenant ID --------------------------
# Mirrors internal/isolation/cgroup.go's Go-side sanitization (T072) so
# both languages enforce the identical allow-list rather than silently
# diverging - a tenant ID that could break out of a systemd slice-name or
# filesystem-path context must be REJECTED, never escaped-and-passed-through.
assert_rc 1 "malicious tenant ID (embedded ';') is rejected, not silently passed through" \
  bash -c '
    export LLMCTL_TENANT_ID="tenant-a; rm -rf /"
    source "'"${LLMCTL_ROOT}"'/lib/common.sh"
    source "'"${LLMCTL_ROOT}"'/lib/service_linux.sh"
    _svc_unit_for fast
  '
assert_rc 1 "malicious tenant ID (path traversal) is rejected" \
  bash -c '
    export LLMCTL_TENANT_ID="../../etc"
    source "'"${LLMCTL_ROOT}"'/lib/common.sh"
    source "'"${LLMCTL_ROOT}"'/lib/service_linux.sh"
    _svc_unit_for fast
  '
assert_rc 1 "malicious tenant ID (embedded '..' mid-string, not just a leading path-traversal) is rejected - same defense-in-depth internal/isolation/cgroup.go's Go-side validateTenantID applies beyond its charset check" \
  bash -c '
    export LLMCTL_TENANT_ID="tenant..other"
    source "'"${LLMCTL_ROOT}"'/lib/common.sh"
    source "'"${LLMCTL_ROOT}"'/lib/service_linux.sh"
    _svc_unit_for fast
  '

# --- bash and Go tenant-ID allow-lists genuinely match --------------------
# An independent code review (2026-09-15) found the bash and Go regexes
# were NOT actually identical despite comments claiming they were: Go
# permits '.' (internal/isolation/cgroup.go's tenantIDPattern), bash did
# not - so a tenant ID like "tenant.3" (which Registry.Create performs no
# format validation on, so nothing upstream would have caught this) could
# succeed against /v1/replication/* (Go-validated) but fail with an opaque
# error against /v1/tenants/:id/models/:model/start (bash-validated). This
# assertion proves the SAME tenant ID bash's own allow-list historically
# rejected is now genuinely accepted, closing that user-visible
# inconsistency rather than merely asserting bash rejects bad input.
captured="$(
  export LLMCTL_TENANT_ID="tenant.3"
  source "${LLMCTL_ROOT}/lib/common.sh"
  source "${LLMCTL_ROOT}/lib/service_linux.sh"
  _svc_unit_for fast
)"
assert_eq "llmctl-llama@tenant.3--fast.service" "${captured}" "tenant ID containing '.' (accepted by Go's allow-list) is now ALSO accepted by bash's - the two languages' allow-lists genuinely match, not merely claimed to"

test_finish
