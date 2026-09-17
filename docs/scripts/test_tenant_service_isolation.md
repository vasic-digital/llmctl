## Overview

`tests/test_tenant_service_isolation.sh` proves the per-tenant systemd
`--user` scope wiring added to `lib/service_linux.sh`
(Clarification 18, FR-049) genuinely isolates concurrent tenants' model
servers from one another at the cgroup level, and that the bash-side
tenant-ID validation matches the Go daemon's own validation exactly. It
closes a disclosed gap (T072): `internal/isolation/cgroup.go`'s real
isolation mechanism for *this* project's systemd-unit-based service
model is a per-instance `Slice=` drop-in file, not a `systemd-run`
wrapper around the short-lived `bin/llmctl` CLI invocation — because
`systemctl --user start` hands the unit off to systemd's own user
manager, which never inherits the calling process's cgroup, so the
*only* way to place a tenant's model-server process under a per-tenant
cgroup slice is a property carried by the unit itself.

## Prerequisites

* Sources `tests/helpers.sh` for assertion helpers and
  `test_setup_env`/`test_finish`.
* Sets `LLMCTL_DRY_RUN=1` and
  `LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"` for
  the whole file.
* Sources, in isolated subshells, `lib/common.sh`, `lib/os_detect.sh`,
  `lib/hardware.sh`, and `lib/service_linux.sh`, calling
  `svc_write_env`, `_svc_unit_for`, `svc_enable`, and `svc_start`
  directly.
* Uses `LLMCTL_TENANT_ID` — the opt-in environment variable this feature
  is entirely keyed on. Unset (the default) is the single-host,
  untenanted path; setting it (`tenant-a`, `tenant-b`, and later
  deliberately-malicious values) activates the tenant-qualified naming
  and per-tenant `Slice=` drop-in mechanism.
* Relies on `test_setup_env`'s isolated `LLMCTL_SERVICES_DIR` (per-tenant
  `.env` files) and `LLMCTL_UNIT_DIR` (systemd unit + drop-in
  destination).
* Requires `bash -c '...'` subshell invocation for the malicious-tenant-ID
  assertions (via the shared `assert_rc` helper), since the validation
  path calls `die()` which exits the process — each malicious case must
  run in its own subprocess so a rejection doesn't abort the whole test
  file.

## Usage examples

```bash
bash tests/test_tenant_service_isolation.sh
```

Also runs as part of the full suite via `tests/run_tests.sh` or
`make test`.

## Edge cases

* **Untenanted path is byte-identical to prior behavior**: with
  `LLMCTL_TENANT_ID` unset, `svc_write_env` still writes a bare
  `fast.env` (not tenant-qualified), and `_svc_unit_for fast` still
  resolves to the plain `llmctl-llama@fast.service` — an explicit
  regression guard proving the new feature does not change any existing,
  non-tenant-aware behavior.
