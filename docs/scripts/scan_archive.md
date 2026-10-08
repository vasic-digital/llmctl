## Overview

`scripts/release/scan_archive.py` is the independent post-scan of a release archive. It is a second,
separately implemented line of defence behind `scripts/release/build_archive.sh` (review-2 C-03 / C-21):
the bash build filter and this scanner share no code and no matching logic, so a defect in one (a mutated
deny-list, a case-glob that spans `/`) cannot also blind the other.

## Prerequisites

`python3` (standard library only: `tarfile`, `zipfile`, `re`). Run with `python3 -I`.

## Usage examples

```sh
python3 -I scripts/release/scan_archive.py [--allow MANIFEST]... ARCHIVE.tar.gz ARCHIVE.zip
# exit 0 clean, 1 findings (one "build_archive: ..." line each on stderr), 2 usage / unreadable archive / bad manifest
```

## Edge cases

* Judged **path by path component, case-insensitively**: `.env`, `.env.*` (not `.env.example`), `*.key`
  `*.pem` `*.p12` `*.pfx` `*.jks` `*.keystore`, `id_rsa*` `id_dsa*` `id_ecdsa*` `id_ed25519*`, `.netrc`, `.pgpass`,
  `credentials*.json`, and any `cert` directory.
* **Content**: a real PEM private-key block (BEGIN line followed by base64 lines) in a working-tree file of at
  most 2 MiB; a single line that quotes the header (scanners, tests) is not a block.
* **Shipped `.git`**: a stash ref, reflogs, non-sample hooks, a config with a `[remote]`, `[credential]`,
  `[http]`, `[url]` or `[include]` section or a URL with embedded credentials; `.gitmodules` with credentials.
* **Exemptions** are exact repo-relative paths from `--allow` manifests (`#` comments); an entry with a
  glob character, `..` or a leading `/` aborts with exit 2 - an exemption never widens into a subtree.

## Internal behaviour

Entries of each archive are enumerated with `tarfile` / `zipfile`; the first path segment (the archive's
base directory) is stripped; an entry is judged by `path_is_secret`, then by content, then (inside `.git`)
by `git_state_findings`. Findings are collected for both archives and printed together.

## Related scripts

`scripts/release/build_archive.sh` (the caller), `scripts/release/public_allowlist.txt`,
`tests/fixtures/PUBLIC_FIXTURES.txt`; tests: `tests/test_release_no_secrets.sh`.

## Last verified date

2026-10-07

## Nested archives (C2-16)

An archive inside the archive (the repository tracks `archive/llmctl.zip` and `archive/llmctl.tar.gz`, and they
ship in every release) is opened and judged by the same rules - secret paths, PEM blocks, `.git` state - to a
bounded depth and size: `SCAN_ARCHIVE_MAX_NEST_DEPTH` (default 3) and `SCAN_ARCHIVE_MAX_NEST_BYTES` (default 256
MiB). Beyond a bound the scan FAILS CLOSED (a `NESTED ARCHIVE too deep/large to scan` finding); an EXACT
allow-manifest entry for the nested archive's path is the explicit opt-out. Recognised extensions: `.zip`, `.jar`,
`.whl`, `.tar`, `.tar.gz`, `.tgz`, `.tar.bz2`, `.tbz2`, `.tar.xz`, `.txz`. Checked against the real tracked blobs on
2026-10-07: both are clean (apart from the public Keynote deck `idea-arch.key`, now allow-listed under its old
`vendor/...` path). The 46 MB tracked blobs themselves were NOT removed: dropping a tracked file is an operator
decision (stale since f4b5754, 2026-09-14).
