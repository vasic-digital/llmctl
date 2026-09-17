#!/usr/bin/env bash
# catalog.sh - query and planning logic over models/catalog.json.
#
# The planner is intentionally simple and conservative:
#   * RAM budget   = available RAM - 4 GiB headroom
#   * VRAM budget  = total VRAM  - 15% headroom
#   * KV cache     = ctx_tokens * parallel_slots / 8 MiB  (conservative upper
#                    estimate for f16 KV; documented in docs/architecture.md)
#   * GGUF models  = "gpu" mode (full offload, ngl from catalog defaults) when
#                    model+KV fits the VRAM budget, else "cpu" mode (ngl=0)
#                    when model+KV fits the RAM budget, else the profile does
#                    not fit this host.
#   * Colibri models map weights from NVMe: VRAM need is 0, RAM need is a
#     fixed conservative reservation, storage need is the full repo size.
#   * Host tiers gate profiles via each profile's min_tier:
#       below-minimum < baseline < workstation < datacenter
#
# Per-profile port override (opt-in, host-local):
#   models/catalog.json's "port" field is meant to stay portable/host-
#   independent - it is checked in and shared across every host that runs
#   this catalog. When a catalog profile's default port collides with an
#   unrelated process already bound to it on ONE specific host, that is a
#   host-local fact, never a reason to edit the shared catalog file. Set
#   LLMCTL_PORT_<PROFILE> (profile name upper-cased, '-' -> '_', e.g.
#   LLMCTL_PORT_FAST=18080 for the "fast" profile) to rebind JUST that
#   profile to a free port on JUST this host, following the same
#   ${VAR:-default}-style opt-in-env-var convention as LLMCTL_LLAMA_SERVER
#   / LLMCTL_COLI_BIN. Consulted by catalog_port() (display) and
#   catalog_plan_json() (the actual launch-port every scheduler operation
#   uses) - see catalog_port_override_env_name() below for the exact name
#   derivation.
set -euo pipefail

_cat_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_cat_dir}/common.sh"

catalog_check() {
  [[ -r "${LLMCTL_CATALOG}" ]] || die "catalog not found: ${LLMCTL_CATALOG}"
  json_query "${LLMCTL_CATALOG}" 'd' >/dev/null || die "catalog is not valid JSON: ${LLMCTL_CATALOG}"
}

catalog_profiles() {
  catalog_check
  json_query "${LLMCTL_CATALOG}" 'sorted(d["profiles"].keys())'
}

catalog_exists() {
  catalog_check
  json_query "${LLMCTL_CATALOG}" "'$1' in d[\"profiles\"]" >/dev/null 2>&1
}

catalog_field() {
  # catalog_field <profile> <field> [default]
  local p="$1" f="$2" def="${3:-}"
  catalog_check
  catalog_exists "$p" || die "unknown profile: $p (see: llmctl models list)"
  local out
  out="$(json_query "${LLMCTL_CATALOG}" "d[\"profiles\"][\"$p\"].get(\"$f\")")" || {
    [[ -n "${def}" ]] && { echo "${def}"; return 0; }
    die "catalog profile '$p' has no field '$f'"
  }
  if [[ -z "${out}" && -n "${def}" ]]; then echo "${def}"; else echo "${out}"; fi
}

# catalog_port_override_env_name <profile> -> LLMCTL_PORT_<PROFILE>
# Profile names are lowercase snake/kebab (e.g. "ws-dense-32b"); this maps
# them to the upper-snake env-var suffix ("WS_DENSE_32B"). tr's two
# argument character classes ([:lower:]- and [:upper:]_) are the same
# length (27: 26 letters + one separator), so each maps position-for-
# position: a-z -> A-Z and '-' -> '_'. Exposed as its own function (rather
# than inlined) so both catalog_port() and any future caller derive the
# override name identically - one source of truth for the naming rule.
catalog_port_override_env_name() {
  printf 'LLMCTL_PORT_%s' "$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')"
}

