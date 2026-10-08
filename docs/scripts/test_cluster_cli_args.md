# `test_cluster_cli_args.sh`

## Overview

Source: `tests/test_cluster_cli_args.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_cluster_cli_args.sh - G-106 (OD-21 / T131): lib/cluster.sh builds the
right curl command for the mutual-TLS llmctld daemon.

A fake `curl` on PATH records its argv (one argument per line), the content
of any `-H @file` header file at call time, and answers like a daemon would.
That proves the ARGUMENT CONSTRUCTION - trust anchor, client cert/key,
transport selection, secret hygiene, and the absence of every
verification-disabling switch. It does NOT exercise a real HTTP/3
transport (this host's curl has none): the end-to-end TLS handshake with
the same inputs is proven by the Go tests in llmctld/cmd/llmctld
(TestCLIRoundTrip_*), and tests/test_cluster_join_leave.sh,
test_apikey_lifecycle.sh and test_tenant_list_quota.sh run the real CLI
against a real daemon whenever the host curl has the HTTP3 feature.
```

Run: `bash tests/test_cluster_cli_args.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh cluster_cli_args` (see [doc_counts](doc_counts.md)).
