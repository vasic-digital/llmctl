#!/usr/bin/env python3
"""Re-verify every pinned decision-profile file against huggingface.co (T060).
LFS files: size + sha256 from the tree API (lfs.oid) - never downloaded.
Non-LFS files < 20 MB: downloaded from /resolve/<rev>/ and sha256 computed.
HF_TOKEN is honoured when set and never printed. Usage: pin_reverify.py [--write-catalog]"""
import hashlib, json, os, sys, time, urllib.request, urllib.error
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
CAT = os.path.join(ROOT, "models", "catalog.json")
OUT = os.path.join(os.path.dirname(__file__), "pin-reverify.json")
BASE = "https://huggingface.co"
LIMIT = 20 * 1024 * 1024

def req(url):
    h = {"User-Agent": "llmctl-pin-reverify"}
    if os.environ.get("HF_TOKEN"):
        h["Authorization"] = "Bearer " + os.environ["HF_TOKEN"]
    return urllib.request.Request(url, headers=h)

def get_json(url):
    with urllib.request.urlopen(req(url), timeout=60) as r:
        return json.load(r)

cat = json.load(open(CAT))
rows, licences = [], {}
for name, p in cat["profiles"].items():
    if "decide" not in p.get("capability", []):
        continue
    repo, rev = p["hf_repo"], p["hf_revision"]
    tree = {t["path"]: t for t in get_json("%s/api/models/%s/tree/%s?recursive=1" % (BASE, repo, rev)) if t.get("type") == "file"}
    time.sleep(0.5)
    info = get_json("%s/api/models/%s/revision/%s" % (BASE, repo, rev))
    licences[name] = {"repo": repo, "api_sha": info.get("sha"), "revision_match": info.get("sha") == rev,
                      "license": (info.get("cardData") or {}).get("license"),
                      "license_tag": [t for t in info.get("tags", []) if t.startswith("license:")]}
    for f in p["files"]:
        t = tree.get(f["name"])
        row = {"profile": name, "repo": repo, "revision": rev, "path": f["name"],
               "catalog_size": f["size"], "catalog_sha256": f["sha256"]}
        if t is None:
            row.update(size=None, sha256=None, source="missing-upstream", match=False)
        else:
            row["size"] = t["size"]
            lfs = t.get("lfs") or {}
            if lfs.get("oid"):
                row.update(sha256=lfs["oid"], source="api")
            elif t["size"] < LIMIT:
                h = hashlib.sha256(); n = 0
                with urllib.request.urlopen(req("%s/%s/resolve/%s/%s" % (BASE, repo, rev, f["name"])), timeout=120) as r:
                    for chunk in iter(lambda: r.read(1 << 20), b""):
                        h.update(chunk); n += len(chunk)
                row.update(sha256=h.hexdigest(), source="computed", downloaded_bytes=n)
                row["size_matches_download"] = (n == t["size"])
                time.sleep(0.5)
            else:
                row.update(sha256=None, source="unverifiable-too-large-non-lfs")
            row["match"] = (row["size"] == f["size"] and row.get("sha256") is not None and
                            (f["sha256"] is None or f["sha256"] == row["sha256"]))
            row["catalog_sha_was_null"] = f["sha256"] is None
        rows.append(row)
    time.sleep(0.5)
doc = {"retrieved_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "source": BASE,
       "method": "tree API (size, lfs.oid) + computed sha256 for non-LFS files < 20 MB; no multi-GB downloads",
       "hf_token_used": bool(os.environ.get("HF_TOKEN")), "licences": licences, "files": rows,
       "summary": {"files": len(rows), "match": sum(1 for r in rows if r["match"]),
                   "mismatch": [r["profile"] + ":" + r["path"] for r in rows if not r["match"]],
                   "filled_null": [r["profile"] + ":" + r["path"] for r in rows if r.get("catalog_sha_was_null")]}}
json.dump(doc, open(OUT, "w"), indent=2); print(json.dumps(doc["summary"], indent=1))
