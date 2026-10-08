#!/usr/bin/env bash
# admit.sh - decision-model admission gate (`llmctl admit`), spec 009 US6.
#
# Runs gates G1-G10 (specs/009-jev-decision-models/research/web-candidate-models.md
# section 4) against one Hugging Face repo and records a machine-readable
# outcome per candidate:
#
#   G1 licence allow-list      G6 protocol classification + contract files
#   G2 stable revision         G7 supply chain (no pickle / custom code)
#   G3 pinned size + sha256    G8 provenance (API author == repo owner)
#   G4 loadable by pinned engine (paper: arch / endpoint exists in tree)
#   G5 fits budgets (file cap + estimated memory)
#   G9 known-issue sweep       G10 real run (loadability, smoke, determinism,
#                                  option-order sensitivity, measured memory)
#
# Every gate yields {gate, status PASS|FAIL|SKIP|PENDING, evidence}. Final
# disposition: ADMITTED (all ten PASS) | ADMIT-CANDIDATE (no FAIL, real-run
# or sweep gates still PENDING) | USER-ONLY | REJECTED | HOLD | NOT-FOUND.
# Unknown is never PASS: an unreadable licence, an absent sha256 or an
# unclassifiable protocol fails closed.
#
# Usage: see cmd_admit below, docs/scripts/admit.md and `llmctl help`.
set -euo pipefail

_admit_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_admit_dir}/common.sh"

LLMCTL_HF_BASE="${LLMCTL_HF_BASE:-https://huggingface.co}"

_admit_spec_dir() { printf '%s' "${LLMCTL_ROOT}/specs/009-jev-decision-models/evidence/admission"; }
_admit_evidence_dir() { printf '%s' "${LLMCTL_ADMIT_EVIDENCE_DIR:-$(_admit_spec_dir)}"; }
_admit_candidates_file() { printf '%s' "${LLMCTL_ADMIT_CANDIDATES:-$(_admit_spec_dir)/candidates.tsv}"; }

# Exit codes by disposition (usage/runtime errors are 2).
_admit_rc_for() {
  case "$1" in
    ADMITTED|ADMIT-CANDIDATE) echo 0 ;;
    USER-ONLY) echo 10 ;;
    REJECTED) echo 11 ;;
    HOLD) echo 12 ;;
    NOT-FOUND) echo 13 ;;
    *) echo 2 ;;
  esac
}

_admit_slug() {
  local s="$1"
  s="${s//\//__}"
  s="${s//[^A-Za-z0-9_.-]/_}"
  printf '%s' "${s}"
}

# Fetch the model API document. Writes the body to $2, prints the HTTP status
# (0 on transport failure). HF_TOKEN is passed through a curl --config on a
# pipe so it never appears in argv, output or evidence.
_admit_fetch() {
  local repo="$1" body="$2" url code attempt=0 retry_wait="${LLMCTL_ADMIT_RETRY_WAIT:-20}"
  url="${LLMCTL_HF_BASE}/api/models/${repo}?blobs=true"
  need_cmd curl
  while :; do
    code=0
    if [[ -n "${HF_TOKEN:-}" ]]; then
      code="$(curl -sS --max-time 60 -o "${body}" -w '%{http_code}' \
        --config <(printf 'header = "Authorization: Bearer %s"\n' "${HF_TOKEN}") "${url}" 2>/dev/null)" || code=0
    else
      code="$(curl -sS --max-time 60 -o "${body}" -w '%{http_code}' "${url}" 2>/dev/null)" || code=0
    fi
    if [[ "${code}" == "429" && "${attempt}" -lt 3 ]]; then
      attempt=$((attempt+1)); sleep "${retry_wait}"; continue
    fi
    break
  done
  printf '%s' "${code}"
}

