# `test_tenant_list_quota.sh`

## Overview

Source: `tests/test_tenant_list_quota.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_tenant_list_quota.sh - 006-cli-daemon-wiring T016/US3: `llmctl
tenant create/list/quota` against a REAL running llmctld (never a
mock) - including the two genuinely-new server routes this feature
adds (GET /v1/tenants, GET+PUT /v1/tenants/:id/quota, already proven
at the Go/HTTP level by TestListTenants/TestTenantQuota_ViewAndSet in
llmctld/internal/api/routes_tenants_test.go).

See tests/test_cluster_join_leave.sh's header comment for the full
environment-architecture finding this test shares: this host's curl
has no HTTP/3 support, and llmctld's cluster API is HTTP/3-QUIC-only
(UDP), so no curl-based request in this environment can complete a
2xx round trip against a real llmctld.

What this test DOES prove for real: `tenant create/list/quota`
hard-fail with the SAME "llmctld unreachable" message whether no
daemon is running or a real one is running-but-curl-unreachable
(FR-008/FR-009/SC-002), for all three subcommands including the two
BRAND NEW routes (list/quota) this feature adds server-side - proving
the new bash wiring reaches cluster::require_daemon identically to
the pre-existing create path, never a different (e.g. hung, crashed,
malformed-request) failure mode just because the route is new. What
it does NOT (and cannot, on this host) prove: the success path (US3
Acceptance Scenarios 1/2/3 - create-then-list, and quota view/set
round-tripping through the real enforcer state) - explicitly SKIPPED,
never silently omitted.

G-106 UPDATE (OD-21 / T131): the certificate side of the HTTP/3 round trip
is fixed. The daemon's certificates carry SANs (127.0.0.1, ::1, localhost,
hostname, -api-bind host, -advertise names), `llmctld cluster bootstrap|join`
writes ca.crt + client.crt + client.key (0700 dir, 0600 files, CLI_CERT_DIR=
on stdout) and lib/cluster.sh passes --cacert/--cert/--key (never -k). The
suite exports LLMCTL_CLUSTER_CERT_DIR=$LLMCTLD_CLI_CERT_DIR on a curl that
has the HTTP3 feature and runs the success path; on a curl without HTTP3
(this host) it still SKIPs, with the measured Features line. The remaining
limit is the host's curl, not the daemon or the CLI.
```

Run: `bash tests/test_tenant_list_quota.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh tenant_list_quota` (see [doc_counts](doc_counts.md)).
