# `test_small_profile_full_context.sh`

## Overview

Source: `tests/test_small_profile_full_context.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_small_profile_full_context.sh - the 'small' profile MUST be
configured for parallel=1 so its full ctx-size is usable by a single
session, rather than being silently halved by llama.cpp's per-slot
context division under a higher --parallel value.

Real, live-confirmed defect this session: 'small' shipped with
ctx=8192 parallel=2, and llama.cpp divides the configured ctx-size
across parallel slots - the live server's own /v1/models response
reported meta.n_ctx=4096 (half of the configured 8192), which is too
small to hold a real Claude Code session (system prompt + tool
schemas routinely exceed 4096 tokens on their own), causing a real
"Prompt is too long" failure when exercised end-to-end through
claude_toolkit's llmctl-small provider alias. This test locks in the
operator-approved fix (parallel=1) as a permanent regression guard so
a future catalog edit cannot silently reintroduce the halved-context
defect for this profile.
```

Run: `bash tests/test_small_profile_full_context.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh small_profile_full_context` (see [doc_counts](doc_counts.md)).