catalog_engine()     { catalog_field "$1" engine; }
catalog_port() {
  # Opt-in per-profile override (see the file-header comment above) takes
  # precedence over the catalog's fixed value; still profile-validated
  # (catalog_check + catalog_exists) exactly as the no-override path is via
  # catalog_field, so an override for an unknown profile still dies with
  # the same "unknown profile" message rather than silently returning the
  # override for a profile that does not exist.
  local p="$1" override_var override
  override_var="$(catalog_port_override_env_name "${p}")"
  override="${!override_var:-}"
  if [[ -n "${override}" ]]; then
    catalog_check
    catalog_exists "${p}" || die "unknown profile: ${p} (see: llmctl models list)"
    printf '%s\n' "${override}"
  else
    catalog_field "${p}" port
  fi
}
catalog_min_tier()   { catalog_field "$1" min_tier baseline; }
catalog_desc()       { catalog_field "$1" desc ""; }
catalog_hf_repo()    { catalog_field "$1" hf_repo; }
catalog_capability() { catalog_check; json_query "${LLMCTL_CATALOG}" "' '.join(d[\"profiles\"][\"$1\"][\"capability\"])"; }

catalog_default() {
  # catalog_default <profile> <key> <fallback>
  local p="$1" k="$2" fb="$3"
  catalog_check
  local out
  out="$(json_query "${LLMCTL_CATALOG}" "d[\"profiles\"][\"$p\"].get(\"defaults\",{}).get(\"$k\")" 2>/dev/null || true)"
  echo "${out:-${fb}}"
}

# Lines of "name|size_bytes|sha256|role" (sha256 may be empty).
catalog_files() {
  local p="$1"
  catalog_check
  catalog_exists "$p" || die "unknown profile: $p"
  json_query "${LLMCTL_CATALOG}" \
    "[\"%s|%s|%s|%s\" % (f[\"name\"], f.get(\"size\") or 0, f.get(\"sha256\") or \"\", f.get(\"role\") or \"model\") for f in d[\"profiles\"][\"$p\"][\"files\"]]"
}

catalog_total_size_mb() {
  local p="$1"
  catalog_check
  json_query "${LLMCTL_CATALOG}" "sum((f.get(\"size\") or 0) for f in d[\"profiles\"][\"$p\"][\"files\"]) // 1048576"
}

# --- Tier classification ----------------------------------------------------
# Exposed as its own function so tests can pin the rules, AND so
# catalog_plan_json (below) has a single source of truth for the thresholds
# instead of a hand-duplicated copy. Uses a real python script (not
# json_stdin's eval()-based helper, which can only evaluate a single
# expression and cannot run this function's if/elif/else - that mismatch
# is exactly why this function was previously unwired: calling it raised a
# SyntaxError, discovered via Constitution §11.4.124 investigation).
catalog_classify_tier() {
  # reads hardware JSON on stdin. MUST use `python3 -c '<script>'` (script as
  # an argument), NOT `python3 - <<HEREDOC` - a heredoc attached to `python3 -`
  # redirects stdin to feed the SCRIPT ITSELF to the interpreter, which
  # collides with the script's own `json.load(sys.stdin)` (stdin would
  # already be at EOF by the time the script runs). This was the second bug
  # found while wiring this function in (the first was the eval()/exec()
  # mismatch fixed above this function's history).
  need_cmd python3
  python3 -c '
import json, sys
d = json.load(sys.stdin)
cores = d["cpu"]["cores"]
ram = d["memory"]["total_mb"]
vram = d.get("gpu_total_vram_mb", 0)
free = d["storage"]["free_mb"]
if cores >= 32 and ram >= 98304 and free >= 409600:
    print("datacenter")
elif cores >= 24 or ram >= 65536 or vram >= 20480:
    print("workstation")
elif cores >= 8 and ram >= 32768:
    print("baseline")
else:
    print("below-minimum")
'
}

catalog_tier_rank() {
  case "$1" in
    below-minimum) echo 0 ;;
    baseline)      echo 1 ;;
    workstation)   echo 2 ;;
    datacenter)    echo 3 ;;
    *) return 1 ;;
  esac
}

