"""d30_release_secrets.py - RED test for D-30: can a planted secret enter a
release archive built by scripts/release/build_archive.sh?

Works on a COPY of the tracked, non-submodule files (archive/ excluded for
size) inside a scratch dir. Plants FAKE secrets (random markers, never real
credentials), runs the REAL build_archive.sh, extracts BOTH archives and
scans them. CONTROL NEEDLE: a marker appended to a tracked file (README.md)
in the copy MUST be found in both archives, otherwise the instrument is
blind -> ERROR. A never-planted marker MUST NOT be found (false-positive
guard). RED iff a planted secret marker is found in an archive.
"""
import json
import os
import shutil
import subprocess
import sys
import tarfile
import uuid
import zipfile

ROOT = os.path.realpath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
RESULTS = os.environ.get("RED_RESULTS_FILE") or os.path.join(ROOT, "tests/red/results/d30.jsonl")
WORK = os.environ["RED_SCRATCH"]


def rec(id_, status, command, rc, excerpt):
    r = {"id": id_, "status": status, "command": command[:300], "exit_code": rc,
         "key_output_excerpt": " ".join(excerpt.split())[:300]}
    with open(RESULTS, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(r) + "\n")
    print("%-14s %-14s %s" % (id_, status, r["key_output_excerpt"]))
    return r


def find_markers(tree, markers):
    found = {k: [] for k in markers}
    for dp, _dn, fns in os.walk(tree):
        for fn in fns:
            p = os.path.join(dp, fn)
            if os.path.islink(p) or not os.path.isfile(p):
                continue
            try:
                data = open(p, "rb").read()
            except OSError:
                continue
            for k, m in markers.items():
                if m in data:
                    found[k].append(os.path.relpath(p, tree).split(os.sep, 1)[-1])
    return found


def main():
    copy = os.path.join(WORK, "llmctl-copy")
    out = os.path.join(WORK, "out")
    os.makedirs(out)
    ls = subprocess.run(["git", "ls-files", "-s", "-z"], cwd=ROOT, capture_output=True).stdout
    n = 0
    for ent in ls.split(b"\0"):
        if not ent:
            continue
        meta, path = ent.split(b"\t", 1)
        mode = meta.split()[0]
        rel = path.decode()
        if mode == b"160000" or rel.startswith("archive/"):
            continue                       # submodule gitlinks / 44 MB archive blob
        src, dst = os.path.join(ROOT, rel), os.path.join(copy, rel)
        if not os.path.lexists(src):
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if os.path.islink(src):
            os.symlink(os.readlink(src), dst)
        else:
            shutil.copy2(src, dst)
        n += 1
    tag = uuid.uuid4().hex
    markers = {
        "env": ("FAKE-ENV-KEY-%s" % tag).encode(),
        "ca.key": ("FAKE-CA-KEY-%s" % tag).encode(),
        "log.key": ("FAKE-LOG-KEY-%s" % tag).encode(),
        "CONTROL(README.md)": ("CONTROL-NEEDLE-%s" % tag).encode(),
        "NEGATIVE(unplanted)": ("NEVER-PLANTED-%s" % tag).encode(),
    }
    plant = {".env": b"LLMCTL_API_KEY=" + markers["env"] + b"\n",
             "cert/ca/ca.key": b"-----BEGIN FAKE KEY-----\n" + markers["ca.key"] + b"\n-----END FAKE KEY-----\n",
             "decide/log.key": markers["log.key"] + b"\n"}
    for rel, data in plant.items():
        p = os.path.join(copy, rel)
        if os.path.exists(p):
            rec("D-30", "ERROR", "plant", None, "planted path already exists in copy: " + rel)
            return 2
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as fh:
            fh.write(data)
        os.chmod(p, 0o600)
    with open(os.path.join(copy, "README.md"), "ab") as fh:
        fh.write(b"\n<!-- " + markers["CONTROL(README.md)"] + b" -->\n")

    cmd = "bash scripts/release/build_archive.sh <copy of %d tracked files + planted .env, cert/ca/ca.key, decide/log.key> <out>/rel" % n
    p = subprocess.run(["bash", os.path.join(copy, "scripts/release/build_archive.sh"), copy,
                        os.path.join(out, "rel")], capture_output=True, text=True, cwd=WORK)
    tgz, zp = os.path.join(out, "rel.tar.gz"), os.path.join(out, "rel.zip")
    if p.returncode != 0 or not (os.path.isfile(tgz) and os.path.isfile(zp)):
        rec("D-30", "ERROR", cmd, p.returncode, "build_archive.sh failed: " + p.stderr[-200:])
        return 2
    ex_t, ex_z = os.path.join(WORK, "ex_tar"), os.path.join(WORK, "ex_zip")
    os.makedirs(ex_t)
    os.makedirs(ex_z)
    with tarfile.open(tgz) as tf:
        tf.extractall(ex_t, filter="data")
    with zipfile.ZipFile(zp) as zf:
        zf.extractall(ex_z)
    res = {"tar.gz": find_markers(ex_t, markers), "zip": find_markers(ex_z, markers)}
    secret_keys = ("env", "ca.key", "log.key")
    # instrument validity (control needle + false-positive guard)
    for fmt, r in res.items():
        if not r["CONTROL(README.md)"]:
            rec("D-30", "ERROR", cmd, 0, "BLIND INSTRUMENT: control needle in tracked README.md not found in %s" % fmt)
            return 2
        if r["NEGATIVE(unplanted)"]:
            rec("D-30", "ERROR", cmd, 0, "scanner false positive on never-planted marker in %s" % fmt)
            return 2
    any_red = False
    for fmt, r in res.items():
        leaked = {k: v for k, v in r.items() if k in secret_keys and v}
        st = "RED" if leaked else "NOT-REPRODUCED"
        any_red |= bool(leaked)
        rec("D-30/" + fmt, st, cmd, 0,
            ("control needle found in %s (instrument sees); secrets present: %s" % (
                fmt, ", ".join("%s -> %s" % (k, v[0]) for k, v in leaked.items())))
            if leaked else "control needle found; no planted secret in %s" % fmt)
    rec("D-30", "RED" if any_red else "NOT-REPRODUCED", cmd, 0,
        "build_archive.sh archives the whole tree: planted untracked/ignored secrets (.env, cert/ca/ca.key, "
        "decide/log.key) %s in tar.gz and zip; control needle found in both archives" %
        ("ARE PRESENT" if any_red else "absent"))
    return 1 if any_red else 0


if __name__ == "__main__":
    sys.exit(main())
