## Overview

`tests/test_release_scripts.sh` (T126, FR-084, OD-4) exercises `scripts/release.sh` against a throwaway git repository fixture: `verify-tag`, `archive`, `sbom`, `notice`, `checksums`, `all` and the `--publish` dry run. Measured with `scripts/doc_counts.sh --check release_scripts`: **36 passing assertions** (no failures, no skips).

## Prerequisites

* `git`, `jq`, `tar`, `gzip`, `sha256sum`; `tests/helpers.sh`. The fixture is a generated repo with a LICENSE, a `go.mod`/`go.sum`, a `.gitmodules` entry with a pinned gitlink and an annotated tag `v9.9.9`.
* It never pushes and never touches a network. `gh` and `glab` are PATH-injected fakes that record any call to a log; the test asserts the log stays empty.

## Usage

* Standalone: `bash tests/test_release_scripts.sh`; also run by `make test`.
* Check the documented count: `bash scripts/doc_counts.sh --check release_scripts`.

## What it proves

* `verify-tag` accepts an annotated tag at HEAD with a clean tree, and refuses a missing tag, a lightweight tag, a tag not at HEAD and a dirty tree; `--allow-dirty` is the explicit escape.
* `archive` is reproducible (two runs, byte-identical SHA-256), sorted, owner 0/0, mtime fixed to the commit date, gzip header mtime zero, and excludes untracked files.
* `sbom` is CycloneDX 1.5 JSON listing Go direct and indirect modules, the submodule's pinned commit as its version, `NOASSERTION` for an unpopulated submodule licence (not guessed) and the root licence from LICENSE; a module lacking a `go.sum` hash is marked `false`.
* `notice` lists Go modules and submodules. `checksums` lists the assets; `--verify` accepts untouched assets and detects a tampered one by name.
* `all` runs the full chain and its SHA256SUMS verifies; `--publish` without the environment guard only prints the `gh`/`glab` commands labelled DRY-RUN, the fakes are never invoked and the fixture has no remotes.

## Mutations / control needles

The golden-bad cases are the lightweight tag, moved HEAD, dirty tree, a go.sum with a missing hash, and an appended byte in a release asset (checksum tamper). The empty fake-tool log and zero remotes are the needles proving nothing could have been published.

## What it does NOT prove

* A real publish to GitHub or GitLab, signing, or the contents of a real release; the fixture is synthetic. Version consistency is covered by [test_version_consistency](test_version_consistency.md).

## Related

[create_release](create_release.md), [build_archive](build_archive.md), [test_release_no_secrets](test_release_no_secrets.md).
