#!/usr/bin/env python3
"""Secret-leak scanner with a mandatory control-needle self-test (SC-005).

Scans files, directories, tar/zip archives, logs and stdout captures for
  * literal secret values supplied in memory (never printed or returned), and
  * regex classes: PEM private-key headers and key-like tokens.

Before it may report "clean" it plants a freshly generated needle through the
SAME scanner function and requires the needle (literal AND regex classes, plain
file AND archive member) to be found. Otherwise the instrument is blind and the
run exits 3 with status 'BLIND INSTRUMENT' (a null from a blind instrument is
not evidence).

Exit codes: 0 clean, 1 leaks found, 3 blind instrument, 2 usage/IO error.
Usage: leak_scan.py [--secrets-file F] [--secrets-env NAME ...] PATH...
"""
import io
import json
import os
import re
import secrets as _rnd
import shutil
import sys
import tarfile
import tempfile
import zipfile

MIN_SECRET_LEN = 8
MAX_FILE_BYTES = 512 * 1024 * 1024
MAX_ARCHIVE_DEPTH = 3

REGEX_CLASSES = (
    ("pem-private-key", re.compile(rb"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----")),
    ("key-like-token", re.compile(
        rb"(?:\bsk-[A-Za-z0-9_-]{20,}"
        rb"|\bAKIA[0-9A-Z]{16}\b"
        rb"|\bgh[pousr]_[A-Za-z0-9]{30,}"
        rb"|\bhf_[A-Za-z0-9]{30,}"
        rb"|\bxox[baprs]-[A-Za-z0-9-]{10,}"
        rb"|\bBearer\s+[A-Za-z0-9._~+/=-]{24,})")),
)


def find_in_bytes(data, secrets):
    """Return [(kind, offset, secret_index_or_None)] for one blob. Values are never returned."""
    out = []
    for i, s in enumerate(secrets or []):
        b = s.encode() if isinstance(s, str) else bytes(s)
        if len(b) < MIN_SECRET_LEN:
            continue
        off = data.find(b)
        if off >= 0:
            out.append(("literal", off, i))
    for kind, rx in REGEX_CLASSES:
        m = rx.search(data)
        if m:
            out.append((kind, m.start(), None))
    return out


def _scan_blob(label, data, secrets, depth, findings):
    for kind, off, idx in find_in_bytes(data, secrets):
        f = {"path": label, "kind": kind, "offset": off}
        if idx is not None:
            f["secret_index"] = idx
        findings.append(f)
    if depth >= MAX_ARCHIVE_DEPTH:
        return
    bio = io.BytesIO(data)
    try:
        if zipfile.is_zipfile(bio):
            with zipfile.ZipFile(io.BytesIO(data)) as z:
                for zi in z.infolist():
                    if not zi.is_dir() and zi.file_size <= MAX_FILE_BYTES:
                        _scan_blob(label + "!" + zi.filename, z.read(zi), secrets, depth + 1, findings)
            return
        bio.seek(0)
        with tarfile.open(fileobj=bio, mode="r:*") as t:
            for ti in t:
                if ti.isfile() and ti.size <= MAX_FILE_BYTES:
                    fh = t.extractfile(ti)
                    if fh is not None:
                        _scan_blob(label + "!" + ti.name, fh.read(), secrets, depth + 1, findings)
    except (tarfile.TarError, zipfile.BadZipFile, EOFError, OSError):
        pass  # not an archive (or unreadable archive): raw bytes were already scanned


def scan_paths(paths, secrets):
    """Scan files/dirs/archives. Returns findings (no secret values)."""
    findings = []
    for root in paths:
        if os.path.isdir(root):
            for dp, dn, fn in os.walk(root):
                dn.sort()
                for name in sorted(fn):
                    _scan_file(os.path.join(dp, name), secrets, findings)
        else:
            _scan_file(root, secrets, findings)
    return findings


def _scan_file(path, secrets, findings):
    try:
        if os.path.islink(path) or os.path.getsize(path) > MAX_FILE_BYTES:
            return
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        findings.append({"path": path, "kind": "unreadable", "offset": 0})
        return
    _scan_blob(path, data, secrets, 0, findings)


def _control_needle(scanner):
    """Plant a decoy through the same scanner; True only if every class is seen."""
    needle = "nd" + _rnd.token_hex(12)
    pem = ("-----BEGIN " + "PRIVATE KEY-----\n" + needle + "\n").encode()
    tok = ("sk-" + _rnd.token_hex(16)).encode()
    d = tempfile.mkdtemp(prefix="leakscan-needle")
    try:
        with open(os.path.join(d, "plain.txt"), "wb") as f:
            f.write(needle.encode() + b"\n" + pem + tok)
        with tarfile.open(os.path.join(d, "arc.tar.gz"), "w:gz") as t:
            data = b"member " + needle.encode()
            ti = tarfile.TarInfo("in/m.txt")
            ti.size = len(data)
            t.addfile(ti, io.BytesIO(data))
        try:
            found = scanner([d], [needle])
        except Exception:  # a crashing scanner is blind too
            return False
        kinds = {(x.get("kind"), "!" in x.get("path", "")) for x in found}
        return {("literal", False), ("literal", True),
                ("pem-private-key", False), ("key-like-token", False)} <= kinds
    finally:
        shutil.rmtree(d, ignore_errors=True)


def run(paths, secrets, scanner=None):
    """Return (rc, report). rc: 0 clean, 1 leaks, 3 blind instrument."""
    scanner = scanner or scan_paths
    needle_ok = _control_needle(scanner)
    if not needle_ok:
        return 3, {"status": "BLIND INSTRUMENT", "control_needle_found": False, "findings": []}
    findings = scanner(list(paths), list(secrets))
    status = "clean" if not findings else "LEAKS FOUND"
    return (0 if not findings else 1), {"status": status, "control_needle_found": True,
                                        "findings": findings, "paths": list(paths)}


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    secrets, paths = [], []
    it = iter(argv)
    try:
        for a in it:
            if a == "--secrets-file":
                with open(next(it)) as f:
                    secrets += [l.rstrip("\n") for l in f if l.strip()]
            elif a == "--secrets-env":
                v = os.environ.get(next(it))
                if v:
                    secrets.append(v)
            else:
                paths.append(a)
    except (StopIteration, OSError) as e:
        print("usage error: %s" % type(e).__name__, file=sys.stderr)
        return 2
    if not paths:
        print("usage: leak_scan.py [--secrets-file F] [--secrets-env NAME] PATH...", file=sys.stderr)
        return 2
    rc, report = run(paths, secrets)
    print(json.dumps(report, indent=2))
    if rc == 3:
        print("BLIND INSTRUMENT: control needle was not found; clean result is NOT evidence", file=sys.stderr)
    return rc


if __name__ == "__main__":
    sys.exit(main())
