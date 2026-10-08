# `test_bin_llmctl_symlink_invocation.sh`

## Overview

Source: `tests/test_bin_llmctl_symlink_invocation.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_bin_llmctl_symlink_invocation.sh - bin/llmctl must resolve its real
../lib sibling directory even when invoked through a PATH symlink (the
supported install pattern this project's other tools already use under
~/.local/bin, e.g. claude-* -> claude_toolkit/scripts/claude-*.sh) - not
just when invoked by its own direct path. `dirname "${BASH_SOURCE[0]}"`
alone resolves against the SYMLINK's own containing directory, not its
real target's directory, which broke every subsequent `source
"${LLMCTL_ROOT}/lib/*.sh"` call the moment bin/llmctl was symlinked
somewhere else on the host (confirmed real repro this session: `ln -sf
.../bin/llmctl ~/.local/bin/llmctl && llmctl status` failed with
"/home/.../.local/lib/common.sh: No such file or directory").
```

Run: `bash tests/test_bin_llmctl_symlink_invocation.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh bin_llmctl_symlink_invocation` (see [doc_counts](doc_counts.md)).
