#!/usr/bin/env python3
"""Build and verify MANIFEST.json + SHA256SUMS for an evidence run directory.

SHA256SUMS (sha256sum -c compatible) covers every file except itself, including
MANIFEST.json. verify() re-hashes and reports tampered / missing / extra.
Usage: manifest.py build DIR | manifest.py verify DIR   (exit 0 ok, 1 not ok)
"""
import hashlib
import json
import os
import sys

SUMS = "SHA256SUMS"
MANIFEST = "MANIFEST.json"


class ManifestError(Exception):
    pass


def _sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _files(d, exclude=()):
    out = []
    for dp, dn, fn in os.walk(d):
        dn.sort()
        for n in fn:
            rel = os.path.relpath(os.path.join(dp, n), d).replace(os.sep, "/")
            if rel not in exclude:
                out.append(rel)
    return sorted(out)


def build(d):
    payload = _files(d, exclude=(SUMS, MANIFEST))
    if not payload:
        raise ManifestError("no files to hash in %s" % d)
    entries = [{"path": p, "sha256": _sha(os.path.join(d, p)),
                "size": os.path.getsize(os.path.join(d, p))} for p in payload]
    with open(os.path.join(d, MANIFEST), "w") as f:
        json.dump({"schema": 1, "files": entries}, f, indent=2, sort_keys=True)
        f.write("\n")
    lines = ["%s  %s" % (e["sha256"], e["path"]) for e in entries]
    lines.append("%s  %s" % (_sha(os.path.join(d, MANIFEST)), MANIFEST))
    with open(os.path.join(d, SUMS), "w") as f:
        f.write("\n".join(sorted(lines, key=lambda l: l.split("  ", 1)[1])) + "\n")
    return entries


def verify(d):
    res = {"ok": False, "tampered": [], "missing": [], "extra": [], "errors": []}
    sp = os.path.join(d, SUMS)
    if not os.path.isfile(sp):
        res["errors"].append("%s missing" % SUMS)
        return res
    expected = {}
    with open(sp) as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line:
                continue
            if "  " not in line:
                res["errors"].append("malformed line %d" % n)
                continue
            h, p = line.split("  ", 1)
            expected[p] = h
    if not expected:
        res["errors"].append("%s lists no files" % SUMS)
    actual = set(_files(d, exclude=(SUMS,)))
    for p, h in sorted(expected.items()):
        if p not in actual:
            res["missing"].append(p)
        elif _sha(os.path.join(d, p)) != h:
            res["tampered"].append(p)
    res["extra"] = sorted(actual - set(expected))
    res["ok"] = not (res["tampered"] or res["missing"] or res["extra"] or res["errors"])
    return res


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if len(argv) != 2 or argv[0] not in ("build", "verify"):
        print("usage: manifest.py build|verify DIR", file=sys.stderr)
        return 2
    if argv[0] == "build":
        try:
            n = len(build(argv[1]))
        except ManifestError as e:
            print("error: %s" % e, file=sys.stderr)
            return 1
        print("manifest built: %d files" % n)
        return 0
    r = verify(argv[1])
    print(json.dumps(r, indent=2))
    return 0 if r["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