# --- Planner ----------------------------------------------------------------
# catalog_plan_json   (hardware JSON document on stdin)
catalog_plan_json() {
  catalog_check
  need_cmd python3
  local hw_doc tier
  hw_doc="$(cat)"
  tier="$(printf '%s' "${hw_doc}" | catalog_classify_tier)"
  LLMCTL_HW_DOC="${hw_doc}" LLMCTL_TIER="${tier}" python3 - "${LLMCTL_CATALOG}" <<'PYEOF'
import json, math, os, sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    catalog = json.load(fh)
hw = json.loads(os.environ["LLMCTL_HW_DOC"])

cores = hw["cpu"]["cores"]
ram_total = hw["memory"]["total_mb"]
ram_avail = hw["memory"]["available_mb"]
vram_total = hw.get("gpu_total_vram_mb", 0)
storage_free = hw["storage"]["free_mb"]

# Tier computed by catalog_classify_tier (bash) - the single source of
# truth for tier thresholds; no longer duplicated here.
tier = os.environ["LLMCTL_TIER"]
tier_rank = {"below-minimum": 0, "baseline": 1, "workstation": 2, "datacenter": 3}

ram_budget = max(0, ram_avail - 4096)          # 4 GiB RAM headroom
vram_budget = int(vram_total * 0.85)           # 15% VRAM headroom

def kv_mb(ctx, parallel):
    # Conservative f16 KV estimate: 1/8 MiB per token-slot.
    return int(math.ceil(ctx * parallel / 8.0))

def resolve_port(name, default_port):
    """Per-profile port override (see the file-header comment): opt-in
    LLMCTL_PORT_<PROFILE> env var, same naming rule as the bash-side
    catalog_port_override_env_name() (upper-cased profile name, '-' ->
    '_'). This is the function every actual launch (llmctl start/enable/
    switch/auto, via sched_build_launch's --port) resolves its port
    through - overriding only catalog_port() (a display-only getter)
    would NOT change what the scheduler actually binds to.
    """
    env_name = "LLMCTL_PORT_" + name.upper().replace("-", "_")
    override = os.environ.get(env_name)
    if not override:
        return default_port
    try:
        return int(override)
    except ValueError:
        sys.stderr.write(
            "catalog_plan_json: %s=%r is not a valid port number\n" % (env_name, override)
        )
        sys.exit(1)

def footprint(name, p):
    """-> dict(mode, ram_mb, vram_mb, storage_mb, fits) or None when unfit."""
    size_mb = sum((f.get("size") or 0) for f in p["files"]) // 1048576
    dfl = p.get("defaults", {})
    ctx = int(dfl.get("ctx", 8192))
    par = int(dfl.get("parallel", 1))
    if p["engine"] == "colibri":
        # Weights are memory-mapped from NVMe; RAM is page cache + working set.
        ram_need = 24576 if size_mb >= 102400 else 8192
        ok = ram_need <= ram_budget and size_mb * 11 // 10 <= storage_free
        return {"mode": "colibri", "ram_mb": ram_need, "vram_mb": 0,
                "storage_mb": size_mb, "ctx": ctx, "ngl": 0, "parallel": par,
                "flash_attn": "off", "fits": ok}
    kv = kv_mb(ctx, par)
    if vram_budget > 0 and size_mb + kv <= vram_budget and 2048 <= ram_budget:
        return {"mode": "gpu", "ram_mb": 2048, "vram_mb": size_mb + kv,
                "storage_mb": size_mb, "ctx": ctx,
                "ngl": int(dfl.get("ngl", 99)), "parallel": par,
                "flash_attn": dfl.get("flash_attn", "auto"), "fits": True}
    if size_mb + kv <= ram_budget:
        return {"mode": "cpu", "ram_mb": size_mb + kv, "vram_mb": 0,
                "storage_mb": size_mb, "ctx": ctx, "ngl": 0, "parallel": par,
                "flash_attn": dfl.get("flash_attn", "auto"), "fits": True}
    return {"mode": "none", "ram_mb": size_mb + kv, "vram_mb": 0,
            "storage_mb": size_mb, "ctx": ctx, "ngl": 0, "parallel": par,
            "flash_attn": dfl.get("flash_attn", "auto"), "fits": False}

profiles = {}
for name in sorted(catalog["profiles"].keys()):
    p = catalog["profiles"][name]
    fp = footprint(name, p)
    min_tier = p.get("min_tier", "baseline")
    tier_ok = tier_rank[tier] >= tier_rank.get(min_tier, 1)
    fp.update({"port": resolve_port(name, p["port"]), "engine": p["engine"],
               "capability": p["capability"], "min_tier": min_tier,
               "tier_ok": tier_ok, "recommended": bool(fp["fits"] and tier_ok)})
    profiles[name] = fp

# Co-residency groups: greedy bin-packing over the recommended profiles in
# port order. A group is a set of profiles whose combined reservations fit the
# budgets at the same time.
groups = []
current = {"members": [], "ram": 0, "vram": 0, "storage": 0}
for name in sorted(profiles, key=lambda n: profiles[n]["port"]):
    fp = profiles[name]
    if not fp["recommended"]:
        continue
    if (current["ram"] + fp["ram_mb"] <= ram_budget
            and current["vram"] + fp["vram_mb"] <= vram_budget
            and current["storage"] + fp["storage_mb"] <= storage_free):
        current["members"].append(name)
        current["ram"] += fp["ram_mb"]
        current["vram"] += fp["vram_mb"]
        current["storage"] += fp["storage_mb"]
    else:
        if current["members"]:
            groups.append(current)
        current = {"members": [name], "ram": fp["ram_mb"],
                   "vram": fp["vram_mb"], "storage": fp["storage_mb"]}
if current["members"]:
    groups.append(current)

out = {
    "tier": tier,
    "budgets": {"ram_mb": ram_budget, "vram_mb": vram_budget,
                "storage_free_mb": storage_free},
    "profiles": profiles,
    "recommended": sorted([n for n, f in profiles.items() if f["recommended"]],
                          key=lambda n: profiles[n]["port"]),
    "coresidency_groups": [
        {"profiles": g["members"], "ram_mb": g["ram"], "vram_mb": g["vram"],
         "storage_mb": g["storage"]} for g in groups
    ],
}
json.dump(out, sys.stdout, indent=2)
sys.stdout.write("\n")
PYEOF
}

