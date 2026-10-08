# Discovery contract — what surrounding tooling may rely on

**Status**: draft contract (User Story 9, FR-036). Source of the expectations: `jev/claude_toolkit` v1.30.5 (`scripts/claude-providers.sh sync-jev`, `scripts/providers/jev.json`, `jev-gate.sh`) and constitution v70 anchors §11.4.277–284, read as **external consumers**. Neither is ported into this repository; where they conflict with the operator's decisions, the conflict is recorded here as a contract change for their maintainers.

## 1. What llmctl guarantees

| Surface | Guarantee | Check |
|---|---|---|
| `llmctl plan --json` | Contains top-level `decision_instances` in the **candidate's shape** (object keyed by profile: `instances_gpu`, `instances_cpu`, `per_instance{ram_mb,vram_mb,slots}`, `total_decision_slots`, optional `reason`; additive field `protocol`); see data-model §10 for the exact (single-profile, best-placement) definition. Existing keys unchanged. Read-only. | JSON-schema check + live equality with admission (SC-010) |
| Gateway address | `https://<host>:8095` (override `LLMCTL_DECIDE_PORT`); HTTPS only; key required except `/healthz`, `/readyz`. | endpoint inventory (EP-040…EP-046) |
| Model list | `GET /v1/models` (authenticated) lists served profiles with aliases, protocol and status. | EP-030 |
| Never a chat model | No decision profile appears in any generated chat configuration; `capability` excludes chat; `auto chat|coder|vision` never selects one; the gateway has no chat route. | catalog test + route inventory |
| Classification | `/v1/models` entries carry `protocol`; consumers classify the endpoint as `decision` and must not create provider aliases for it (toolkit record: `classification:"decision"`, `alias:null`). | contract doc + consumer run (below) |
| Trust material | `llmctl cert export DEST` yields the public CA (0644) and fingerprint; key via `LLMCTL_API_KEY` (env or `.env`). | cert/key tests |
| Install/update | llmctl is installable and updatable by its own installer (`scripts/install.sh`; `llmctl install` installs the user services, not the tool); a wrapper must invoke that installer rather than reimplement it (§11.4.284). | install e2e test |

## 2. Known incompatibilities with the toolkit snapshot (recorded, not worked around)

| Snapshot assumption | Under this feature | Required change (outside this repo) |
|---|---|---|
| Local gateway reached at `http://127.0.0.1:8095` (plain HTTP) | HTTPS only, certificate verification | Use `https://…`, supply the CA (`SSL_CERT_FILE`/`NODE_EXTRA_CA_CERTS` or its client's CA option) |
| Keyless or any non-empty bearer on loopback | Key required for every request | Read `LLMCTL_API_KEY` (or the toolkit's own key store) and send `Authorization: Bearer` |
| Hosted-style 2xx/4xx only | Retryable 529/503 with `Retry-After` | Honour `Retry-After` |
| `jev-gate.sh` calls the gateway over HTTP from a hook | Hooks must be **command** hooks calling `llmctl decide ask`/`curl --cacert` (HTTP hooks fail open on non-2xx and their TLS trust of a private CA is unverified) | Use the templates shipped in the integration kit (FR-086) |

## 3. How the contract is verified (US9)

1. Run the snapshot's discovery command **unmodified** against the gateway with trust and key supplied through its environment; expected: endpoint recognised, models recorded, no alias created. If the tool cannot be configured for HTTPS/key, the result is recorded as `fail` with the exact reason and the contract change above is cited.
2. An automated comparison of `plan --json` and `/v1/models` output against this document's field list (schema test), run in the release gate.
3. The documented change list for the toolkit's maintainers is part of the release notes ("Compatibility notes").

## 4. Constitution v70 anchors → llmctl obligations (for the record)

| Anchor | llmctl obligation | Where |
|---|---|---|
| §11.4.277(A) detection before generation | Provide `plan --json decision_instances` and a stable gateway address | §1 |
| §11.4.280 maximal utilisation | Capacity computed from the plan; gateway spreads across instances of a profile | FR-028, 029 |
| §11.4.282(D) decision models never generate / never chat | Enforced by catalog, selectors, routes | §1 |
| §11.4.284 llmctl as installable dependency | Own installer, pinned ref, no re-implementation | §1 |
| §11.4.279/283 wizard, calibration | Out of scope; llmctl exposes calibration tooling and the request log they need (FR-080) | — |
