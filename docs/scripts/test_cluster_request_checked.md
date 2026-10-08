# `test_cluster_request_checked.sh`

## Overview

Source: `tests/test_cluster_request_checked.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_cluster_request_checked.sh - 006-cli-daemon-wiring T019/T020: proves
cluster::request_checked genuinely distinguishes all three outcomes
spec.md's Edge Cases require ("auth-vs-unreachable-vs-app-error
distinction"): reachable+2xx, reachable+non-2xx, and unreachable - AND
proves the pre-existing cluster::request function's own output/exit-code
contract is completely unmodified (research.md R3's additive-only design
decision; the one existing caller, `cluster status`, must see zero
behavior change).

Real HTTP round trip against a REAL, running local HTTP server (python3's
stdlib http.server, the SAME "no mocks, real local fixture" pattern
test_download.sh already uses for a real download source) - never a
mocked transport. It deliberately does NOT talk to a real llmctld: this
host's curl build has no HTTP/3 support (`curl --version` lacks
"HTTP3" in its Features line) and llmctld's cluster API server
(llmctld/internal/api/server.go's NewServer) serves EXCLUSIVELY over
HTTP/3 via a UDP-only QUIC listener (confirmed empirically this
session: a real bootstrapped llmctld shows only a UDP socket in
`ss -tulpn`, and a plain-TCP curl request to it fails with
"Connection refused", identical to no daemon running at all) - so no
curl-based bash test can ever reach a real llmctld's success path in
this environment. That is a pre-existing daemon/environment
architecture fact this feature's Assumptions section did not
anticipate (it assumed only request/response SHAPES might need bash-
side handling, not the transport protocol itself), tracked separately
(see docs/qa/006-cli-daemon-wiring/ for the full writeup) - it is NOT
a defect in cluster::request_checked's OWN logic, which this test
proves correct against a real HTTP server that curl on this host CAN
actually speak to.
```

Run: `bash tests/test_cluster_request_checked.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh cluster_request_checked` (see [doc_counts](doc_counts.md)).
