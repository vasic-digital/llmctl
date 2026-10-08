#!/usr/bin/env python3
"""scan_archive.py - independent post-scan of a release archive (tar.gz / zip).

Second, separately-implemented line of defence behind scripts/release/build_archive.sh
(C-03 / C-21): the bash build filter and this scanner share NO code and NO matching logic,
so a defect in one (a mutated deny-list, a case-glob that spans '/') cannot also blind the
other.  It reads the archive with tarfile / zipfile and reports, one finding per line on
stderr, anything that must never ship:

  * a secret-looking PATH, judged component by component (never a glob across '/'),
    case-insensitively: .env / .env.* (not .env.example), *.key *.pem *.p12 *.pfx *.jks
    *.keystore, id_rsa* id_dsa* id_ecdsa* id_ed25519*, .netrc, .pgpass, credentials*.json,
    and any `cert` directory;
  * a PEM private-key BLOCK in the content of a working-tree file (a real BEGIN line followed
    by base64 body lines; a single line quoting the header, as scanners and tests do, is not a
    block);
  * unreleased git state inside a shipped .git: refs/stash, reflogs, hooks other than samples,
    a remote / credential / extraheader / url-rewrite section in a config, a URL carrying
    userinfo, and any .gitmodules URL carrying userinfo.

Exemptions are EXACT repo-relative paths read from manifest files (one path per line, '#'
comments); an entry containing a glob character or '..' is rejected, so an exemption can never
widen into a subtree. An entry applies to the scanned archive's own paths only; for a path INSIDE a
nested archive the entry is "<outer-path>!<inner-path>" (chain "a!b!c" for deeper nesting), so an
exemption granted to one file can never exempt the same relative path in every nested archive.
Nested archives are bounded: compressed size, depth, and a shared DECOMPRESSED-bytes budget that is
enforced while streaming (SCAN_ARCHIVE_MAX_NEST_DECOMPRESSED); exceeding any bound is a finding.

Usage: scan_archive.py [--allow MANIFEST]... ARCHIVE [ARCHIVE...]
Exit: 0 clean, 1 findings, 2 usage / unreadable archive / bad manifest.
"""
import bz2
import gzip
import io
import lzma
import os
import re
import sys
import tarfile
import zipfile

SECRET_EXT = (".key", ".pem", ".p12", ".pfx", ".jks", ".keystore")
SECRET_EXACT = {".netrc", ".pgpass"}
KEY_PREFIXES = ("id_rsa", "id_dsa", "id_ecdsa", "id_ed25519")
PEM_RE = re.compile(
    rb"^-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----[ \t]*\r?\n(?:[A-Za-z0-9+/=]{32,}[ \t]*\r?\n)+",
    re.M,
)
CRED_URL_RE = re.compile(r"[a-z][a-z0-9+.-]*://[^/@\s]+@", re.I)
MAX_CONTENT = 2 * 1024 * 1024
# C2-16: archives nested inside the archive (a tracked archive/llmctl.zip ships inside every release) are
# opened and judged by the same rules, to a bounded depth and size. Beyond the bound the scan FAILS CLOSED
# (a finding), it never silently treats the nested archive as opaque bytes; an EXACT allow-manifest entry
# for the nested archive's path is the explicit opt-out.
NESTED_EXT = (".zip", ".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz", ".jar", ".whl")
MAX_NEST_DEPTH = int(os.environ.get("SCAN_ARCHIVE_MAX_NEST_DEPTH", "3"))
MAX_NEST_BYTES = int(os.environ.get("SCAN_ARCHIVE_MAX_NEST_BYTES", str(256 * 1024 * 1024)))
MAX_NEST_ENTRIES = 200000
# C3-05: the size bound above is on COMPRESSED bytes; a 4 MiB nested tar.gz can inflate to 4 GiB (minutes of CPU). The
# DECOMPRESSED bytes of all nested archives of one scanned archive share ONE budget, enforced while streaming (a chunked
# read that stops at the limit - never "inflate it all, then look"); exceeding it FAILS CLOSED.
MAX_NEST_DECOMPRESSED = int(os.environ.get("SCAN_ARCHIVE_MAX_NEST_DECOMPRESSED", str(512 * 1024 * 1024)))
_CHUNK = 1024 * 1024


class BudgetExceeded(Exception):
    pass


class Budget:
    def __init__(self, limit):
        self.limit = limit
        self.used = 0

    def add(self, n):
        self.used += n
        if self.used > self.limit:
            raise BudgetExceeded("decompressed size exceeds the %d-byte budget (zip bomb?)" % self.limit)


