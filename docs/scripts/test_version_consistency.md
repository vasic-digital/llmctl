## Overview

`tests/test_version_consistency.sh` (T123, FR-053) proves that the release version is stated identically everywhere it is
stated. The `VERSION` file is the single source of truth. The suite compares it with `bin/llmctl` (`LLMCTL_VERSION`), the newest
`CHANGELOG.md` release heading and that section's required parts (Added, Changed, Fixed, Security, Removed, Migration notes,
Known limitations, plus named feature keywords), the README release banner, every `llmctl X.Y.Z` statement in `docs/*.md`, the
OpenAPI contract `info.version` (`X.Y.Z` or `X.Y.Z-draft` until the tag is cut) and the catalog's integer schema `version`
(which is not the release version).

## Prerequisites

* `tests/helpers.sh`, `python3`, `grep`, `awk`; no network, no models, no engines.

## Control needle

The version extractor is exercised first on a planted file holding a different version (`9.9.9`); it must read that value and it
must differ from `VERSION`. An extractor that cannot see a mismatch would make every later PASS meaningless.

## Usage

* Standalone: `bash tests/test_version_consistency.sh`; also run by `make test`.
* At release time bump `VERSION`, `bin/llmctl`, the CHANGELOG heading and the README banner together, and flip the OpenAPI
  `-draft` suffix with the tag.
