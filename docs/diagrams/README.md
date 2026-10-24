# llmctl diagrams

Sources are `*.mmd` ([Mermaid](https://mermaid.js.org)); the rendered `*.svg` files are committed so they display without a renderer.
Each diagram is also embedded as a Mermaid block at the point of use (Constitution 11.4.258); `tests/test_docs_diagrams_governance.sh`
checks that the embedded block is byte-identical to its `.mmd` source.

| Diagram | Source | Rendered | Embedded in |
|---|---|---|---|
| Validation gate state machine (exit codes 0, 1, 2, 75, 77, 98) | [validation-gate.mmd](validation-gate.mmd) | [validation-gate.svg](validation-gate.svg) | [validation](../validation.md) |
| Decide gateway request flow (HTTPS + bearer key) | [decide-gateway-flow.mmd](decide-gateway-flow.mmd) | [decide-gateway-flow.svg](decide-gateway-flow.svg) | [decide gateway](../decide-gateway.md) |
| Hub-engine placement and dependency resolution | [hub-engine-placement.mmd](hub-engine-placement.mmd) | [hub-engine-placement.svg](hub-engine-placement.svg) | [dependency layout](../dependency-layout.md) |
| Vision tiers and model identity | [vision-tiers.mmd](vision-tiers.mmd) | [vision-tiers.svg](vision-tiers.svg) | [validation](../validation.md) |

Regenerate after editing a source (same renderer and flags as `claude_toolkit/docs/diagrams`; `mmdc` needs a Chromium and, in a
container or as root, `--no-sandbox`):

```bash
echo '{"args":["--no-sandbox"]}' > "${TMPDIR:-/tmp}/pptr.json"
for d in validation-gate decide-gateway-flow hub-engine-placement vision-tiers; do
  mmdc -i docs/diagrams/$d.mmd -o docs/diagrams/$d.svg -p "${TMPDIR:-/tmp}/pptr.json"
done
```

Where `mmdc` is absent the `.svg` cannot be produced; the index then records `<name> not rendered (SKIP: no mmdc)` instead of
shipping a placeholder. All four were rendered on 2026-10-22 with `mmdc` from node v26.8.1.
