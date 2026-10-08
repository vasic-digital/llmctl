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
    if p.get("engine") not in ("llama", "colibri", "onnx"):
        errors.append("%s: bad engine %r" % (name, p.get("engine")))
    # "below-minimum" is a valid min_tier (catalog_tier_rank includes it;
    # the tier gate only RECOMMENDS, it never blocks) - the decide-tiny
    # profile uses it intentionally for its CPU-friendly 0.53 GB model.
    if p.get("min_tier") not in ("below-minimum", "baseline", "workstation", "datacenter"):
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

# 4. Decision profiles (decide capability): pinned entries whose size/sha256/
#    commit were re-verified against huggingface.co (not the mirror) - the
#    in-repo evidence is specs/009-jev-decision-models/evidence/pin-reverify.json
#    (section 6 below cross-checks the catalog against it). The unique-port
#    loop in check 2 already covers 8092-8094 automatically once added to
#    the profiles map; here we pin the decide-specific contract explicitly.
out="$(python3 - "${CATALOG}" <<'PYEOF'
import json, re, sys
d = json.load(open(sys.argv[1]))
errors = []
expected = {
    "decide-tiny": (8092, "below-minimum"),
    "decide": (8093, "baseline"),
    "decide-pro": (8094, "workstation"),
}
sha_re = re.compile(r"^[0-9a-f]{64}$")
for name, (port, min_tier) in expected.items():
    p = d["profiles"].get(name)
    if p is None:
        errors.append("%s: profile missing" % name)
        continue
    if p.get("engine") != "llama":
        errors.append("%s: engine must be llama" % name)
    if "decide" not in p.get("capability", []):
        errors.append("%s: capability must contain 'decide'" % name)
    if p.get("port") != port:
        errors.append("%s: port must be %d" % (name, port))
    if d.get("ports", {}).get(name) != port:
        errors.append("%s: ports map must advertise %d" % (name, port))
    if p.get("min_tier") != min_tier:
        errors.append("%s: min_tier must be %s" % (name, min_tier))
    files = [f for f in p.get("files", []) if f.get("role") == "model"]
    if len(files) != 1:
        errors.append("%s: expected exactly one model file" % name)
    for f in files:
        if not sha_re.match(f.get("sha256") or ""):
            errors.append("%s: sha256 must be a real 64-hex pin (not a placeholder)" % name)
        if not (f.get("size") or 0) > 0:
            errors.append("%s: size must be > 0" % name)
    rev = p.get("hf_revision") or ""
    if not re.match(r"^[0-9a-f]{40}$", rev):
        errors.append("%s: hf_revision must be pinned to an immutable commit sha" % name)
for e in errors:
    print("ERROR:", e)
sys.exit(1 if errors else 0)
PYEOF
)" && rc=0 || rc=$?
printf '%s\n' "${out}"
assert_eq 0 "${rc}" "decide profiles: present, llama engine, decide capability, real sha256 pins, ports 8092-8094"

# 5. Iteration-2 decision profiles: the onnx-engine encoder profile
#    (decide-nli) and the two additional GGUF profiles (decide-2b,
#    decide-max), pinned per specs/009-jev-decision-models/evidence/pin-reverify.json.
out="$(python3 - "${CATALOG}" <<'PYEOF'
import json, re, sys
d = json.load(open(sys.argv[1]))
errors = []
sha_re = re.compile(r"^[0-9a-f]{64}$")
rev_re = re.compile(r"^[0-9a-f]{40}$")
# name -> (port, min_tier, engine)
expected = {
    "decide-nli": (8096, "below-minimum", "onnx"),
    "decide-2b": (8098, "baseline", "llama"),
    "decide-max": (8097, "workstation", "llama"),
}
for name, (port, min_tier, engine) in expected.items():
    p = d["profiles"].get(name)
    if p is None:
        errors.append("%s: profile missing" % name)
        continue
    if p.get("engine") != engine:
        errors.append("%s: engine must be %s" % (name, engine))
    if "decide" not in p.get("capability", []):
        errors.append("%s: capability must contain 'decide'" % name)
    if p.get("port") != port:
        errors.append("%s: port must be %d" % (name, port))
    if d.get("ports", {}).get(name) != port:
        errors.append("%s: ports map must advertise %d" % (name, port))
    if p.get("min_tier") != min_tier:
        errors.append("%s: min_tier must be %s" % (name, min_tier))
    if not rev_re.match(p.get("hf_revision") or ""):
        errors.append("%s: hf_revision must be pinned to an immutable commit sha" % name)
    models = [f for f in p.get("files", []) if f.get("role") == "model"]
    if len(models) != 1:
        errors.append("%s: expected exactly one model-role file" % name)
    for f in models:
        if not sha_re.match(f.get("sha256") or ""):
            errors.append("%s: model file sha256 must be a real 64-hex pin" % name)
        if not (f.get("size") or 0) > 0:
            errors.append("%s: model file size must be > 0" % name)