class BudgetStream:
    """Seekable read-only view of a decompressor; every byte newly decompressed is charged to the budget."""

    def __init__(self, f, budget):
        self.f, self.budget, self.pos, self.hw = f, budget, 0, 0

    def _advance(self, n):
        self.pos += n
        if self.pos > self.hw:
            self.budget.add(self.pos - self.hw)
            self.hw = self.pos

    def read(self, n=-1):
        if n is not None and 0 <= n <= _CHUNK:
            d = self.f.read(n)
            self._advance(len(d))
            return d
        out, left = [], (-1 if n is None or n < 0 else n)
        while left != 0:
            d = self.f.read(_CHUNK if left < 0 else min(_CHUNK, left))
            if not d:
                break
            self._advance(len(d))
            out.append(d)
            if left > 0:
                left -= len(d)
        return b"".join(out)

    def tell(self):
        return self.pos

    def seekable(self):
        return True

    def seek(self, off, whence=0):
        target = off if whence == 0 else (self.pos + off if whence == 1 else None)
        if target is None:
            raise OSError("unsupported seek")
        if target < self.pos:
            self.f.seek(target)
            self.pos = target
        else:
            while self.pos < target:
                if not self.read(min(_CHUNK, target - self.pos)):
                    break
        return self.pos


def load_allow(paths):
    allowed = set()
    for mf in paths:
        try:
            lines = open(mf, encoding="utf-8").read().splitlines()
        except OSError as e:
            raise SystemExit("scan_archive: cannot read allow manifest %s: %s" % (mf, e))
        for n, raw in enumerate(lines, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if any(c in line for c in "*?[]\\") or ".." in line.split("/") or line.startswith("/"):
                print("scan_archive: %s:%d: allow entry %r must be an exact repo-relative path (no globs)" % (mf, n, line), file=sys.stderr)
                raise SystemExit(2)
            allowed.add(line)
    return allowed


def path_is_secret(rel):
    parts = [p for p in rel.split("/") if p]
    if ".git" in parts:
        return False  # git internals are judged by git_state_findings
    low = [p.lower() for p in parts]
    for i, p in enumerate(low):
        last = i == len(low) - 1
        if p == ".env" or (p.startswith(".env.") and p != ".env.example"):
            return True
        if p == "cert" and not last:
            return True
        if last:
            if p.endswith(SECRET_EXT) or p in SECRET_EXACT or p.startswith(KEY_PREFIXES):
                return True
            if p.startswith("credentials") and p.endswith(".json"):
                return True
    return False


def git_state_findings(rel, data):
    """Findings for entries that live inside a shipped .git directory."""
    out = []
    parts = rel.split("/")
    if ".git" not in parts:
        return out
    tail = "/".join(parts[parts.index(".git") + 1:])
    if tail.endswith("refs/stash") or tail == "refs/stash":
        out.append("unreleased git state (stash ref) in %s" % rel)
    if tail.startswith("logs/") or "/logs/" in tail:
        out.append("git reflog shipped: %s" % rel)
    if (tail.startswith("hooks/") or "/hooks/" in tail) and not tail.endswith(".sample"):
        out.append("git hook shipped: %s" % rel)
    if tail == "config" or tail.endswith("/config"):
        text = data.decode("utf-8", "replace") if data is not None else ""
        for line in text.splitlines():
            s = line.strip().lower()
            if re.match(r"\[(remote|credential|http|url|include|includeif)\b", s):
                out.append("git config %s has a [%s] section" % (rel, re.match(r"\[(\w+)", s).group(1)))
                break
        if CRED_URL_RE.search(text):
            out.append("git config %s contains a URL with embedded credentials" % rel)
    return out


def _decompressor(data):
    raw = io.BytesIO(data)
    if data[:2] == b"\x1f\x8b":
        return gzip.GzipFile(fileobj=raw)
    if data[:3] == b"BZh":
        return bz2.BZ2File(raw)
    if data[:6] == b"\xfd7zXZ\x00":
        return lzma.LZMAFile(raw)
    return None


def nested_entries(rel, data, budget):
    """(entries, error) for a nested archive held in memory; entries yield (name, size, reader).
    Raises BudgetExceeded when it would inflate past the shared decompressed-bytes budget."""
    low = rel.lower()
    try:
        if low.endswith((".zip", ".jar", ".whl")):
            return list(zip_entries(io.BytesIO(data), budget)), None
        dec = _decompressor(data)
        if dec is None:
            return list(tar_entries(io.BytesIO(data))), None
        return list(tar_entries(BudgetStream(dec, budget), plain=True)), None
    except (OSError, tarfile.TarError, zipfile.BadZipFile, EOFError, ValueError) as e:
        return None, str(e)


def scan_entries(entries, allowed, label, depth=0, strip_top=True, budget=None, ctx=""):
    """entries: iterable of (name, reader) ; reader() -> bytes | None.
    ctx: "" for the scanned archive itself, else the chain "<outer-path>!<nested-path>" of the nested archive being
    judged; an allow entry applies to a nested path ONLY in the form "<ctx>!<path>" (C3-05)."""
    bad = []
    for name, size, reader in entries:
        if strip_top:
            rel = name.split("/", 1)[1] if "/" in name else ""
        else:
            rel = name
        if not rel or rel.endswith("/"):
            continue
        key = rel if not ctx else ctx + "!" + rel
        if key in allowed:
            continue
        # C3-05: a nested archive's single top directory is stripped to get the repo-relative path, but the UNSTRIPPED
        # name is judged too - `tar czf certs.tgz cert/` has the single top `cert`, which stripping would hide.
        if depth > 0 and strip_top and path_is_secret(name) and not path_is_secret(rel):
            bad.append("SECRET PATH in %s: %s" % (label, name))
            continue
        if rel.lower().endswith(NESTED_EXT) and ".git" not in rel.split("/"):
            if depth >= MAX_NEST_DEPTH:
                bad.append("NESTED ARCHIVE too deep to scan in %s: %s (depth > %d)" % (label, rel, MAX_NEST_DEPTH))
                continue
            if size > MAX_NEST_BYTES:
                bad.append("NESTED ARCHIVE too large to scan in %s: %s (%d bytes > %d); allow-list it by exact path if it is public" % (label, rel, size, MAX_NEST_BYTES))
                continue
            data = reader()
            try:
                sub, err = nested_entries(rel, data, budget) if data is not None else (None, "unreadable")
            except BudgetExceeded as e:
                bad.append("NESTED ARCHIVE too large once decompressed in %s: %s (%s); allow-list it by exact path if it is public" % (label, rel, e))
                continue
            if sub is None:
                bad.append("NESTED ARCHIVE unreadable in %s: %s (%s)" % (label, rel, err))
                continue
            if len(sub) > MAX_NEST_ENTRIES:
                bad.append("NESTED ARCHIVE has too many entries to scan in %s: %s (%d)" % (label, rel, len(sub)))
                continue
            # a nested release archive has the same <top>/... shape as the outer one: strip a single common top dir
            tops = {n.split("/", 1)[0] for n, _, _ in sub}
            single_top = len(tops) == 1 and all("/" in n for n, _, _ in sub)
            bad.extend(scan_entries(sub, allowed, "%s>%s" % (label, rel), depth + 1, strip_top=single_top, budget=budget, ctx=key))
            continue
        if path_is_secret(rel):
            bad.append("SECRET PATH in %s: %s" % (label, rel))
            continue
        in_git = ".git" in rel.split("/")
        is_cfg = in_git and (rel.endswith("/config") or rel.endswith(".git/config"))
        is_gm = rel == ".gitmodules" or rel.endswith("/.gitmodules")
        if in_git and not is_cfg:
            bad.extend("%s: %s" % (label, f) for f in git_state_findings(rel, None))
            continue
        if size > MAX_CONTENT and not is_cfg and not is_gm:
            continue
        data = reader()
        if data is None:
            continue
        if is_cfg:
            bad.extend("%s: %s" % (label, f) for f in git_state_findings(rel, data))
        elif is_gm:
            if CRED_URL_RE.search(data.decode("utf-8", "replace")):
                bad.append("%s: %s contains a URL with embedded credentials" % (label, rel))
        elif not in_git and PEM_RE.search(data):
            bad.append("PRIVATE KEY BLOCK in %s: %s" % (label, rel))
    return bad


def tar_entries(path, plain=False):
    if plain:
        tf = tarfile.open(fileobj=path, mode="r:")
    else:
        tf = tarfile.open(fileobj=path, mode="r:*") if hasattr(path, "read") else tarfile.open(path, "r:*")
    for m in tf:
        if not m.isfile():
            if m.name:
                yield m.name + ("/" if m.isdir() else ""), 0, (lambda: None)
            continue
        yield m.name, m.size, (lambda m=m: tf.extractfile(m).read())


def zip_entries(path, budget=None):
    zf = zipfile.ZipFile(path)
    infos = zf.infolist()
    if budget is not None:
        budget.add(sum(i.file_size for i in infos))      # reads are bounded by the declared size
    for i in infos:
        if i.is_dir():
            yield i.filename, 0, (lambda: None)
            continue
        yield i.filename, i.file_size, (lambda i=i: zf.read(i))


def main(argv):
    allow_files, archives = [], []
    it = iter(argv)
    for a in it:
        if a == "--allow":
            try:
                allow_files.append(next(it))
            except StopIteration:
                print("scan_archive: --allow needs a manifest path", file=sys.stderr)
                return 2
        else:
            archives.append(a)
    if not archives:
        print(__doc__, file=sys.stderr)
        return 2
    allowed = load_allow(allow_files)
    bad = []
    for a in archives:
        try:
            if a.endswith(".zip"):
                bad += scan_entries(zip_entries(a), allowed, "zip", budget=Budget(MAX_NEST_DECOMPRESSED))
            else:
                bad += scan_entries(tar_entries(a), allowed, "tar.gz", budget=Budget(MAX_NEST_DECOMPRESSED))
        except (OSError, tarfile.TarError, zipfile.BadZipFile) as e:
            print("scan_archive: cannot read %s: %s" % (a, e), file=sys.stderr)
            return 2
    for b in bad:
        print("build_archive: " + b, file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
