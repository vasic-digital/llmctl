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

Two more needles prove the failure path: a planted CHANGELOG whose first heading is `## Unreleased` must read as that heading
with an empty version, and one without any `## ` heading must read as empty. Both are read as assignments under
`set -e -o pipefail`, exactly like the real checks. Every extractor ends in `|| true`: "nothing found" must become an empty
string that the assertion reports (`CHANGELOG: newest release heading is X (got: ## Unreleased)`), never a silent abort. Before
this guard a CHANGELOG starting with `## Unreleased` killed the run after four assertions with exit 1 and no message, and the
README, docs and OpenAPI checks never ran; removing the guard from either extractor makes the run die again on the matching
needle line.

## Failure reading

A disagreeing tree is reported one assertion at a time, so the failing lines name the files that disagree with `VERSION`. The
CHANGELOG check reads the first `## ` heading, so a CHANGELOG that carries an `## Unreleased` section above the newest release
heading fails that one assertion until a release heading is on top (whether an `## Unreleased` section should be tolerated
between releases is a policy question for the maintainers; this test does not decide it).

## Usage

* Standalone: `bash tests/test_version_consistency.sh`; also run by `make test`.
* At release time bump `VERSION`, `bin/llmctl`, the CHANGELOG heading and the README banner together, and flip the OpenAPI
  `-draft` suffix with the tag.
