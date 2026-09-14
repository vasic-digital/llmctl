#!/usr/bin/env bash
# test_catalog_json.sh - catalog validity and internal consistency.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

CATALOG="${LLMCTL_ROOT}/models/catalog.json"

# 1. Valid JSON.
rc=0
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${CATALOG}" || rc=$?
assert_eq 0 "${rc}" "catalog parses as JSON (python3 json.load)"

# 2. Cross-checks: required fields, unique ports, sane values.
out="$(python3 - "${CATALOG}" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
errors = []
ports = {}
for name, p in d["profiles"].items():
    for field in ("engine", "port", "capability", "min_tier", "hf_repo", "files"):
        if field not in p:
            errors.append("%s: missing field %s" % (name, field))
    if p.get("engine") not in ("llama", "colibri"):
        errors.append("%s: bad engine %r" % (name, p.get("engine")))
    if p.get("min_tier") not in ("baseline", "workstation", "datacenter"):
        errors.append("%s: bad min_tier %r" % (name, p.get("min_tier")))
    port = p.get("port")
    if port in ports:
        errors.append("%s: duplicate port %s (also %s)" % (name, port, ports[port]))
    ports[port] = name
    if not p.get("files"):
        errors.append("%s: empty files list" % name)
    for f in p.get("files", []):
        if "name" not in f or "size" not in f:
            errors.append("%s: file entry missing name/size" % name)
        sha = f.get("sha256")
        if sha is not None and (not isinstance(sha, str) or len(sha) != 64):
            errors.append("%s: bad sha256 for %s" % (name, f.get("name")))
# advertised port table must match profile ports
for name, port in d.get("ports", {}).items():
    if name in d["profiles"] and d["profiles"][name].get("port") != port:
        errors.append("ports table mismatch for %s" % name)
# the 8 GGUF profiles + 2 colibri profiles are all present
expected = {"fast","coder","vision","vision-pro","moe-fast","small",
            "ws-dense-32b","ws-moe-30b","colibri-glm","colibri-qwen36"}
missing = expected - set(d["profiles"])
if missing:
    errors.append("missing profiles: %s" % sorted(missing))
for e in errors:
    print("ERROR:", e)
print("profiles:", len(d["profiles"]))
sys.exit(1 if errors else 0)
PYEOF
)" && rc=0 || rc=$?
printf '%s\n' "${out}"
assert_eq 0 "${rc}" "catalog cross-check (fields, unique ports, known profiles)"

# 3. Every GGUF model file has a real (non-null) sha256 - this is the
#    project's verified-download contract.
out="$(python3 - "${CATALOG}" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
bad = ["%s/%s" % (n, f["name"]) for n, p in d["profiles"].items()
       for f in p["files"] if f["name"].endswith(".gguf") and not f.get("sha256")]
for b in bad:
    print("NULL sha256:", b)
sys.exit(1 if bad else 0)
PYEOF
)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "all GGUF files carry a real sha256"

test_finish