* **Tenant-scoped path produces a distinct unit *instance* per tenant**:
  with `LLMCTL_TENANT_ID=tenant-a`, `svc_write_env fast ... --port 8081`
  writes `tenant-a--fast.env` (not a bare `fast.env`) containing its own
  `--port 8081` args; with `LLMCTL_TENANT_ID=tenant-b`,
  `svc_write_env fast ... --port 8082` writes a *separate*
  `tenant-b--fast.env` with its own `--port 8082` — and, critically,
  asserts tenant-a's env file is asserted to *still* contain `--port
  8081` **after** tenant-b registers the same profile name — the exact
  cross-tenant-collision failure mode this feature exists to prevent
  (explicitly said to mirror T073's HTTP-layer isolation test at the
  bash-unit layer).
* **Unit-name resolution is tenant-qualified**: `_svc_unit_for fast`
  under `tenant-a` resolves to
  `llmctl-llama@tenant-a--fast.service`; under `tenant-b` resolves to
  the distinct `llmctl-llama@tenant-b--fast.service`.
* **Dry-run enable output shows the tenant-qualified unit**: `svc_enable
  fast` under `tenant-a` produces dry-run `enable`/`start` lines
  targeting `llmctl-llama@tenant-a--fast.service`, not the bare unit
  name.
* **The real isolation mechanism — a per-instance systemd drop-in**:
  asserts a real drop-in file
  `${LLMCTL_UNIT_DIR}/llmctl-llama@tenant-a--fast.service.d/tenant-slice.conf`
  was written after `svc_enable`, and that it sets
  `Slice=llmctl-tenant-tenant-a.slice` — the actual cgroup placement
  directive. Separately (and without ever calling `svc_enable` for
  tenant-b), asserts that `svc_start` **alone** — the more common runtime
  path — also ensures tenant-b's own distinct drop-in
  (`.../tenant-b--fast.service.d/tenant-slice.conf`, naming
  `Slice=llmctl-tenant-tenant-b.slice`) exists, proving the drop-in
  mechanism is not gated only on the first-time-install path.
* **Fail-closed on a malicious/malformed tenant ID**: asserts (via
  `assert_rc 1 ...`) that each of three attack-shaped tenant IDs is
  rejected (process exits `1`, never silently sanitized-and-passed-through):
  an embedded shell metacharacter (`"tenant-a; rm -rf /"`), a leading
  path-traversal sequence (`"../../etc"`), and — distinctly — an
  embedded (non-leading) `".."` sequence mid-string
  (`"tenant..other"`), which the comment notes is the same
  defense-in-depth the Go-side `validateTenantID` applies beyond a bare
  charset check.
* **Bash and Go tenant-ID allow-lists genuinely match (a real
  cross-language regression found by independent code review,
  2026-09-15)**: asserts that `"tenant.3"` — a tenant ID containing a
  literal `.`, which Go's `tenantIDPattern` in
  `internal/isolation/cgroup.go` permits but which bash's own allow-list
  previously rejected — is *now* accepted by bash's validation too,
  resolving to `llmctl-llama@tenant.3--fast.service`. The comment
  explains the real-world impact this closes: without this fix, the same
  tenant ID could succeed against a Go-validated HTTP route
  (`/v1/replication/*`) while failing with an opaque error against a
  bash-validated one (`/v1/tenants/:id/models/:model/start`), since
  nothing upstream (`Registry.Create`) performs its own format
  validation.

## Internal behaviour

1. `set -euo pipefail`; source `tests/helpers.sh`; `test_setup_env`;
   export `LLMCTL_DRY_RUN=1` and the baseline `LLMCTL_FAKE_HW` fixture.
2. In a subshell (no `LLMCTL_TENANT_ID`): source `common.sh`,
   `service_linux.sh`; call `svc_write_env` for `fast`; assert the bare
   `fast.env` exists; in a second subshell call `_svc_unit_for fast` and
   assert it is the untenanted unit name.
3. In a subshell with `LLMCTL_TENANT_ID=tenant-a`: call `svc_write_env`
   for `fast` with port 8081; assert `tenant-a--fast.env` exists and
   contains `--port 8081`.
4. In a subshell with `LLMCTL_TENANT_ID=tenant-b`: call `svc_write_env`
   for `fast` with port 8082; assert `tenant-b--fast.env` exists and
   contains `--port 8082`; assert `tenant-a--fast.env` *still* contains
   `--port 8081` (cross-tenant non-collision check).
5. In two further subshells (one per tenant), call `_svc_unit_for fast`
   and assert each resolves to its own tenant-qualified unit name.
6. In a subshell with `LLMCTL_TENANT_ID=tenant-a` (stdout captured): call
   `svc_enable fast`; assert the captured dry-run lines target the
   tenant-qualified unit.
7. Assert the tenant-a drop-in file exists and contains the correct
   `Slice=` line.
8. In a subshell with `LLMCTL_TENANT_ID=tenant-b` (stdout redirected to
   `/dev/null`): call `svc_start fast` directly (not `svc_enable`);
   assert tenant-b's own drop-in file exists and contains its own
   distinct `Slice=` line.
9. Three `assert_rc 1 ...` calls, each wrapping a `bash -c '...'`
   subprocess that exports a malicious/malformed `LLMCTL_TENANT_ID`,
   sources `common.sh`+`service_linux.sh`, and calls `_svc_unit_for
   fast` — asserting each dies with exit `1`.
10. In a subshell with `LLMCTL_TENANT_ID=tenant.3` (stdout captured):
    call `_svc_unit_for fast`; assert the result is
    `llmctl-llama@tenant.3--fast.service` (proving the `.`-permitting
    allow-list now matches Go's).
11. `test_finish` tears down the temp environment and exits non-zero iff
    any assertion failed.

## Related scripts

* Sources `tests/helpers.sh` (sibling, documented separately, including
  its `assert_rc` helper used for the malicious-tenant-ID cases).
* Exercises `lib/service_linux.sh`'s tenant-aware functions
  (`svc_write_env`, `_svc_unit_for`, `svc_enable`, `svc_start`, and the
  internal `_svc_validate_tenant_id` / `_svc_ensure_tenant_slice_dropin`
  helpers it calls), on top of `lib/common.sh`, `lib/os_detect.sh`,
  `lib/hardware.sh`.
* Reads `tests/fixtures/hw-baseline.json`.
* Cross-references the Go-side tenant-ID validation in
  `internal/isolation/cgroup.go` (`validateTenantID`,
  `tenantIDPattern`) — this test exists specifically to keep the two
  languages' allow-lists in sync.
* Sibling tests `tests/test_services.sh` and
  `tests/test_services_crashloop.sh` cover the non-tenant-aware baseline
  behavior of the same `lib/service_linux.sh` backend.
* Discovered and run automatically by `tests/run_tests.sh`; syntax and
  shebang/strict-mode covered by `tests/test_syntax.sh`.

## Last verified date

2026-09-17
