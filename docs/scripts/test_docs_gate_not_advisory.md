# `test_docs_gate_not_advisory.sh`

## Overview

Source: `tests/test_docs_gate_not_advisory.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_docs_gate_not_advisory.sh - the validation gate is ENFORCED (docs/validation.md, "Enforcement of the gate"):
every path that brings a profile up runs the hook, FAIL stops the profile, UNDETERMINED never stops/passes (strict: stops).
Shipped prose must not still call it advisory, say a wrong answer keeps serving, or say systemd-started units skip the hook.
The scanner is proven first: each stale shape planted in a temp file MUST be flagged, an allowed sentence MUST NOT be.
Scope: README.md, CHANGELOG.md, docs/*.md (not docs/qa evidence, not specs), bin/llmctl help text.
```

Run: `bash tests/test_docs_gate_not_advisory.sh`. **8 passing** assertions (measured with `scripts/doc_counts.sh docs_gate_not_advisory`). The count is regenerated, not typed: `scripts/doc_counts.sh docs_gate_not_advisory` (see [doc_counts](doc_counts.md)).
