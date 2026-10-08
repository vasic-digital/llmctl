#!/usr/bin/env python3
"""(Re)write tests/fixtures/golden/MANIFEST.json from the JSONL files (stdlib only, deterministic).

Run after ANY edit of questions.jsonl or probes.jsonl, then run verify_manifest.py.
Usage: build_manifest.py [DIR]
"""
import json
import os
import sys

try:
    from scripts.golden import verify_manifest as vm
except ImportError:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import verify_manifest as vm


def build(d):
    files, counts = {}, {}
    for name in vm.DATA_FILES:
        p = os.path.join(d, name)
        items = vm.read_items(p)
        files[name] = {"sha256": vm.sha256_file(p), "bytes": os.path.getsize(p), "items": len(items)}
        counts[name] = vm.compute_counts(items)
    man = {"schema": 1, "name": "llmctl-golden-set",
           "spec": "specs/009-jev-decision-models (SC-003, FR-080)",
           "seed": 20261007, "language": "en",
           "labeled_by": "agent-authored; human-review-pending",
           "licence": "CC0-1.0 / project licence",
           "note": "Not human-labelled yet. Not a safety benchmark. No calibration claim below 200 labels.",
           "files": files, "counts": counts}
    with open(os.path.join(d, vm.MANIFEST), "w") as f:
        json.dump(man, f, indent=2, sort_keys=True)
        f.write("\n")
    return man


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    d = argv[0] if argv else vm.DEFAULT_DIR
    man = build(d)
    print("wrote %s/%s: %s" % (d, vm.MANIFEST, {n: v["items"] for n, v in man["files"].items()}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
