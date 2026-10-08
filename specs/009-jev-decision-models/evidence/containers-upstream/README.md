# Containers upstream patch texts (not applied - FR-091)

The `submodules/containers` checkout is pinned and never edited by llmctl. Each file here is a complete
change proposal (problem, change, verification, diff) for `vasic-digital/Containers`; the llmctl workaround
that each one makes deletable is named in the file.

| File | Gap | llmctl workaround |
|---|---|---|
| `G9-network-bind-all-addresses.md` | `isPortAvailable` tests 127.0.0.1 only | `internal/registry/ports.go` `bindTest` |
| `G10-health-tls-config.md` | `CheckHTTP` cannot be given a CA pool | `internal/registry/tlsprobe.go` `TLSCheck` |

G11 (`endpoint` not importable) needed no upstream change: `go.mod` now requires `gopkg.in/yaml.v3`, and
`registry.Entry.URL()` calls `endpoint.NewEndpoint()...ResolvedURL()`.