# Human-readable plan rendering (plan JSON on stdin).
catalog_plan_human() {
  need_cmd python3
  local plan_doc
  plan_doc="$(cat)"
  LLMCTL_PLAN_DOC="${plan_doc}" python3 - <<'PYEOF'
import json, os, sys
plan = json.loads(os.environ["LLMCTL_PLAN_DOC"])
b = plan["budgets"]
print("Host tier:   %s" % plan["tier"])
print("Budgets:     RAM %d MiB (avail - 4GiB), VRAM %d MiB (total - 15%%), storage %d MiB free"
      % (b["ram_mb"], b["vram_mb"], b["storage_free_mb"]))
print("")
print("%-16s %-6s %-9s %-8s %-8s %-6s %-5s %-4s %s" %
      ("profile", "port", "verdict", "mode", "RAM MiB", "VRAM", "ctx", "ngl", "why"))
for name in sorted(plan["profiles"], key=lambda n: plan["profiles"][n]["port"]):
    p = plan["profiles"][name]
    if p["recommended"]:
        verdict, why = "FITS", "recommended"
    elif not p["tier_ok"]:
        verdict, why = "GATED", "needs min_tier=%s" % p["min_tier"]
    else:
        verdict, why = "NO-FIT", "footprint exceeds RAM and VRAM budgets"
    print("%-16s %-6s %-9s %-8s %-8s %-6s %-5s %-4s %s" %
          (name, p["port"], verdict, p["mode"], p["ram_mb"], p["vram_mb"],
           p["ctx"], p["ngl"], why))
print("")
groups = plan["coresidency_groups"]
if groups:
    print("Co-residency groups (profiles that can run at the same time):")
    for i, g in enumerate(groups, 1):
        print("  group %d: %s  (RAM %d MiB, VRAM %d MiB)"
              % (i, ", ".join(g["profiles"]), g["ram_mb"], g["vram_mb"]))
else:
    print("Co-residency groups: none (no profile fits this host)")
PYEOF
}

# Footprint for a single profile out of a plan document.
# Usage: plan_get <plan-json-file-or-stdin... keep simple: reads plan JSON on stdin> <profile> <field>
catalog_plan_get() {
  local profile="$1" field="$2"
  json_stdin "d[\"profiles\"][\"$profile\"][\"$field\"]"
}