# decide-nli specifics: the onnx runner needs model.onnx (LFS, pinned) and
# a SentencePiece tokenizer (LFS, pinned); small non-LFS configs may carry
# the null-sha + gitblob1 fallback allowance.
nli = d["profiles"].get("decide-nli", {})
names = {f["name"]: f for f in nli.get("files", [])}
if "onnx/model.onnx" not in names:
    errors.append("decide-nli: onnx/model.onnx missing")
if not sha_re.match((names.get("onnx/spm.model") or {}).get("sha256") or ""):
    errors.append("decide-nli: onnx/spm.model must carry a real sha256 (it is LFS)")
for f in nli.get("files", []):
    if f.get("sha256") is None and (f.get("size") or 0) > 100 * 1024 * 1024:
        errors.append("decide-nli: null sha256 allowed only for non-LFS files: %s" % f["name"])
for e in errors:
    print("ERROR:", e)
sys.exit(1 if errors else 0)
PYEOF
)" && rc=0 || rc=$?
printf '%s\n' "${out}"
assert_eq 0 "${rc}" "iter2 profiles: decide-nli (onnx), decide-2b, decide-max pinned and consistent (ports 8096/8098/8097)"

# 6. Decision-profile schema contract (specs/009-jev-decision-models/
#    contracts/catalog-schema.md, FR-002..FR-006, D-13, D-22, D-26): the
#    validator is a standalone python program so the paired mutation tests
#    below can run the SAME code against deliberately-broken catalog copies
#    and require it to FAIL (FR-041 / catalog-schema rule 6).
VALIDATOR="${TEST_TMP}/validate_decision_schema.py"
cat > "${VALIDATOR}" <<'PYEOF'
import json, re, sys, os
path = sys.argv[1]
evidence = sys.argv[2] if len(sys.argv) > 2 else None
d = json.load(open(path))
errors = []
SHA = re.compile(r"^[0-9a-f]{64}$")
REV = re.compile(r"^[0-9a-f]{40}$")
LICENSES = {"Apache-2.0", "MIT", "BSD-3-Clause", "BSD-2-Clause"}
CLASSES = {"vendor-measured", "independent", "llmctl-measured", "unverified"}
ROLES = {"model", "tokenizer", "config", "head", "mmproj"}
# jev-verdict: Jev-Style verdict readout (one " ->" slot per option); catalogued, NOT served by the
# gateway yet (internal/gateway/catalog.go unsupportedReason)
PROTOCOLS = {"letter-logit", "systemone-native", "nli-onnx", "jev-verdict"}
CHAT_CAPS = {"chat", "coder", "vision"}
tiers = ("below-minimum", "baseline", "workstation", "datacenter")
ports = {}
for name, p in d["profiles"].items():
    caps = set(p.get("capability", []))
    port = p.get("port")
    if port in ports:
        errors.append("%s: duplicate port %s (also %s)" % (name, port, ports[port]))
    ports[port] = name
    if port == 8099:
        errors.append("%s: port 8099 is held by another program on this host" % name)
    if d.get("ports", {}).get(name) != port:
        errors.append("%s: ports map entry missing or different from profile port" % name)
    if "." in name:
        errors.append("%s: profile names must not contain '.' (instance separator)" % name)
    is_dec = "decide" in caps
    has_obj = "decision" in p
    if is_dec != has_obj:
        errors.append("%s: 'decision' object must be present iff capability has 'decide'" % name)
    if not is_dec:
        continue
    if caps & CHAT_CAPS:
        errors.append("%s: decision profile must not carry a chat capability (%s)" % (name, sorted(caps & CHAT_CAPS)))
    if p.get("min_tier") not in tiers:
        errors.append("%s: bad min_tier" % name)
    if not REV.match(p.get("hf_revision") or ""):
        errors.append("%s: hf_revision must be a 40-hex commit" % name)
    lic = p.get("license")
    if lic not in LICENSES:
        errors.append("%s: licence %r not on the allow-list (%s)" % (name, lic, sorted(LICENSES)))
    bm = (p.get("provenance") or {}).get("benchmark") or {}
    if bm.get("class") not in CLASSES or not bm.get("value"):
        errors.append("%s: provenance.benchmark needs a value and class in %s" % (name, sorted(CLASSES)))
    for f in p.get("files", []):
        if not SHA.match(f.get("sha256") or ""):
            errors.append("%s: file %s must carry a non-null 64-hex sha256" % (name, f.get("name")))
        if not isinstance(f.get("size"), int) or f["size"] <= 0:
            errors.append("%s: file %s needs a positive size" % (name, f.get("name")))
        if f.get("role") not in ROLES:
            errors.append("%s: file %s has bad role %r" % (name, f.get("name"), f.get("role")))
    dec = p.get("decision") or {}
    proto = dec.get("protocol")
    if proto not in PROTOCOLS:
        errors.append("%s: decision.protocol %r not in %s" % (name, proto, sorted(PROTOCOLS)))
    if (p.get("engine") == "onnx") != (proto == "nli-onnx"):
        errors.append("%s: engine onnx <=> protocol nli-onnx violated (engine=%s protocol=%s)" % (name, p.get("engine"), proto))
    if p.get("engine") == "llama" and proto not in ("letter-logit", "systemone-native", "jev-verdict"):
        errors.append("%s: llama engine needs protocol letter-logit|systemone-native|jev-verdict" % name)
    # the Jev-Style decision GGUFs are read at a verdict slot per option, never by a generated letter
    # (vendor readout_config.json "readout": "verdict"; measured letter mass ~0, 2026-10-08)
    if (p.get("hf_repo") or "").startswith("chaoliangUNSW/Jev-Style-") and proto != "jev-verdict":
        errors.append("%s: Jev-Style verdict model needs protocol jev-verdict (got %r)" % (name, proto))
    if proto == "jev-verdict" and "not servable" not in (dec.get("tier_note") or ""):
        errors.append("%s: a jev-verdict profile must say in decision.tier_note that it is not servable yet" % name)
    mo = dec.get("max_options")
    # JevK5 is read in ONE pass over the letters A..P (vendor README: LETTERS = "ABCDEFGHIJKLMNOP"); more than 16
    # options needs the vendor runtime's knockout, which the gateway does not implement
    if (p.get("hf_repo") or "") == "alibiserikbay/JevK5-GGUF" and isinstance(mo, int) and mo > 16:
        errors.append("%s: JevK5 single-pass readout covers 16 option letters (A..P); max_options %r > 16" % (name, mo))
    if not isinstance(mo, int) or not 2 <= mo <= 255 or (proto == "letter-logit" and mo > 26):
        errors.append("%s: decision.max_options %r out of range" % (name, mo))
    if dec.get("max_options_status") not in ("evidence-pending", "measured"):
        errors.append("%s: decision.max_options_status must be evidence-pending|measured" % name)
    if dec.get("score_levels") != [2, 10]:
        errors.append("%s: decision.score_levels must be [2, 10]" % name)
    ro = dec.get("readout")
    if proto == "letter-logit":
        if not (isinstance(ro, dict) and isinstance(ro.get("n_probs"), int) and ro.get("n_probs") >= 1
                and isinstance(ro.get("mass_threshold"), (int, float)) and ro.get("spellings")
                and ro.get("cache_prompt") is False):
            errors.append("%s: letter-logit needs readout{n_probs,mass_threshold,spellings,cache_prompt:false}" % name)
        # G-031 / N-03: a lower-case spelling ("a", " a") collides with the
        # English article / option letters; internal/readout is upper-case only
        # and matches exact single-letter tokens, so the catalog must not
        # advertise a spelling the readout would never accept.
        for sp in (ro or {}).get("spellings") or []:
            if not (isinstance(sp, str) and re.fullmatch(r" ?[A-Z]", sp)):
                errors.append("%s: readout spelling %r must be one UPPER-CASE letter with at most one leading space (N-03)" % (name, sp))
    elif ro is not None:
        errors.append("%s: readout is letter-logit only" % name)
    th = dec.get("template_hash")
    if th is not None and not re.match(r"^sha256:[0-9a-f]{64}$", th):
        errors.append("%s: template_hash must be sha256:<64 hex> when present" % name)
