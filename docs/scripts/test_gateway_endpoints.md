# `test_gateway_endpoints.sh`

## Overview

Source: `tests/test_gateway_endpoints.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_gateway_endpoints.sh - T042: builds the REAL llmctl-decide binary and a tiny fake-engine helper
(both into a temp dir; nothing lands in the repo tree), starts `serve` in an isolated HOME against the
fake llama-server / encoder runtime and drives every reachable row of
specs/009-jev-decision-models/contracts/endpoint-inventory.tsv over real HTTPS (curl --cacert), then
checks `serve --status` / `--stop` safety (Helix 11.4.263: only a verified process is ever signalled).
The engines are fakes by design (they stand in for a model); gateway, TLS, auth, limits, key and
certificate handling are the real implementations.
```

Run: `bash tests/test_gateway_endpoints.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh gateway_endpoints` (see [doc_counts](doc_counts.md)).
