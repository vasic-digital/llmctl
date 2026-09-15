# Contracts Directory

**Feature**: 001-llmctl-completion

---

## Contract Files

| File | Description |
|------|-------------|
| `cli-command.md` | CLI command contract (all llmctl subcommands, JSON schemas, exit codes) |
| `model-catalog.md` | Model catalog schema (models/catalog.json) |
| `service-unit.md` | Service unit lifecycle, systemd/launchd templates, state files |
| `api-compatibility.md` | API compatibility (OpenAI + Anthropic endpoints) |

---

## Contract Coverage

| Contract | Spec Requirements Covered |
|----------|---------------------------|
| cli-command.md | FR-001, FR-009, FR-013 |
| model-catalog.md | FR-001 (catalog.json), FR-014 |
| service-unit.md | FR-001, FR-009, FR-015, FR-017 |
| api-compatibility.md | FR-010, FR-012 |

---

## Usage

These contracts define the exact interfaces that must be implemented and tested. They serve as:

1. **Implementation reference** - Exact schemas, exit codes, endpoints
2. **Test contracts** - Validation scenarios in quickstart.md reference these
3. **Integration contracts** - CLI agents integrate via these exact APIs
4. **Compliance verification** - Constitution §6 requires nano-detail documentation

---

*End of Contracts Index*