# D-22: the unused tokenizer.json is not downloaded next to spm.model
nli = d["profiles"].get("decide-nli", {})
names = [f["name"] for f in nli.get("files", [])]
if "tokenizer.json" in names and "onnx/spm.model" in names:
    errors.append("decide-nli: tokenizer.json is unused next to spm.model (D-22)")
# Evidence cross-check: every decision file equals the huggingface.co re-verification
if evidence:
    ev = json.load(open(evidence))
    seen = set()
    for r in ev["files"]:
        seen.add((r["profile"], r["path"]))
        p = d["profiles"].get(r["profile"])
        f = next((x for x in (p or {}).get("files", []) if x["name"] == r["path"]), None)
        if f is None:
            # allowed only for a file deliberately dropped from the catalog
            if (r["profile"], r["path"]) != ("decide-nli", "tokenizer.json"):
                errors.append("evidence file %s/%s missing from catalog" % (r["profile"], r["path"]))
            continue
        if f["size"] != r["size"] or f["sha256"] != r["sha256"]:
            errors.append("%s/%s: catalog pin differs from huggingface.co re-verification" % (r["profile"], r["path"]))
        if p.get("hf_revision") != r["revision"]:
            errors.append("%s: revision differs from the re-verified revision" % r["profile"])
    for name, p in d["profiles"].items():
        if "decide" in p.get("capability", []):
            for f in p["files"]:
                if (name, f["name"]) not in seen:
                    errors.append("%s/%s: no re-verification evidence" % (name, f["name"]))