# ---------------------------------------------------------------------------
# Gate evaluator. Reads the API body + curated candidate config, emits the
# full outcome record. argv: api_body http_status cfg_json real_json|"" mode
# ---------------------------------------------------------------------------
_admit_eval() {
  python3 -I - "$@" <<'PYEOF'
import datetime, json, os, re, sys

api_path, http_status, cfg_path, real_path, mode = sys.argv[1:6]
http_status = int(http_status or 0)
cfg = json.load(open(cfg_path))
real = json.load(open(real_path)) if real_path and os.path.isfile(real_path) else None

ALLOW = [s.strip().lower() for s in os.environ.get(
    "LLMCTL_ADMIT_LICENSES",
    "apache-2.0,mit,bsd-2-clause,bsd-3-clause,cc-by-4.0,cc0-1.0,isc,unlicense").split(",") if s.strip()]
MAX_BYTES = int(os.environ.get("LLMCTL_ADMIT_MAX_BYTES", str(10 * 1024 ** 3)))
LLAMA_SRC = os.environ.get("LLMCTL_ADMIT_LLAMA_SRC") or os.path.join(os.environ.get("LLMCTL_ROOT", ""), "submodules", "llama.cpp")


def mem_budget():
    v = os.environ.get("LLMCTL_ADMIT_MEM_BYTES")
    if v:
        return int(v), "LLMCTL_ADMIT_MEM_BYTES"
    try:
        for line in open("/proc/meminfo"):
            if line.startswith("MemTotal:"):
                return int(int(line.split()[1]) * 1024 * 0.6), "60% of /proc/meminfo MemTotal (Constitution 12.6)"
    except OSError:
        pass
    return 0, "unavailable"


gates = []


def gate(gid, name, status, evidence):
    gates.append({"gate": gid, "name": name, "status": status, "evidence": evidence})


name, repo = cfg.get("name") or cfg.get("repo"), cfg.get("repo") or ""
rec = {
    "schema": "llmctl.admission/1",
    "candidate": {k: cfg.get(k) for k in ("name", "repo", "pinned", "protocol_hint", "known_issue", "name_collision", "kind")},
    "slug": cfg["slug"],
    "mode": mode,
    "retrieved_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}

api = None
if repo and repo != "-" and http_status == 200:
    try:
        api = json.load(open(api_path))
        if not isinstance(api, dict):
            api = None
    except (ValueError, OSError):
        api = None

# ---- existence verdict (Helix 11.4.270) -----------------------------------
if repo in ("", "-"):
    ex = ("UNVERIFIED", "not probed: no Hugging Face repo is named for this candidate (GitHub/PyPI-only tool); "
          "see research/web-candidate-models.md for the recorded GitHub/PyPI evidence, not re-verified by this driver")
elif http_status == 200 and api is not None:
    ex = ("VERIFIED", "HTTP 200 from %s/api/models/%s" % ("<LLMCTL_HF_BASE>", repo))
elif http_status == 200:
    ex = ("AMBIGUOUS", "HTTP 200 but the body is not a model document")
elif http_status in (401, 403):
    ex = ("AMBIGUOUS", "HTTP %d: huggingface.co answers 401 for both private and non-existent repos; cannot be told apart anonymously" % http_status)
elif http_status == 404:
    ex = ("UNVERIFIED", "HTTP 404: no such repository found at the time of the probe")
else:
    ex = ("UNVERIFIED", "no usable HTTP answer (status %s): transport failure or unexpected status" % http_status)
rec["existence"] = {"verdict": ex[0], "evidence": ex[1], "http_status": http_status}
if cfg.get("name_collision") not in (None, "", "-"):
    rec["existence"]["name_collision"] = cfg["name_collision"]

GATES = [("G1", "licence allow-list"), ("G2", "stable revision"), ("G3", "pinned size+sha256"),
         ("G4", "loadable by pinned engine"), ("G5", "fits budgets"), ("G6", "protocol classification"),
         ("G7", "supply chain"), ("G8", "provenance"), ("G9", "known-issue sweep"), ("G10", "real run")]
SUBCHECKS = ["loadability", "smoke_answer", "determinism_repeats", "option_order_sensitivity", "memory_fit_measured"]
rec.update({"api": {}, "pins": [], "protocol": {"class": "unsupported", "source": "none"},
            "needs_engine_advance": False, "tier": None})

if api is None:
    why = "not attempted: candidate does not exist or was not readable (existence %s)" % ex[0]
    for gid, gname in GATES:
        gate(gid, gname, "SKIP", why)
    rec["g10_subchecks"] = [{"check": c, "status": "SKIP", "evidence": why} for c in SUBCHECKS]
    if cfg.get("kind") == "harness":
        rec["disposition"] = "REJECTED"
        rec["reasons"] = ["no weights artifact: harness / library, not a model (kind=harness)"]
    else:
        rec["disposition"] = "NOT-FOUND"
        rec["reasons"] = ["existence %s: %s" % ex]
    rec["gates"] = gates
    json.dump(rec, sys.stdout, indent=2)
    sys.exit(0)

sibs = api.get("siblings") or []
by_name = {s.get("rfilename"): s for s in sibs}
card = api.get("cardData") or {}
tags = [t for t in (api.get("tags") or []) if isinstance(t, str)]
rec["api"] = {"id": api.get("id"), "sha": api.get("sha"), "lastModified": api.get("lastModified"),
              "author": api.get("author"), "gated": api.get("gated"), "private": api.get("private"),
              "disabled": api.get("disabled")}

# ---- G1 licence ------------------------------------------------------------
lic = card.get("license")
lics = [lic] if isinstance(lic, str) else (list(lic) if isinstance(lic, list) else [])
tag_lics = [t.split(":", 1)[1] for t in tags if t.startswith("license:")]
lics = [l.strip().lower() for l in (lics or tag_lics) if isinstance(l, str) and l.strip()]
lic_files = [n for n in by_name if re.match(r"(?i)^(licen[cs]e|copying)(\..*)?$", n or "")]
if not lics:
    gate("G1", "licence allow-list", "FAIL", "licence unknown: no cardData.license and no license:* tag (fail closed); licence files in repo: %s" % (lic_files or "none"))
else:
    bad = [l for l in lics if l not in ALLOW]
    note = "licence files in repo: %s" % (lic_files or "none")
    if tag_lics and set(l.lower() for l in tag_lics) != set(lics):
        note += "; cardData/tag licence mismatch (tags: %s)" % tag_lics
    if bad:
        gate("G1", "licence allow-list", "FAIL", "weights licence %s is not on the allow-list %s; %s" % (", ".join(bad), ALLOW, note))
    else:
        gate("G1", "licence allow-list", "PASS", "weights licence %s (SPDX, from the HF API) is on the allow-list; %s" % (", ".join(lics), note))

# ---- G2 stable revision ----------------------------------------------------
sha = api.get("sha") or ""
problems = []
if not re.fullmatch(r"[0-9a-f]{40}", sha):
    problems.append("no 40-hex commit sha")
if api.get("private"):
    problems.append("private repo")
if api.get("gated"):
    problems.append("gated repo (gated=%s)" % api.get("gated"))
if api.get("disabled"):
    problems.append("disabled repo")
if problems:
    gate("G2", "stable revision", "FAIL", "; ".join(problems))
else:
    gate("G2", "stable revision", "PASS", "immutable ref %s, lastModified %s; re-verify at release" % (sha, api.get("lastModified")))

# ---- pin selection ----------------------------------------------------------
AUX_EXT = (".json", ".model", ".txt", ".yaml", ".yml", ".md")
PICKLE_EXT = (".pt", ".pth", ".bin", ".pkl", ".pickle", ".npz", ".ckpt")
wanted = list(cfg.get("pins") or [])
auto = False
if not wanted:
    auto = True
    ggufs = sorted(n for n in by_name if n.lower().endswith(".gguf")
                   and not re.search(r"(?i)(mmproj|bf16|f16|f32)", n))
    pick = ([n for n in ggufs if "q4_k_m" in n.lower()] or [n for n in ggufs if "q8_0" in n.lower()]
            or sorted(ggufs, key=lambda n: (by_name[n].get("size") or 0))[:1])
    if pick:
        wanted = pick[:1]
    else:
        onnx = [n for n in by_name if n.lower().endswith("model.onnx")] or \
               sorted((n for n in by_name if n.lower().endswith(".onnx")), key=lambda n: (by_name[n].get("size") or 0))
        wanted = sorted(onnx)[:1] if onnx and onnx[0].lower().endswith("model.onnx") else onnx[:1]
pins, missing, nonlfs_model, nonlfs_aux = [], [], [], []
for n in wanted:
    s = by_name.get(n)
    if not s:
        missing.append(n)
        continue
    lfs = s.get("lfs") or {}
    size = lfs.get("size") or s.get("size")
    h = lfs.get("sha256") or ""
    role = "aux" if n.lower().endswith(AUX_EXT) else "model"
    pins.append({"name": n, "size": size, "sha256": h or None, "role": role})
    if not h:
        (nonlfs_aux if role == "aux" else nonlfs_model).append(n)
rec["pins"] = pins

# ---- G3 ---------------------------------------------------------------------
if not wanted:
    gate("G3", "pinned size+sha256", "FAIL", "no GGUF or ONNX file in the repo to pin (siblings: %s)" % sorted(by_name)[:8])
elif missing:
    gate("G3", "pinned size+sha256", "FAIL", "pin file(s) not in repo: %s" % missing)
elif nonlfs_model:
    gate("G3", "pinned size+sha256", "FAIL", "model file(s) without an LFS sha256 from the primary source: %s" % nonlfs_model)
elif nonlfs_aux:
    gate("G3", "pinned size+sha256", "PENDING", "model sha256 pinned from the API LFS oid (%s); aux file(s) %s are non-LFS: sha256 must be computed at pin time (not done in paper mode)" % (
        ", ".join("%s=%s..." % (p["name"], p["sha256"][:12]) for p in pins if p["sha256"]), nonlfs_aux))
else:
    gate("G3", "pinned size+sha256", "PASS", "%d file(s) with size+sha256 from the HF API LFS oid%s: %s" % (
        len(pins), " (auto-selected)" if auto else "", ", ".join("%s %s B sha256:%s..." % (p["name"], p["size"], p["sha256"][:12]) for p in pins)))

models = [p for p in pins if p["role"] == "model"]

# ---- G6 protocol -----------------------------------------------------------
g = api.get("gguf") or {}
hint = (cfg.get("protocol_hint") or "").strip()
if g.get("decision_type"):
    proto, psrc = "systemone-native", "API gguf.decision_type=%s" % g.get("decision_type")
elif hint in ("letter-logit", "systemone-native", "nli-onnx"):
    proto, psrc = hint, "curated hint (research/web-candidate-models.md; VENDOR-CLAIM / paper)"
else:
    proto, psrc = "unsupported", ("curated hint '%s'" % hint if hint else "no curated hint and no API decision signal")
rec["protocol"] = {"class": proto, "source": psrc}
has_gguf = any(p["name"].lower().endswith(".gguf") for p in models)
has_onnx = any(p["name"].lower().endswith(".onnx") for p in models)
if proto == "unsupported":
    gate("G6", "protocol classification", "FAIL", "unsupported / unclassified protocol (%s); fail closed" % psrc)
elif proto in ("letter-logit", "systemone-native") and not has_gguf:
    gate("G6", "protocol classification", "FAIL", "%s needs a GGUF pin; pinned model files: %s" % (proto, [p["name"] for p in models]))
elif proto == "nli-onnx":
    tok = [n for n in by_name if n.lower().endswith(("spm.model", "tokenizer.json"))]
    pin_tok = [p["name"] for p in pins if p["name"].lower().endswith(("spm.model", "tokenizer.json"))]
    if not has_onnx:
        gate("G6", "protocol classification", "FAIL", "nli-onnx needs an ONNX model pin")
    elif not pin_tok:
        gate("G6", "protocol classification", "FAIL", "nli-onnx needs a tokenizer file in the pin (spm.model / tokenizer.json); repo has: %s" % (tok or "none"))
    else:
        gate("G6", "protocol classification", "PASS", "nli-onnx (%s); tokenizer pinned: %s" % (psrc, pin_tok))
else:
    tmpl = "chat_template" in g
    gate("G6", "protocol classification", "PASS", "%s (%s); GGUF metadata in API: arch=%s, chat_template=%s (tokenizer is embedded in GGUF)" % (
        proto, psrc, g.get("architecture"), "yes" if tmpl else "not reported"))

# ---- G4 loadability on paper -----------------------------------------------
def read_tree():
    arch_src, server_hit = "", False
    if LLAMA_SRC and os.path.isfile(os.path.join(LLAMA_SRC, "src", "llama-arch.cpp")):
        arch_src = open(os.path.join(LLAMA_SRC, "src", "llama-arch.cpp"), errors="replace").read()
        for root, _, files in os.walk(os.path.join(LLAMA_SRC, "tools", "server")):
            for f in files:
                if f.endswith((".cpp", ".h", ".md", ".hpp")):
                    try:
                        if "systemone" in open(os.path.join(root, f), errors="replace").read():
                            server_hit = True
                    except OSError:
                        pass
            if server_hit:
                break
        return True, arch_src, server_hit
    return False, "", False


tree_ok, arch_src, server_hit = read_tree()
arch = g.get("architecture")
if proto == "unsupported":
    gate("G4", "loadable by pinned engine", "SKIP", "no supported runtime exists for an unclassified protocol (the failure is recorded at G6)")
elif proto == "nli-onnx":
    gate("G4", "loadable by pinned engine", "PASS" if has_onnx else "FAIL",
         "ONNX encoder runnable by lib/onnx_server.py (NLI contract only); real load proven only by the G10 run" if has_onnx else "no ONNX model pinned")
elif not tree_ok:
    gate("G4", "loadable by pinned engine", "PENDING", "pinned llama.cpp tree not available (LLMCTL_ADMIT_LLAMA_SRC=%r); cannot check architecture / endpoint on paper" % LLAMA_SRC)
elif not arch:
    gate("G4", "loadable by pinned engine", "PENDING", "API reports no gguf.architecture; determine at load time")
else:
    in_tree = ('"%s"' % arch) in arch_src
    if proto == "systemone-native":
        if not in_tree:
            gate("G4", "loadable by pinned engine", "FAIL", "GGUF arch '%s' is absent from the pinned tree and an engine bump is not proven to add it (custom / patched architecture)" % arch)
        elif server_hit:
            gate("G4", "loadable by pinned engine", "PASS", "arch %s and /v1/systemone both present in the pinned tree" % arch)
        else:
            rec["needs_engine_advance"] = True
            gate("G4", "loadable by pinned engine", "PENDING",
                 "pending engine advance (FR-085): pinned tree has arch %s=%s, /v1/systemone=%s; needs llama.cpp >= b11361" % (arch, "yes" if in_tree else "no", "yes" if server_hit else "no"))
    elif in_tree:
        gate("G4", "loadable by pinned engine", "PASS", "GGUF arch '%s' present in the pinned tree's llm_arch_names" % arch)
    else:
        gate("G4", "loadable by pinned engine", "FAIL", "GGUF arch '%s' not found in the pinned tree's llm_arch_names" % arch)

# ---- G5 budgets -------------------------------------------------------------
if not models:
    gate("G5", "fits budgets", "SKIP", "no model file pinned, nothing to size (the failure is recorded at G3)")
else:
    biggest = max(models, key=lambda p: p["size"] or 0)
    sz = biggest["size"] or 0
    is_onnx = biggest["name"].lower().endswith(".onnx")
    est = int(sz * 1.5 + 512 * 1024 ** 2) if is_onnx else int(sz * 1.3)
    mb, mb_src = mem_budget()
    tier = "below-minimum" if sz <= 1_000_000_000 else ("baseline" if sz <= 3_100_000_000 else "workstation")
    rec["tier"] = tier
    rec["est_memory_bytes"] = est
    ev = "largest model file %s = %d B (cap %d B), tier %s, memory ESTIMATE %d B (%s) vs budget %d B (%s)" % (
        biggest["name"], sz, MAX_BYTES, tier, est, "onnx: size*1.5+512MiB" if is_onnx else "gguf: size*1.3", mb, mb_src)
    if sz > MAX_BYTES:
        gate("G5", "fits budgets", "FAIL", "over the file-size budget: " + ev)
    elif mb and est > mb:
        gate("G5", "fits budgets", "FAIL", "estimated memory exceeds the host budget: " + ev)
    else:
        gate("G5", "fits budgets", "PASS", ev)

# ---- G7 supply chain --------------------------------------------------------
pk = [p["name"] for p in pins if p["name"].lower().endswith(PICKLE_EXT)]
repo_pk = sorted(n for n in by_name if n.lower().endswith(PICKLE_EXT) and n not in [p["name"] for p in pins])
cc = [t for t in tags if t in ("custom_code",)]
if pk:
    gate("G7", "supply chain", "FAIL", "pickle-format file(s) in the pin: %s (never loaded by llmctl)" % pk)
else:
    note = "pin has no pickle files"
    if repo_pk:
        note += "; repo also holds pickle file(s) %s which the explicit pin excludes" % repo_pk
    if cc:
        note += "; repo tagged custom_code (applies to the safetensors path, not the pinned GGUF/ONNX)"
    gate("G7", "supply chain", "PASS", note)

# ---- G8 provenance ----------------------------------------------------------
owner = repo.split("/")[0]
author = api.get("author")
if not author:
    gate("G8", "provenance", "PENDING", "API reports no author to compare with owner '%s'" % owner)
elif author.lower() != owner.lower():
    gate("G8", "provenance", "FAIL", "API author '%s' differs from repo owner '%s'" % (author, owner))
else:
    coll = cfg.get("name_collision")
    gate("G8", "provenance", "PASS", "API author '%s' == repo owner; HF-side cross-link to GitHub/PyPI not checked in paper mode%s" % (
        author, "; name collision noted: %s" % coll if coll not in (None, "", "-") else ""))

# ---- G9 known issues --------------------------------------------------------
ki = (cfg.get("known_issue") or "").strip()
if ki.startswith("block:"):
    gate("G9", "known-issue sweep", "FAIL", "blocking open issue recorded: " + ki[6:])
elif ki.startswith("none-verified:"):
    gate("G9", "known-issue sweep", "PASS", "live tracker sweep attested: " + ki[14:])
elif ki.startswith("note:"):
    gate("G9", "known-issue sweep", "PENDING", "non-blocking note recorded (%s); live tracker sweep not done by this driver" % ki[5:])
else:
    gate("G9", "known-issue sweep", "PENDING", "live upstream issue-tracker sweep not done by this driver (offline); none recorded in the research register")

# ---- G10 real run -----------------------------------------------------------
failed_before = [x["gate"] for x in gates if x["status"] == "FAIL"]
engine_pending = rec["needs_engine_advance"]
sub = []
if failed_before:
    why = "not attempted: earlier gate(s) failed: %s" % failed_before
    gate("G10", "real run", "SKIP", why)
    sub = [{"check": c, "status": "SKIP", "evidence": why} for c in SUBCHECKS]
elif real is not None:
    st = real.get("status") if real.get("status") in ("PASS", "FAIL", "SKIP", "PENDING") else "FAIL"
    gate("G10", "real run", st, real.get("evidence") or "real-run executor reported %s" % st)
    got = {s.get("check"): s for s in real.get("subchecks") or []}
    for c in SUBCHECKS:
        s = got.get(c)
        sub.append({"check": c, "status": (s or {}).get("status", "PENDING" if st == "FAIL" else "FAIL"),
                    "evidence": (s or {}).get("evidence", "executor did not report this check")})
    if st == "PASS" and any(s["status"] != "PASS" for s in sub):
        gates[-1]["status"] = "FAIL"
        gates[-1]["evidence"] += " (overridden: executor said PASS but a sub-check did not pass)"
else:
    why = ("paper-only mode: needs a real run on a host with the pinned engine" if mode == "paper-only"
           else "no real-run executor configured (LLMCTL_ADMIT_REAL_RUN unset): nothing was run")
    if engine_pending:
        why += "; also blocked on the engine advance (FR-085)"
    gate("G10", "real run", "PENDING", why)
    sub = [{"check": c, "status": "PENDING", "evidence": why} for c in SUBCHECKS]
rec["g10_subchecks"] = sub
gates.sort(key=lambda x: int(x["gate"][1:]))
rec["gates"] = gates

# ---- disposition -------------------------------------------------------------
st = {x["gate"]: x["status"] for x in gates}
fails = [x for x in gates if x["status"] == "FAIL"]
pend = [x for x in gates if x["status"] == "PENDING"]
if cfg.get("kind") == "harness":
    disp, why = "REJECTED", ["no weights artifact: harness / library, not a model (kind=harness)"]
elif st["G1"] == "FAIL":
    disp = "REJECTED"
    why = ["G1: " + [x for x in gates if x["gate"] == "G1"][0]["evidence"]]
elif st["G9"] == "FAIL":
    disp = "HOLD"
    why = ["G9: " + [x for x in gates if x["gate"] == "G9"][0]["evidence"]]
elif fails:
    disp = "USER-ONLY"
    why = ["%s: %s" % (x["gate"], x["evidence"]) for x in fails]
elif pend:
    disp = "ADMIT-CANDIDATE"
    why = ["%s PENDING: %s" % (x["gate"], x["evidence"]) for x in pend]
else:
    disp, why = "ADMITTED", ["all ten gates PASS"]
rec["disposition"] = disp
rec["reasons"] = why
json.dump(rec, sys.stdout, indent=2)
PYEOF
}

# ---------------------------------------------------------------------------
# Summary generator: SUMMARY.json + SUMMARY.md from the per-candidate files.
# ---------------------------------------------------------------------------
_admit_summarize() {
  local dir="$1"
  python3 -I - "${dir}" <<'PYEOF'
import glob, json, os, sys
d = sys.argv[1]
recs = []
for p in sorted(glob.glob(os.path.join(d, "*.json"))):
    if os.path.basename(p) == "SUMMARY.json":
        continue
    try:
        r = json.load(open(p))
    except ValueError:
        continue
    if r.get("schema") == "llmctl.admission/1":
        recs.append(r)
order = ["ADMITTED", "ADMIT-CANDIDATE", "USER-ONLY", "HOLD", "REJECTED", "NOT-FOUND"]
by_disp = {k: 0 for k in order}
by_ex = {"VERIFIED": 0, "AMBIGUOUS": 0, "UNVERIFIED": 0}
gate_fail, gate_pend = {}, {}
cands = []
for r in recs:
    by_disp[r["disposition"]] = by_disp.get(r["disposition"], 0) + 1
    by_ex[r["existence"]["verdict"]] = by_ex.get(r["existence"]["verdict"], 0) + 1
    label = r["candidate"].get("repo") or r["candidate"].get("name")
    for g in r["gates"]:
        if g["status"] == "FAIL":
            gate_fail.setdefault(g["gate"], []).append(label)
        elif g["status"] == "PENDING":
            gate_pend.setdefault(g["gate"], []).append(label)
    cands.append({"name": r["candidate"].get("name"), "repo": r["candidate"].get("repo"), "slug": r["slug"],
                  "pinned": r["candidate"].get("pinned"), "disposition": r["disposition"],
                  "existence": r["existence"]["verdict"], "protocol": r["protocol"]["class"],
                  "needs_engine_advance": r.get("needs_engine_advance", False),
                  "reasons": r["reasons"], "retrieved_at": r["retrieved_at"]})
need = []
for c in cands:
    if c["disposition"] == "ADMIT-CANDIDATE" and c["pinned"] != "yes":
        need.append({"repo": c["repo"], "protocol": c["protocol"], "needs_engine_advance": c["needs_engine_advance"],
                     "command": "LLMCTL_ADMIT_REAL_RUN=<real-run-executor> llmctl admit %s" % c["repo"]})
summary = {"schema": "llmctl.admission-summary/1", "total": len(recs), "by_disposition": by_disp,
           "by_existence_verdict": by_ex,
           "gate_failures": {k: sorted(v) for k, v in sorted(gate_fail.items())},
           "gate_pending": {k: len(v) for k, v in sorted(gate_pend.items())},
           "admit_candidates_needing_real_runs": need,
           "candidates": cands,
           "last_retrieved_at": max([c["retrieved_at"] for c in cands] or [""])}
json.dump(summary, open(os.path.join(d, "SUMMARY.json"), "w"), indent=2)
open(os.path.join(d, "SUMMARY.json"), "a").write("\n")
md = ["# Admission summary (paper checks)", "",
      "| Field | Value |", "|---|---|",
      "| Records | %d |" % len(recs),
      "| Last retrieved (UTC) | %s |" % summary["last_retrieved_at"],
      "| Method | `llmctl admit --paper-only` against the live Hugging Face API; no weights downloaded |",
      "| Gates | G1-G10 per `research/web-candidate-models.md` section 4 |", "",
      "## Dispositions", "", "| Disposition | Count |", "|---|---|"]
md += ["| %s | %d |" % (k, by_disp.get(k, 0)) for k in order]
md += ["", "## Existence verdicts (Helix 11.4.270)", "", "| Verdict | Count |", "|---|---|"]
md += ["| %s | %d |" % (k, v) for k, v in by_ex.items()]
md += ["", "## Gate failures", "", "| Gate | Failing candidates |", "|---|---|"]
md += ["| %s | %s |" % (k, ", ".join(v)) for k, v in sorted(gate_fail.items())] or ["| - | none |"]
md += ["", "## Gates still PENDING (count of candidates)", "", "| Gate | Candidates |", "|---|---|"]
md += ["| %s | %d |" % (k, len(v)) for k, v in sorted(gate_pend.items())] or ["| - | none |"]
md += ["", "## ADMIT-CANDIDATEs (not pinned) needing real runs", ""]
if need:
    md += ["| Repo | Protocol | Engine advance needed | Command |", "|---|---|---|---|"]
    md += ["| %s | %s | %s | `%s` |" % (n["repo"], n["protocol"], "yes" if n["needs_engine_advance"] else "no", n["command"]) for n in need]
else:
    md += ["none"]
md += ["", "## All candidates", "", "| Candidate | Repo | Disposition | Existence | Protocol | First reason |", "|---|---|---|---|---|---|"]
for c in cands:
    reason = (c["reasons"][0] if c["reasons"] else "").replace("|", "/")[:150]
    md.append("| %s | %s | %s | %s | %s | %s |" % (c["name"], c["repo"], c["disposition"], c["existence"], c["protocol"], reason))
md += ["", "## Honest gaps (what this paper run does NOT establish)", "",
       "- G10 (loadability, smoke answer, determinism repeats, option-order sensitivity, measured memory) is PENDING for every non-rejected candidate: no weights were downloaded and nothing was run. A paper pass is not admission (FR-007).",
       "- No real-run executor script exists yet; `LLMCTL_ADMIT_REAL_RUN` must point at one (it is called as `<exe> <repo> <record.json>` and must print the JSON documented in docs/scripts/admit.md). The commands above are therefore the intended invocation, not something that can be run today.",
       "- The protocol class comes from the API's `gguf.decision_type` when present and otherwise from the curated hint in candidates.tsv (VENDOR-CLAIM / paper); an unhinted candidate is `unsupported` (fail closed), so USER-ONLY here can mean 'no hint was curated', not 'proven unusable'.",
       "- G9 is PENDING everywhere except the recorded blocking issue: upstream issue trackers were not queried by the driver (offline logic); the notes come from research/web-candidate-models.md.",
       "- G3: non-LFS auxiliary files have no sha256 in the API; they stay PENDING until a pin step computes it.",
       "- Non-HF names (GitHub/PyPI tools) were not probed; existence is UNVERIFIED by this driver and their REJECTED disposition rests on the research register (no weights artifact).",
       "- G4 for native-decision models is PENDING the engine advance (FR-085): the pinned tree has the architectures but not `/v1/systemone`.",
       "- Differences from the research register are possible because the gates are mechanical: e.g. repos holding only adapters or safetensors come out USER-ONLY here where the register says REJECT."]
open(os.path.join(d, "SUMMARY.md"), "w").write("\n".join(md) + "\n")
PYEOF
}

# Look up a candidates.tsv row (by hf_repo or name) into _ADMIT_ROW_* globals.
_admit_lookup() {
  local key="$1" file name hf pinned pins proto ki coll kind
  file="$(_admit_candidates_file)"
  _ADMIT_ROW_FOUND=0
  [[ -f "${file}" ]] || return 0
  while IFS=$'\t' read -r name hf pinned pins proto ki coll kind || [[ -n "${name:-}" ]]; do
    [[ -z "${name}" || "${name}" == "name" || "${name}" == \#* ]] && continue
    if [[ "${hf}" == "${key}" || "${name}" == "${key}" ]]; then
      _ADMIT_ROW_FOUND=1
      _ADMIT_ROW_NAME="${name}"; _ADMIT_ROW_REPO="${hf}"; _ADMIT_ROW_PINNED="${pinned}"
      _ADMIT_ROW_PINS="${pins}"; _ADMIT_ROW_PROTO="${proto}"; _ADMIT_ROW_KI="${ki}"
      _ADMIT_ROW_COLL="${coll}"; _ADMIT_ROW_KIND="${kind}"
      return 0
    fi
  done <"${file}"
}

# Run all gates for one candidate and write/print its record.
# args: repo name pinned pins(comma|auto|-) proto known_issue collision kind mode json(0|1) write(0|1)
#
# The work runs in a SUBSHELL whose EXIT trap removes the scratch directory: `die` (exit) from inside
# the evaluation used to skip a RETURN trap and leak the directory, and a trap string with the path
# embedded in single quotes broke when TMPDIR held a quote (C-19). The trap references a variable,
# never an interpolated path, and the parent removes the directory again on every normal return.
_admit_one() {
  local tmp rc=0
  tmp="$(mktemp -d)" || die "admit: cannot create a scratch directory"
  (
    _ADMIT_SCRATCH="${tmp}"
    trap 'rm -rf -- "${_ADMIT_SCRATCH}"' EXIT
    _admit_one_body "${tmp}" "$@"
  ) || rc=$?
  rm -rf -- "${tmp}"
  return "${rc}"
}

# _admit_one_body <scratch-dir> <the _admit_one arguments...>
_admit_one_body() {
  local tmp="$1"; shift
  local repo="$1" name="$2" pinned="$3" pins="$4" proto="$5" ki="$6" coll="$7" kind="$8" \
        mode="$9" want_json="${10}" write="${11}"
  local slug status disp rc evdir
  if [[ -z "${name}" || "${name}" == "-" ]]; then name="${repo}"; fi
  if [[ "${repo}" == "-" ]]; then slug="$(_admit_slug "${name}")"; else slug="$(_admit_slug "${repo}")"; fi
  : >"${tmp}/body"
  status=0
  if [[ "${repo}" != "-" ]]; then status="$(_admit_fetch "${repo}" "${tmp}/body")"; fi
  python3 -I - "${tmp}/cfg" "${name}" "${repo}" "${slug}" "${pinned}" "${pins}" "${proto}" "${ki}" "${coll}" "${kind}" <<'PYEOF'
import json, sys
p, name, repo, slug, pinned, pins, proto, ki, coll, kind = sys.argv[1:11]
pl = [] if pins in ("", "-", "auto") else [x for x in pins.split(",") if x]
json.dump({"name": name, "repo": repo, "slug": slug, "pinned": pinned,
           "pins": pl, "protocol_hint": "" if proto == "-" else proto,
           "known_issue": "" if ki == "-" else ki, "name_collision": "" if coll == "-" else coll,
           "kind": "weights" if kind in ("", "-") else kind}, open(p, "w"))
PYEOF
  _admit_eval "${tmp}/body" "${status}" "${tmp}/cfg" "" "${mode}" >"${tmp}/rec" ||
    die "admission evaluation failed for ${repo}"
  disp="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["disposition"])' "${tmp}/rec")"
  # Real run only for a candidate that passed every paper gate, and only
  # when an executor is configured; the executor result is evaluated by the
  # same gate code (second pass) - never trusted blindly.
  if [[ "${mode}" != "paper-only" && -n "${LLMCTL_ADMIT_REAL_RUN:-}" && "${disp}" == "ADMIT-CANDIDATE" ]]; then
    if [[ -x "${LLMCTL_ADMIT_REAL_RUN}" ]]; then
      if "${LLMCTL_ADMIT_REAL_RUN}" "${repo}" "${tmp}/rec" >"${tmp}/real" 2>"${tmp}/real.err"; then :; else
        printf '{"status":"FAIL","evidence":"real-run executor exited non-zero: %s"}\n' \
          "$(head -c 200 "${tmp}/real.err" | tr -d '"\\\n')" >"${tmp}/real"
      fi
    else
      printf '{"status":"FAIL","evidence":"LLMCTL_ADMIT_REAL_RUN is set but not an executable file"}\n' >"${tmp}/real"
    fi
    _admit_eval "${tmp}/body" "${status}" "${tmp}/cfg" "${tmp}/real" "${mode}" >"${tmp}/rec" ||
      die "admission evaluation failed for ${repo}"
    disp="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["disposition"])' "${tmp}/rec")"
  fi
  if [[ "${write}" == "1" ]]; then
    evdir="$(_admit_evidence_dir)"
    mkdir -p "${evdir}"
    cp "${tmp}/rec" "${evdir}/${slug}.json.tmp" && mv "${evdir}/${slug}.json.tmp" "${evdir}/${slug}.json"
  fi
  if [[ "${want_json}" == "1" ]]; then
    cat "${tmp}/rec"; printf '\n'
  else
    python3 -I - "${tmp}/rec" <<'PYEOF'
import json, sys
r = json.load(open(sys.argv[1]))
print("admit %s  [%s]  existence=%s  protocol=%s" % (r["candidate"]["name"] if r["candidate"]["repo"] in ("", "-") else r["candidate"]["repo"], r["disposition"], r["existence"]["verdict"], r["protocol"]["class"]))
for g in r["gates"]:
    print("  %-4s %-8s %s" % (g["gate"], g["status"], g["evidence"][:160]))
for x in r["reasons"]:
    print("  reason: " + x[:200])
PYEOF
  fi
  rc="$(_admit_rc_for "${disp}")"
  return "${rc}"
}

_admit_usage() {
  cat >&2 <<'EOF'
usage: llmctl admit <hf-repo> [--paper-only] [--json] [--protocol P] [--pin FILE]...
                       [--known-issue TEXT] [--kind weights|harness] [--name N]
                       [--no-write]
       llmctl admit --all [--paper-only] [--candidates FILE]
       llmctl admit --summarize
exit codes: 0 ADMITTED/ADMIT-CANDIDATE, 10 USER-ONLY, 11 REJECTED, 12 HOLD,
            13 NOT-FOUND, 2 usage/runtime error
EOF
}

cmd_admit() {
  local repo="" paper=0 want_json=0 all=0 summarize=0 write=1
  local proto="" ki="" kind="" name="" cand_file="" pins_arg=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --paper-only) paper=1 ;;
      --json) want_json=1 ;;
      --all) all=1 ;;
      --summarize) summarize=1 ;;
      --no-write) write=0 ;;
      --protocol) [[ $# -ge 2 ]] || { _admit_usage; return 2; }; proto="$2"; shift ;;
      --pin) [[ $# -ge 2 ]] || { _admit_usage; return 2; }; pins_arg+=("$2"); shift ;;
      --known-issue) [[ $# -ge 2 ]] || { _admit_usage; return 2; }; ki="$2"; shift ;;
      --kind) [[ $# -ge 2 ]] || { _admit_usage; return 2; }; kind="$2"; shift ;;
      --name) [[ $# -ge 2 ]] || { _admit_usage; return 2; }; name="$2"; shift ;;
      --candidates) [[ $# -ge 2 ]] || { _admit_usage; return 2; }; cand_file="$2"; shift ;;
      -h|--help) _admit_usage; return 2 ;;
      -*) err "admit: unknown option: $1"; _admit_usage; return 2 ;;
      *) [[ -z "${repo}" ]] || { err "admit: more than one repo given"; return 2; }; repo="$1" ;;
    esac
    shift
  done
  [[ -z "${cand_file}" ]] || LLMCTL_ADMIT_CANDIDATES="${cand_file}"
  local mode="full"; [[ "${paper}" == "1" ]] && mode="paper-only"

  if [[ "${summarize}" == "1" ]]; then
    _admit_summarize "$(_admit_evidence_dir)"
    info "wrote $(_admit_evidence_dir)/SUMMARY.json and SUMMARY.md"
    return 0
  fi

  if [[ "${all}" == "1" ]]; then
    local file delay n=0 first=1
    file="$(_admit_candidates_file)"
    [[ -f "${file}" ]] || { err "admit: candidates file not found: ${file}"; return 2; }
    delay="${LLMCTL_ADMIT_DELAY:-1}"
    local cname chf cpinned cpins cproto cki ccoll ckind
    while IFS=$'\t' read -r cname chf cpinned cpins cproto cki ccoll ckind || [[ -n "${cname:-}" ]]; do
      [[ -z "${cname}" || "${cname}" == "name" || "${cname}" == \#* ]] && continue
      if [[ "${first}" == "0" && "${chf}" != "-" ]]; then sleep "${delay}"; fi
      [[ "${chf}" == "-" ]] || first=0
      local rc=0
      _admit_one "${chf}" "${cname}" "${cpinned}" "${cpins}" "${cproto}" "${cki}" "${ccoll}" "${ckind}" \
        "${mode}" 0 1 </dev/null || rc=$?
      case "${rc}" in 0|10|11|12|13) ;; *) err "admit: evaluation error (rc ${rc}) for ${chf}"; return 2 ;; esac
      n=$((n+1))
    done <"${file}"
    _admit_summarize "$(_admit_evidence_dir)"
    info "admitted-gate run complete: ${n} candidates; summary in $(_admit_evidence_dir)"
    return 0
  fi

  [[ -n "${repo}" ]] || { _admit_usage; return 2; }
  need_cmd python3
  _admit_lookup "${repo}"
  local d_name="${name}" d_pinned="no" d_pins="auto" d_proto="${proto}" d_ki="${ki}" d_coll="-" d_kind="${kind}"
  if [[ "${_ADMIT_ROW_FOUND:-0}" == "1" ]]; then
    d_name="${name:-${_ADMIT_ROW_NAME}}"; d_pinned="${_ADMIT_ROW_PINNED}"; d_pins="${_ADMIT_ROW_PINS}"
    d_proto="${proto:-${_ADMIT_ROW_PROTO}}"; d_ki="${ki:-${_ADMIT_ROW_KI}}"; d_coll="${_ADMIT_ROW_COLL}"
    d_kind="${kind:-${_ADMIT_ROW_KIND}}"
  fi
  if [[ ${#pins_arg[@]} -gt 0 ]]; then
    d_pins="$(IFS=,; printf '%s' "${pins_arg[*]}")"
  fi
  local rc=0
  _admit_one "${repo}" "${d_name}" "${d_pinned}" "${d_pins}" "${d_proto:--}" "${d_ki:--}" "${d_coll}" "${d_kind:--}" \
    "${mode}" "${want_json}" "${write}" || rc=$?
  return "${rc}"
}
