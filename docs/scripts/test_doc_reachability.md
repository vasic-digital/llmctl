# `test_doc_reachability.sh`

## Overview

Source: `tests/test_doc_reachability.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_doc_reachability.sh - Constitution 11.4.212: the main README is the entry point of ALL documentation; no doc under
docs/ may be an orphan (unreachable, directly or transitively, through markdown links starting at README.md).
scripts/check_doc_reachability.sh is the checker. It is proven here BEFORE it is trusted on the real tree:
  * control needle: a planted orphan MUST be reported (a checker that cannot see an orphan says nothing about the tree);
  * negative control: the same tree with the orphan linked MUST pass (no false positive);
  * link forms: relative, ../ , anchors, directory links, titles, transitive chains;
  * the real repository: zero orphans.
```

Run: `bash tests/test_doc_reachability.sh`. **18 passing** assertions (measured with `scripts/doc_counts.sh doc_reachability`). The count is regenerated, not typed: `scripts/doc_counts.sh doc_reachability` (see [doc_counts](doc_counts.md)).