for e in errors:
    print("ERROR:", e)
sys.exit(1 if errors else 0)
PYEOF
EVIDENCE="${LLMCTL_ROOT}/specs/009-jev-decision-models/evidence/pin-reverify.json"
if [[ ! -f "${EVIDENCE}" ]]; then
  # honest: evidence is shipped in the repo; an archive without specs/ cannot cross-check
  assert_skip "specs/009-jev-decision-models/evidence/pin-reverify.json not present" "catalog vs huggingface.co re-verification evidence"
  EVIDENCE=""
fi
out="$(python3 "${VALIDATOR}" "${CATALOG}" ${EVIDENCE:+"${EVIDENCE}"} 2>&1)" && rc=0 || rc=$?
printf '%s\n' "${out}"
assert_eq 0 "${rc}" "decision schema contract + huggingface.co pin evidence cross-check"

# decide-max moved off 8099 (held by another program on this host) to 8097,
# everywhere the catalog advertises it.
assert_eq "8097 8097" "$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(d["ports"]["decide-max"], d["profiles"]["decide-max"]["port"])' "${CATALOG}")" "decide-max port is 8097 in ports map and profile"
assert_eq "0" "$(grep -c '8099' "${CATALOG}" || true)" "no 8099 anywhere in the catalog"
# No stale 8099 in ANY document of this repository (not a fixed list - C-22). A line may still name 8099
# when it is a statement about the MOVE (it also names 8097) or is explicitly marked <!-- historical -->.
# Vendored trees, the spec folder (design history) and the research notes are out of scope.
stale="$(
  cd "${LLMCTL_ROOT}"
  { git ls-files --cached --others --exclude-standard -- '*.md' 2>/dev/null || find . -name '*.md' -not -path './.git/*' | sed 's|^\./||'; } \
    | grep -vE '^(specs/|submodules/|constitution/|docs/research/|archive/)' \
    | while IFS= read -r f; do
        [[ -f "${f}" ]] || continue
        grep -nE 'decide-max[^|]*8099|8099[^0-9]*decide-max|8099: decide-max|P8099' "${f}" 2>/dev/null \
          | grep -v '8097' | grep -v '<!-- historical' | sed "s|^|${f}:|" || true
      done
)"
assert_eq "" "${stale}" "no document still advertises decide-max on 8099 (every tracked/unignored .md scanned)"
# the check itself can fail: a planted stale line is found by the same scan
planted="$(printf 'decide-max listens on 8099\n' | grep -nE 'decide-max[^|]*8099' | grep -v '8097' | grep -v '<!-- historical' || true)"
assert_eq "1" "$([[ -n "${planted}" ]] && echo 1 || echo 0)" "control: the stale-8099 pattern matches a planted stale line"
assert_file_contains "${LLMCTL_ROOT}/.specify/memory/constitution.md" "- 8097: decide-max" "constitution Port Map lists decide-max on 8097"

# D-26: tests must not cite the untracked out-of-tree research path (the
# bracket in the pattern keeps this file from matching its own check)
assert_eq "" "$(grep -rln '/mnt/agen[t]s' "${LLMCTL_ROOT}/tests" --include='*.sh' --include='*.py' | grep -v 'tests/red/' || true)" \
  "no test cites the out-of-tree research path (D-26)"

