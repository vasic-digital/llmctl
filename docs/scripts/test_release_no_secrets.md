# `test_release_no_secrets.sh`

## Overview

Source: `tests/test_release_no_secrets.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_release_no_secrets.sh - GREEN guard for spec 009 FR-087 / D-30:
scripts/release/build_archive.sh must never put untracked/ignored secrets
(.env, cert/**, *.key, *.pem) into the release tar.gz / zip.

Layers:
 1. Reuses the RED scenario (tests/fixtures/release_secrets/scenario.py, read-only,
    not duplicated) - it carries its own control needle; must be NOT-REPRODUCED.
 2. Real git-mode fixture (main repo + one submodule): untracked .env,
    ignored cert/ca/ca.key and decide/log.key, and an untracked secret in the
    submodule must be absent from BOTH archives, while tracked files (control
    needle) and the submodule's content are present.
 3. Defense in depth: a TRACKED secret makes the build fail non-zero and
    leaves no archive behind.
 4. Mutation: the pre-fix unfiltered script (git show of the old blob,
    embedded below) run on the same fixture MUST leak -> proves this test
    can fail.
```

Run: `bash tests/test_release_no_secrets.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh release_no_secrets` (see [doc_counts](doc_counts.md)).
