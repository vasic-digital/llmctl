# `test_apikey_lifecycle.sh`

## Overview

Source: `tests/test_apikey_lifecycle.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_apikey_lifecycle.sh - 006-cli-daemon-wiring T009/US2: `llmctl
apikey create <scope>` and `llmctl apikey rotate <key-id>` against a
REAL running llmctld (never a mock).

See tests/test_cluster_join_leave.sh's header comment for the full
environment-architecture finding this test shares: this host's curl
has no HTTP/3 support, and llmctld's cluster API is HTTP/3-QUIC-only
(UDP), so no curl-based request in this environment can complete a
2xx round trip against a real llmctld - proven again below against a
genuinely running, healthy daemon (not merely asserted from the
join/leave test in isolation).

What this test DOES prove for real: `apikey create`/`apikey rotate`
hard-fail with the SAME "llmctld unreachable" message whether no
daemon is running or a real one is running-but-curl-unreachable
(FR-008/FR-009/SC-002). What it does NOT (and cannot, on this host)
prove: the success path (US2 Acceptance Scenarios 1/2 - a real usable
key issued, then genuinely rotated) - explicitly SKIPPED, never
silently omitted.

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

Run: `bash tests/test_apikey_lifecycle.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh apikey_lifecycle` (see [doc_counts](doc_counts.md)).