# Paired mutations (FR-041): the validator must FAIL for each deliberate breakage.
mutate() {  # <label> <python-expression mutating d>
  local label="$1" expr="$2" cp="${TEST_TMP}/mutant.json"
  python3 - "${CATALOG}" "${cp}" "${expr}" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
exec(sys.argv[3])
json.dump(d, open(sys.argv[2], "w"))
PYEOF
  local rc=0
  python3 "${VALIDATOR}" "${cp}" ${EVIDENCE:+"${EVIDENCE}"} >/dev/null 2>&1 || rc=$?
  assert_eq 1 "${rc}" "mutation '${label}' is rejected by the validator"
}
mutate "null one sha256" 'd["profiles"]["decide-nli"]["files"][2]["sha256"]=None'
mutate "flip one revision char" 'r=d["profiles"]["decide"]["hf_revision"]; d["profiles"]["decide"]["hf_revision"]=("0" if r[0]!="0" else "1")+r[1:]'
mutate "main as revision" 'd["profiles"]["decide"]["hf_revision"]="main"'
mutate "non-commercial licence" 'd["profiles"]["decide-tiny"]["license"]="CC-BY-NC-4.0"'
mutate "missing licence" 'del d["profiles"]["decide-pro"]["license"]'
mutate "chat capability on a decision profile" 'd["profiles"]["decide"]["capability"].append("chat")'
mutate "duplicate port" 'd["profiles"]["decide-max"]["port"]=8098; d["ports"]["decide-max"]=8098'
mutate "decide-max back on 8099" 'd["profiles"]["decide-max"]["port"]=8099; d["ports"]["decide-max"]=8099'
mutate "onnx engine with letter-logit protocol" 'd["profiles"]["decide-nli"]["decision"]["protocol"]="letter-logit"'
mutate "unknown protocol" 'd["profiles"]["decide"]["decision"]["protocol"]="magic"'
mutate "benchmark class invented" 'd["profiles"]["decide"]["provenance"]["benchmark"]["class"]="obviously-true"'
mutate "decision object removed" 'del d["profiles"]["decide-2b"]["decision"]'
mutate "size differs from huggingface.co" 'd["profiles"]["decide-tiny"]["files"][0]["size"]+=1'
mutate "sha256 differs from huggingface.co" 'f=d["profiles"]["decide-max"]["files"][0]; f["sha256"]=("0" if f["sha256"][0]!="0" else "1")+f["sha256"][1:]'
mutate "tokenizer.json re-added next to spm.model" 'd["profiles"]["decide-nli"]["files"].append({"name":"tokenizer.json","size":8656646,"sha256":"05402ffae6dd"+"0"*52,"role":"tokenizer"})'
mutate "lower-case spelling a (G-031)" 'd["profiles"]["decide"]["decision"]["readout"]["spellings"].append("a")'
mutate "lower-case spelling with a leading space (G-031)" 'd["profiles"]["decide-2b"]["decision"]["readout"]["spellings"].append(" a")'
# decide-tiny is a Jev-Style verdict model (vendor readout_config.json "readout": "verdict"); its first
# token is " yes"/" no", never a letter (evidence/live-models/decide-tiny/letter_probe.out): putting it
# back on the letter-logit protocol must be refused
mutate "Jev-Style verdict model back on letter-logit" 'dd=d["profiles"]["decide-tiny"]["decision"]; dd["protocol"]="letter-logit"; dd["readout"]=dict(d["profiles"]["decide"]["decision"]["readout"])'
mutate "jev-verdict profile without its not-servable note" 'del d["profiles"]["decide-tiny"]["decision"]["tier_note"]'
mutate "JevK5 letter-logit profile above 16 options" 'd["profiles"]["decide-max"]["decision"]["max_options"]=20'
mutate "multi-letter spelling (G-031)" 'd["profiles"]["decide-pro"]["decision"]["readout"]["spellings"].append("AB")'
mutate "profile name with a dot" 'd["profiles"]["decide.2"]=d["profiles"]["decide"]; d["ports"]["decide.2"]=8093'

