# `test_cluster_join_leave.sh`

## Overview

Source: `tests/test_cluster_join_leave.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_cluster_join_leave.sh - 006-cli-daemon-wiring T006/US1: `llmctl
cluster join <peer-addr>` and `llmctl cluster leave` against a REAL
running llmctld (never a mock), covering both the daemon-unreachable
hard-fail path (spec.md Acceptance Scenario 3) and, honestly
documented where NOT achievable in this environment, the success path
(Acceptance Scenarios 1/2).

IMPORTANT - environment-architecture finding (captured this session,
see docs/qa/006-cli-daemon-wiring/):
  `curl --version` on this host has NO "HTTP3" in its Features line
  (curl 8.18.0, no ngtcp2/quiche build). llmctld's cluster API server
  (llmctld/internal/api/server.go's NewServer) serves EXCLUSIVELY over
  HTTP/3 via a UDP-only QUIC listener - confirmed empirically: a real
  bootstrapped llmctld shows ONLY a UDP socket in `ss -tulpn` for its
  -api-bind address, and a plain-TCP curl request to that exact
  address fails with "Connection refused", byte-for-byte identical to
  the message when no daemon is running at all. `lib/cluster.sh`'s own
  `_cluster_http3_supported()` correctly detects this host cannot use
  --http3 and falls back to a plain TCP-based request - which can
  never reach a UDP-only listener, on ANY host without a real HTTP/3-
  capable curl build. This is a pre-existing daemon/environment
  transport-protocol fact this feature's own Assumptions section did
  not anticipate (it assumed only request/response SHAPES might need
  bash-side handling); it is not a defect in this feature's CLI
  wiring, which this test proves is correctly reached and correctly
  constructs its request in every case it CAN observe.

What this test DOES prove for real, against a REAL running daemon:
  - `cluster join`/`cluster leave` hard-fail with the SAME
    "llmctld unreachable" message whether NO daemon is running, or a
    genuinely running, healthy daemon is unreachable via curl for the
    reason above - never a silent fallback to any other behavior
    (FR-008/FR-009/SC-002), and never a DIFFERENT failure mode
    (a hang, a stack trace, a different message) depending on which
    of those two states is real.
What this test does NOT (and, on this host, cannot) prove: the
success path (join genuinely reflected in the peer's own node list) -
explicitly SKIPPED below with assert_skip, never silently omitted.

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

Run: `bash tests/test_cluster_join_leave.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh cluster_join_leave` (see [doc_counts](doc_counts.md)).
