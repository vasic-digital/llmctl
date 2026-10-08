# Retired: the Python decision gateway (candidate from the second team)

Archived verbatim before deletion (Helix 11.4.122/11.4.124: a retired component keeps its history). The
files are **not** built, shipped or executed; the sha256 manifest is `SHA256SUMS`.

| File | Was | Superseded by |
|---|---|---|
| `decide_gateway.py` | stdlib HTTP gateway, `POST /v1/systemone`, single prompt-template owner, `--backend-engine llama/onnx` | `internal/gateway` + `internal/server` + `cmd/llmctl-decide` (Go, HTTPS) |
| `test_decide_gateway.sh` | 36 assertions on that gateway | `tests/test_gateway_endpoints.sh`, the Go tests; assertion-by-assertion map: `../python-gateway-parity.json` |
| `decide_server.py`, `onnx_decide_server.py` | stub llama-server / stub onnx backend for those tests | `internal/gateway/internal/fakebackends` (Go fake engine) |
| `decide_gateway.md`, `test_decide_gateway.md` | the two doc pages | `docs/decide-gateway.md` (the Go gateway guide) |

## Git-history note (verified 2026-10-07)

* `git log --all -- lib/decide_gateway.py tests/test_decide_gateway.sh tests/fixtures/decide_server.py tests/fixtures/onnx_decide_server.py` -> **no commits**: the files were never committed.
* `git tag --contains` for the tree they lived in -> **no tag** (latest release tag `v3.0.2` carries none of them; `git ls-tree -r v3.0.2 | grep -c decide_gateway` -> 0).
* They were an uncommitted candidate (the second team's), part of the working tree only. Nothing shipped
  to a user was removed; no behaviour was retired without parity evidence (`../python-gateway-parity.json`
  maps every assertion group to its Go/endpoint test or to an explicit "intentionally dropped/changed" reason).
* Behaviour changes versus the candidate are intentional and listed there: the response `model` is the served
  profile id, an over-budget state is rejected by default (opt-in shortening), a missing pidfile on `--stop`
  is a clean no-op, the transport is HTTPS with a mandatory access key, there is no `--backend-engine` flag
  (the engine follows the catalog profile).