# 7. Native /v1/systemone decision profiles (engine >= b11379): ports 8103-8108,
#    protocol systemone-native, and every pin (repo, revision, size, sha256) equal
#    to the admission record it was copied from
#    (specs/009-jev-decision-models/evidence/admission/ggml-org__*.json) - the
#    catalog may not drift from the evidence it cites. 8097 stays decide-max.
ADMISSION_DIR="${LLMCTL_ROOT}/specs/009-jev-decision-models/evidence/admission"
cat > "${TEST_TMP}/native_pins.py" <<'PYEOF'
import json, os, sys
cat, adm = json.load(open(sys.argv[1])), sys.argv[2]
expected = {  # profile: (port, min_tier, admission slug)
    "decide-julia":   (8103, "below-minimum", "Julia-1-GGUF"),
    "decide-kev-08b": (8104, "below-minimum", "Kev-0.8B-GGUF"),
    "decide-kev-4b":  (8105, "baseline",      "Kev-4B-GGUF"),
    "decide-kev-9b":  (8106, "workstation",   "Kev-9B-GGUF"),
    "decide-laya":    (8107, "below-minimum", "Laya-GGUF"),
    "decide-lev":     (8108, "baseline",      "lev-GGUF"),
}
errors = []
for name, (port, tier, slug) in expected.items():
    p = cat["profiles"].get(name)
    if p is None:
        errors.append("%s: missing" % name); continue
    if p["port"] != port or cat["ports"].get(name) != port: errors.append("%s: port must be %d" % (name, port))
    if p["min_tier"] != tier: errors.append("%s: min_tier must be %s" % (name, tier))
    if p["engine"] != "llama" or p["decision"]["protocol"] != "systemone-native": errors.append("%s: llama + systemone-native" % name)
    if p["decision"].get("max_options") != 255: errors.append("%s: native max_options is the hosted 255" % name)
    # encoder-class windows; the MEASURED working-set overhead is derived from evidence and checked in section 8
    want_ctx = {"decide-julia": 1024, "decide-laya": 1024, "decide-kev-08b": 2048}.get(name, 8192)
    if p["defaults"].get("ctx") != want_ctx: errors.append("%s: defaults.ctx must be %d" % (name, want_ctx))
    if p["defaults"].get("parallel") != 1 or "kv_cache_type" in p["defaults"]: errors.append("%s: native defaults: one slot, default (f16) KV" % name)
    if p.get("license") != "Apache-2.0": errors.append("%s: licence" % name)
    r = json.load(open(os.path.join(adm, "ggml-org__%s.json" % slug)))
    pin = r["pins"][0]; f = p["files"]
    if len(f) != 1 or (f[0]["name"], f[0]["size"], f[0]["sha256"]) != (pin["name"], pin["size"], pin["sha256"]): errors.append("%s: file pin differs from the admission record" % name)
    if p["hf_revision"] != r["api"]["sha"] or p["hf_repo"] != r["candidate"]["repo"]: errors.append("%s: repo/revision differ from the admission record" % name)
    if r["protocol"]["class"] != "systemone-native": errors.append("%s: admission protocol class" % name)
if cat["profiles"]["decide-max"]["port"] != 8097: errors.append("decide-max must stay on 8097")
for e in errors: print("ERROR:", e)
sys.exit(1 if errors else 0)
PYEOF
if [[ -d "${ADMISSION_DIR}" ]]; then
  out="$(python3 "${TEST_TMP}/native_pins.py" "${CATALOG}" "${ADMISSION_DIR}" 2>&1)" && rc=0 || rc=$?
  printf '%s\n' "${out}"
  assert_eq 0 "${rc}" "native profiles: ports 8103-8108, systemone-native, pins equal the admission records"
  # paired mutations: a drifted sha, a wrong port and a wrong protocol are each caught
  for m in 'f=d["profiles"]["decide-lev"]["files"][0]; f["sha256"]=("0" if f["sha256"][0]!="0" else "1")+f["sha256"][1:]' \
           'd["profiles"]["decide-laya"]["port"]=8099; d["ports"]["decide-laya"]=8099' \
           'd["profiles"]["decide-julia"]["decision"]["protocol"]="letter-logit"' \
           'd["profiles"]["decide-kev-4b"]["hf_revision"]="0"*40'; do
    cp_="${TEST_TMP}/native_mut.json"
    python3 - "${CATALOG}" "${cp_}" "${m}" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
exec(sys.argv[3])
json.dump(d, open(sys.argv[2], "w"))
PYEOF
    rc=0; python3 "${TEST_TMP}/native_pins.py" "${cp_}" "${ADMISSION_DIR}" >/dev/null 2>&1 || rc=$?
    assert_eq 1 "${rc}" "native-pin mutation is rejected: ${m:0:60}"
  done
else
  assert_skip "admission evidence not present" "native profile pins vs admission records"
fi

