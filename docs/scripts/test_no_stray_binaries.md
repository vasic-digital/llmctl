# `test_no_stray_binaries.sh`

## Overview

Source: `tests/test_no_stray_binaries.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_no_stray_binaries.sh - no native executable may sit in the work tree where it does not belong.
Why: an ad-hoc `go build ./cmd/...` (without -o) drops a 9-24 MB binary into the current directory;
it would be committed by `git add -A` and shipped (gap G-105). This guard fails the suite instead.

Scope (C3-12, stated, not implied):
  * UNTRACKED + NOT ignored files of the main repo AND of every initialised submodule (`git ls-files --others
    --exclude-standard` does not recurse into submodules, so each one is listed on its own);
  * TRACKED native executables larger than 1 MiB that are not named in tests/fixtures/TRACKED_BINARIES_ALLOWLIST.txt
    (one exact repo-relative path per line, '#' comments) - a small tracked fixture binary is legitimate, a 20 MB one
    is a release-size accident.
Formats (magic bytes): ELF; Mach-O thin (both endians, 32/64) and FAT/universal (0xcafebabe followed by a small
architecture count - a Java class file shares the magic but carries a major version >= 45 there, so it is not flagged);
Windows PE (MZ with a "PE\0\0" header at the offset stored at 0x3c); WebAssembly (\0asm).
Instrument proof (C3-12): the control needles go through the SAME enumeration function as the real check, on a scratch
git repository (and a scratch submodule), not through a bare predicate on a file in mktemp.
```

Run: `bash tests/test_no_stray_binaries.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh no_stray_binaries` (see [doc_counts](doc_counts.md)).
