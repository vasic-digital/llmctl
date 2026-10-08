## Overview

`tests/test_mcp_stdio.sh` drives the real `llmctl-decide mcp` binary over **stdio** (newline-delimited
JSON-RPC 2.0) against a **real** TLS gateway (`internal/client/internal/clienttest`), and checks the
`schema` emitters. It covers initialize / tools/list / tools/call, the tool list equalling `schema --format
mcp`, `min_confidence` withholding, and **fail-closed** behaviour (gateway down -> exit code 6, wrong key ->
exit code 4, not-ready 503, readout 422, no key at all) - every one an `isError` tool result with no
structured answer - plus malformed input (bad JSON, a batch, an unknown method) never killing the server.

**35 passing** assertions.

## Prerequisites

`go`, `python3` (the test prints SKIP and exits 0 without them).

## Usage examples

```sh
bash tests/test_mcp_stdio.sh
go test -race -cover ./internal/mcpserver ./internal/schema ./cmd/llmctl-decide
```

## Edge cases

* The wrong-key case sets `LLMCTL_API_KEY` to a well-formed but wrong value.
* The key never appears on stdout/stderr (asserted with the real key of the test gateway).

## Internal behaviour

The Python driver (`drive.py`, written to the temp dir) spawns the binary, writes all lines, closes stdin and
reads the output, so the server's EOF handling is part of the test. Go-level tests (protocol table, fuzz seed
corpus, golden files) are in `internal/mcpserver/server_test.go` and `internal/schema/schema_test.go`.