# 8. T138/T139: measured memory overhead + per-type maturity of EVERY decision profile.  Both blocks are DERIVED by
#    script from recorded evidence (scripts/overhead_from_memory.py, scripts/maturity_from_golden.py); the catalog must
#    equal the derivation, every evidence path must exist, and a profile that lacks the fields fails.
OVH_PY="${LLMCTL_ROOT}/scripts/overhead_from_memory.py"
MAT_PY="${LLMCTL_ROOT}/scripts/maturity_from_golden.py"
rc=0; out="$(python3 -B "${OVH_PY}" --catalog "${CATALOG}" --root "${LLMCTL_ROOT}" --check 2>&1)" || rc=$?
assert_eq 0 "${rc}" "T139: every decision profile's overhead_mb / overhead_vram_mb / window_tokens equals the derivation from its evidence"
printf '%s\n' "${out}" | grep -E '^(memory:)' || true
n_open="$(printf '%s\n' "${out}" | grep -c '^OPEN:' || true)"
echo "  info: ${n_open} decision-profile memory half(s) still unmeasured (listed as OPEN by overhead_from_memory.py --check)"
rc=0; out="$(python3 -B "${MAT_PY}" --catalog "${CATALOG}" --root "${LLMCTL_ROOT}" --check 2>&1)" || rc=$?
assert_eq 0 "${rc}" "T138: every decision profile's maturity object equals the derivation from its golden-run output"
printf '%s\n' "${out}" | grep -E '^(maturity:)' || true
cat > "${TEST_TMP}/evidence_paths.py" <<'PYEOF'
import json, os, sys
cat, root = json.load(open(sys.argv[1])), sys.argv[2]
errs = []
for name, p in cat["profiles"].items():
    if "decide" not in p.get("capability", []):
        continue
    mem, mat = p.get("memory"), p.get("maturity")
    # ram + vram always; gpu (the gpu-mode footprint, live run 2026-10-08) is optional - absent = unmeasured
    if not isinstance(mem, dict) or not {"ram", "vram"} <= set(mem) <= {"ram", "vram", "gpu"}:
        errs.append("%s: memory must hold ram and vram (and optionally gpu)" % name); continue
    g = mem.get("gpu")
    if g is not None:
        if g.get("status") in ("measured", "lower-bound"):
            if not os.path.isfile(os.path.join(root, g.get("evidence", "/nonexistent"))): errs.append("%s: memory.gpu evidence path does not exist" % name)
            need = ("gpu_vram_mb", "gpu_ram_mb") if g["status"] == "measured" else ("gpu_compute_buffer_mb",)
            if not all(isinstance(p.get("defaults", {}).get(k), int) for k in need): errs.append("%s: memory.gpu %s needs defaults.%s" % (name, g["status"], "/".join(need)))
        elif g.get("status") == "unmeasured":
            if not g.get("reason"): errs.append("%s: memory.gpu unmeasured without a reason" % name)
        else:
            errs.append("%s: memory.gpu.status %r" % (name, g.get("status")))
    for half in ("ram", "vram"):
        h = mem[half]
        if h.get("status") == "measured":
            if not os.path.isfile(os.path.join(root, h.get("evidence", "/nonexistent"))): errs.append("%s: memory.%s evidence path does not exist" % (name, half))
        elif h.get("status") == "unmeasured":
            if not h.get("reason"): errs.append("%s: memory.%s unmeasured without a reason" % (name, half))
        else:
            errs.append("%s: memory.%s.status %r" % (name, half, h.get("status")))
    dfl = p.get("defaults", {})
    if mem["ram"].get("status") == "measured" and not all(isinstance(dfl.get(k), int) for k in ("overhead_mb", "window_tokens")):
        errs.append("%s: measured RAM needs defaults.overhead_mb and defaults.window_tokens" % name)
    if mem["vram"].get("status") == "measured" and not isinstance(dfl.get("overhead_vram_mb"), int):
        errs.append("%s: measured VRAM needs defaults.overhead_vram_mb" % name)
    if not isinstance(mat, dict) or set(mat) != {"noul", "choice", "score"}:
        errs.append("%s: maturity must hold exactly noul, choice, score" % name); continue
    for t, e in mat.items():
        if e.get("status") in ("measured", "experimental"):
            if not os.path.isfile(os.path.join(root, e.get("evidence", "/nonexistent"))): errs.append("%s: maturity.%s evidence path does not exist" % (name, t))
            if not all(k in e for k in ("lower_bound", "baseline", "n")): errs.append("%s: maturity.%s lacks lower_bound/baseline/n" % (name, t))
        elif e.get("status") == "unmeasured":
            if e.get("reason") != "not yet measured": errs.append("%s: maturity.%s unmeasured needs the reason 'not yet measured'" % (name, t))
        else:
            errs.append("%s: maturity.%s.status %r" % (name, t, e.get("status")))
