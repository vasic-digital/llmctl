# `test_keyring_go_cli.sh`

## Overview

Source: `tests/test_keyring_go_cli.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_keyring_go_cli.sh - builds the REAL Go binary (go build -o into a temp
dir, never into the repo) and drives `llmctl-decide key doctor|show|path|
rotate|export` in temp dirs. Port of test_keyring_cli.sh. Asserts exit codes,
file modes, stdout hygiene (doctor/rotate never print the key), idempotent
export, and the FR-087 placement guard inside temp git repos.
FR-057..FR-063, FR-087; contracts/cli.md `key`.
```

Run: `bash tests/test_keyring_go_cli.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh keyring_go_cli` (see [doc_counts](doc_counts.md)).
