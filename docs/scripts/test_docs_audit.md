## Overview

`tests/test_docs_audit.sh` (T121, SC-009) proves the documentation audit `tests/py/docs_audit.py`, which checks `README.md` and `docs/` for missing links, wrong ports, stale counts, code/doc mismatches and literal keys, and then runs it on the real repository. Measured with `scripts/doc_counts.sh --check docs_audit`: **31 passing assertions** (no failures, no skips).

## Prerequisites

* `python3`; `tests/helpers.sh`; the audit script must exist. Fixture trees (README, docs, catalog, lib) are generated in a temp dir.

## Usage

* Standalone: `bash tests/test_docs_audit.sh`; also run by `make test`.
* Check the documented count: `bash scripts/doc_counts.sh --check docs_audit`.

## What it proves

* Golden-good fixture: exit 0, and each of the five rules (`links`, `ports`, `counts`, `code`, `keys`) reports it examined at least one item.
* One golden-bad fixture per defect is flagged by exactly its rule with exit 1: a missing link, a ports table that disagrees with the catalog, a prose port that disagrees, a stale decide-profile count, a stale CLI-agent count, an env var absent from code, an unknown `decide` subcommand, a literal bearer key.
* Negative controls are not flagged: placeholders, URLs, anchors, fenced code, and historical directories such as `docs/research`.
* An empty tree is BLIND (exit 2), never clean.
* Real repository: 0 mismatches and every rule examined something.

## Mutations / control needles

Each `bad ...` case is a mutation of the good fixture; the "examined" assertions are the needles proving a rule saw its inputs. The real-tree run fails if a rule examined nothing, so a silently disabled rule cannot pass.

## What it does NOT prove

* Prose accuracy beyond the five rules, or that linked pages are correct. Test-page assertion counts are checked by `scripts/doc_counts.sh`, not by this suite.

## Related

[doc_counts](doc_counts.md), [check_doc_reachability](check_doc_reachability.md), [test_doc_reachability](test_doc_reachability.md), [test_docs_no_literal_keys](test_docs_no_literal_keys.md).