for e in errs: print("ERROR:", e)
sys.exit(1 if errs else 0)
PYEOF
rc=0; python3 "${TEST_TMP}/evidence_paths.py" "${CATALOG}" "${LLMCTL_ROOT}" || rc=$?
assert_eq 0 "${rc}" "T138/T139: every decision profile carries memory + maturity objects whose evidence paths exist"
# paired mutations: each must be REJECTED (script --check or the structural scan)
mut8() {  # <label> <python statement(s) mutating d> <which: ovh|mat|struct>
  local label="$1" expr="$2" which="$3" cp_="${TEST_TMP}/mut8.json" rc_=0
  python3 - "${CATALOG}" "${cp_}" "${expr}" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
exec(sys.argv[3])
json.dump(d, open(sys.argv[2], "w"), indent=2)
PYEOF
  case "${which}" in
    ovh)    python3 -B "${OVH_PY}" --catalog "${cp_}" --root "${LLMCTL_ROOT}" --check >/dev/null 2>&1 || rc_=$? ;;
    mat)    python3 -B "${MAT_PY}" --catalog "${cp_}" --root "${LLMCTL_ROOT}" --check >/dev/null 2>&1 || rc_=$? ;;
    struct) python3 "${TEST_TMP}/evidence_paths.py" "${cp_}" "${LLMCTL_ROOT}" >/dev/null 2>&1 || rc_=$? ;;
  esac
  assert_eq 1 "${rc_}" "mutation '${label}' is rejected"
}
mut8 "decide-julia loses its memory object"           'del d["profiles"]["decide-julia"]["memory"]' ovh
mut8 "decide-julia loses its memory object (structure)" 'del d["profiles"]["decide-julia"]["memory"]' struct
mut8 "hand-typed overhead_mb"                          'd["profiles"]["decide-lev"]["defaults"]["overhead_mb"]=1' ovh
mut8 "overhead_vram_mb removed from a measured profile" 'del d["profiles"]["decide-kev-08b"]["defaults"]["overhead_vram_mb"]' ovh
mut8 "window_tokens changed"                           'd["profiles"]["decide-laya"]["defaults"]["window_tokens"]=4096' ovh
mut8 "ram evidence path does not exist"                'd["profiles"]["decide-julia"]["memory"]["ram"]["evidence"]+=".missing"' ovh
mut8 "ram evidence path does not exist (structure)"    'd["profiles"]["decide-julia"]["memory"]["ram"]["evidence"]+=".missing"' struct
mut8 "unmeasured half without a reason"               'del d["profiles"]["decide-tiny"]["memory"]["ram"]["reason"]' struct
mut8 "unmeasured profile gains a number by hand"       'd["profiles"]["decide-tiny"]["defaults"]["overhead_mb"]=5' ovh
# gpu-mode half (live run 2026-10-08): derived from the evidence like the other halves
mut8 "hand-typed gpu_vram_mb (kev-4b measured 7328)"   'd["profiles"]["decide-kev-4b"]["defaults"]["gpu_vram_mb"]=3916' ovh
mut8 "gpu ctx differs from the run's --ctx-size"       'd["profiles"]["decide-kev-4b"]["memory"]["gpu"]["ctx"]=4096' ovh
mut8 "hand-typed gpu_compute_buffer_mb (kev-9b 4016)"  'd["profiles"]["decide-kev-9b"]["defaults"]["gpu_compute_buffer_mb"]=0' ovh
mut8 "gpu evidence path does not exist"                'd["profiles"]["decide-lev"]["memory"]["gpu"]["evidence"]+=".missing"' struct
mut8 "gpu evidence path does not exist (script)"       'd["profiles"]["decide-lev"]["memory"]["gpu"]["evidence"]+=".missing"' ovh
mut8 "gpu status invented"                             'd["profiles"]["decide-kev-9b"]["memory"]["gpu"]["status"]="estimated"' struct
mut8 "measured gpu half without its booking"           'del d["profiles"]["decide-kev-08b"]["defaults"]["gpu_vram_mb"]' struct
mut8 "maturity status hand-flipped to measured"        'd["profiles"]["decide-laya"]["maturity"]["score"]["status"]="measured"' mat
mut8 "maturity evidence path does not exist"           'd["profiles"]["decide-lev"]["maturity"]["noul"]["evidence"]+=".missing"' struct
mut8 "maturity evidence path does not exist (script)"  'd["profiles"]["decide-lev"]["maturity"]["noul"]["evidence"]+=".missing"' mat
mut8 "maturity object removed"                         'del d["profiles"]["decide-kev-08b"]["maturity"]' mat
mut8 "maturity object removed (structure)"             'del d["profiles"]["decide-kev-08b"]["maturity"]' struct
mut8 "maturity lower_bound hand-edited above baseline" 'd["profiles"]["decide-julia"]["maturity"]["noul"]["lower_bound"]=0.99' mat

test_finish
