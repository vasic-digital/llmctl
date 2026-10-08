# `check_doc_reachability.sh`

## Overview

Source: `scripts/check_doc_reachability.sh` (script). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
check_doc_reachability.sh - Constitution 11.4.212: README.md is the entry point of ALL documentation; every markdown
document under docs/ must be reachable from it, directly or transitively, through markdown links.

Usage:  scripts/check_doc_reachability.sh [--root DIR] [--check-links] [--list]
  --root DIR      repository root (default: the directory above this script); must hold README.md
  --check-links   also fail on a link inside a reachable document whose target does not exist
  --list          print every reachable in-scope document before the summary
Scope:  docs/**/*.md (the documentation tree). README.md itself is the start node and is not an orphan.
What counts as a link: an inline markdown link  [text](target)  or  [text](target "title")  in a *.md file.
  target forms followed: relative paths, ../ paths, #anchors (stripped), a directory (its README.md).
  not followed: http(s)/mailto/other-scheme targets, non-.md targets (scripts, json, ...), reference-style links,
  bare backticked paths. A link written inside a code fence is counted like any other (documented limit).
Output: "ORPHAN: <path>" per unreachable document, then "reachable=<N> orphans=<N> broken=<N>"; with --check-links a
  "BROKEN: <file> -> <target>" line per dead link.
Exit: 0 no orphan (and, with --check-links, no broken link); 1 an orphan or broken link; 2 usage / no README.md.
Portability: bash 3.2 compatible (no associative arrays, no mapfile); needs only grep, sed, sort, find.
```

Usage and options: see the header above and run the script with `--help` where it supports it.
