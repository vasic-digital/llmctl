#!/usr/bin/env bash
# catalog.sh - query and planning logic over models/catalog.json.
#
# The planner is intentionally simple and conservative:
#   * RAM budget   = available RAM - 4 GiB headroom
#   * VRAM budget  = REAL FREE VRAM (live nvidia-smi/amdgpu measurement) -
#                    15% headroom, when a live free-VRAM reading exists;
#                    falls back to total VRAM - 15% headroom only when it
#                    does not (old hw-doc fixture, or a GPU path with no
#                    verified free-memory counter - see hardware.sh). Fixed
#                    2026-10-03: the total-based estimate alone let a
#                    profile report "fits" while something else already
#                    held several GiB of the same card, causing a real
#                    CUDA OOM at launch the catalog could not predict.
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
#
# Per-profile bind-host override (opt-in, host-local):
#   common.sh's LLMCTL_BIND_HOST sets the GLOBAL default engine bind
#   address (0.0.0.0, LAN-accessible, per operator mandate - see that
#   file's header comment for the full security-trade-off disclosure).
#   catalog.json has no "host" field (bind address is a deployment/network
#   concern, not a portable model-catalog fact), so there is nothing to
#   override IN the catalog the way LLMCTL_PORT_<PROFILE> overrides a
#   catalog "port" value. Instead, LLMCTL_BIND_HOST_<PROFILE> (same
#   profile-name upper-cased, '-' -> '_' derivation as
#   catalog_port_override_env_name, e.g. LLMCTL_BIND_HOST_FAST=127.0.0.1)
#   overrides the GLOBAL LLMCTL_BIND_HOST default for JUST that profile on
#   JUST this host - e.g. to lock one sensitive profile back to
#   localhost-only while the rest of the fleet stays LAN-accessible.
#   Consulted by catalog_bind_host() - the actual host every
#   sched_build_launch call (llama AND colibri engine paths) resolves its
#   --host flag through - see catalog_bind_host_override_env_name() below
#   for the exact name derivation.
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

# catalog_ctx_override_env_name <profile> -> LLMCTL_CTX_<PROFILE>
# Same name-derivation rule as catalog_port_override_env_name() above - the
# bash-side half of the ctx-override mechanism, matching resolve_ctx()
# (catalog_plan_json's Python, the functional path) for naming consistency.
catalog_ctx_override_env_name() {
  printf 'LLMCTL_CTX_%s' "$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')"
}

# catalog_kv_type_override_env_name <profile> -> LLMCTL_KVTYPE_<PROFILE>
# Same name-derivation rule, bash-side half of resolve_kv_type()'s override.
catalog_kv_type_override_env_name() {
  printf 'LLMCTL_KVTYPE_%s' "$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')"
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
  if [[ -n "${override}" && "${override}" != "auto" ]]; then
    catalog_check
    catalog_exists "${p}" || die "unknown profile: ${p} (see: llmctl models list)"
    printf '%s\n' "${override}"
  else
    catalog_field "${p}" port
  fi
}
# catalog_bind_host_override_env_name <profile> -> LLMCTL_BIND_HOST_<PROFILE>
# Identical name-derivation rule as catalog_port_override_env_name() above
# (see that function's comment for why tr's two character classes map
# position-for-position); kept as its own function for the same reason -
# one source of truth for the override-name derivation, used by both
# catalog_bind_host() and any future caller.
catalog_bind_host_override_env_name() {
  printf 'LLMCTL_BIND_HOST_%s' "$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')"
}

# catalog_bind_host <profile> -> the engine bind address for this profile.
# Per-profile override (LLMCTL_BIND_HOST_<PROFILE>, see the file-header
# comment above) takes precedence over the global LLMCTL_BIND_HOST default
# (common.sh); still profile-validated (catalog_check + catalog_exists)
# exactly like catalog_port(), so an override for an unknown profile still
# dies with the same "unknown profile" message rather than silently
# returning the override for a profile that does not exist.
catalog_bind_host() {
  local p="$1" override_var override
  catalog_check
  catalog_exists "${p}" || die "unknown profile: ${p} (see: llmctl models list)"
  override_var="$(catalog_bind_host_override_env_name "${p}")"
  override="${!override_var:-}"
  if [[ -n "${override}" ]]; then
    printf '%s\n' "${override}"
  else
    printf '%s\n' "${LLMCTL_BIND_HOST}"
  fi
}

catalog_min_tier()   { catalog_field "$1" min_tier baseline; }
catalog_desc()       { catalog_field "$1" desc ""; }
catalog_hf_repo()    { catalog_field "$1" hf_repo; }
# catalog_decision_protocol <profile> -> letter-logit | systemone-native | nli-onnx ("" for a non-decision profile).
catalog_decision_protocol() {
  catalog_check
  json_query "${LLMCTL_CATALOG}" "d[\"profiles\"][\"$1\"].get(\"decision\",{}).get(\"protocol\") or \"\"" 2>/dev/null || true
}

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
vram_free = hw.get("gpu_free_vram_mb")         # None: unmeasurable/old fixture
storage_free = hw["storage"]["free_mb"]

# Tier computed by catalog_classify_tier (bash) - the single source of
# truth for tier thresholds; no longer duplicated here.
tier = os.environ["LLMCTL_TIER"]
tier_rank = {"below-minimum": 0, "baseline": 1, "workstation": 2, "datacenter": 3}

ram_budget = max(0, ram_avail - 4096)          # 4 GiB RAM headroom
# Root-caused 2026-10-03 (real repro, not guessed): a profile reported
# "fits: true" here, computed from the card's STATIC TOTAL capacity, then
# genuinely OOM'd (cudaMalloc failed) at launch because something else
# already held several GiB of the SAME card's real capacity - this
# estimate could not see that, unlike ram_budget above which already uses
# REAL available RAM (ram_avail), not ram_total. vram_free (from
# hardware.sh's live nvidia-smi memory.free / amdgpu sysfs used-counter /
# Apple available-RAM-scaled probe) closes that asymmetry the same way:
# when a real measurement exists, the budget is 85% of what is ACTUALLY
# free right now, not 85% of the card's theoretical ceiling. The 15%
# figure itself is unchanged and reused rather than re-derived - it was
# already covering CUDA context/driver reserved allocations and
# allocator fragmentation on top of raw weights+KV, and that overhead is
# the same whether counted from total or from already-free capacity.
# Falls back to the pre-fix total-based estimate only when vram_free is
# genuinely unmeasurable (None) - an old hw-doc fixture, or a GPU
# vendor/path this fix could not verify a free-memory counter for (see
# hardware.sh's AMD rocm-smi comment) - never by treating "unknown" as
# "equal to total", which would silently resurrect the exact bug this
# fixes.
vram_budget = int((vram_free if vram_free is not None else vram_total) * 0.85)
# vram_live: True whenever vram_budget was computed from a REAL, live
# free-VRAM measurement rather than the static total-capacity fallback.
# Independent review, 2026-10-03 (same day as the fix above): a budget
# that already reflects current usage (ram_budget ALWAYS does, via
# ram_avail; vram_budget does exactly when this is True) must not ALSO
# have currently-running profiles' reservations added back on top at the
# admission-control call sites in scheduler.sh - that double-subtracts
# the same memory twice, UNDER-counting how much is genuinely free. The
# scheduler reads this flag to decide whether sched_reserved_field's sum
# belongs in that arithmetic at all (see scheduler.sh's
# _sched_initial_used). ram_budget carries no equivalent flag because it
# has never had a static-fallback path - ram_avail is unconditionally a
# live measurement.
vram_live = vram_free is not None

# KV-cache-type VRAM multipliers, relative to f16 = 1.0 (bits-per-element
# ratio to f16's 16 bits, plus each quant type's own per-block scale
# overhead). Root-caused 2026-10-03: the flat 1/8 MiB-per-token estimate
# below was ALWAYS an f16-calibrated number (llama-server's own default
# before this fix), never actually re-derived when q4_0/q8_0/etc. KV
# quantization became available as a real --cache-type-k/-v flag.
#
# q4_0 is EMPIRICALLY VERIFIED on real hardware (RTX 3060,
# Llama-3.2-3B-Instruct-Q4_K_M, 28 layers x 8 KV heads x 128 head_dim): a
# live llama-server run's own OOM log reported "allocating 3550740480
# bytes" for the KV buffer at ctx=110080 (110000 padded up to a multiple
# of 256 by llama.cpp's GGML_PAD(n_ctx, 256)) - and that is an EXACT match
# (round-3 independent review, 2026-10-03, re-verified here byte-for-byte),
# not an approximation: 2(K+V) * 28 * 8 * 128 * 2bytes(f16) = 114688
# f16-bytes/token, times q4_0's true per-block ratio (4 bits + one fp16
# scale per 32 elements = 4.5 bits/16 = 0.28125), times 110080 tokens =
# 3550740480.0 bytes, to the byte. 0.28125 (not 0.25) is q4_0's honest,
# portable ratio.
#
# Why this entry used to read 0.25, and why that was wrong to keep: this
# model's REAL f16 KV cost (114688 B/token = 0.109375 MiB/token) is itself
# ~12.5% BELOW what kv_mb()'s flat "ctx/8 MiB" base formula assumes (0.125
# MiB/token, equivalently a ~14.3% overestimate relative to the real cost -
# exactly right only when layers * kv_heads * head_dim = 32768, e.g.
# 32x8x128, as in an 8B-class Llama). 0.25 applied to the OVERESTIMATED
# 0.125 base happened to land close to the true cost - the true 0.28125
# ratio applied to THIS model's REAL 0.109375 base (0.25*0.125 = 0.03125
# ~= 0.28125*0.109375 = 0.03076, ~1.6% apart) - so 0.25 "worked" on this
# specific model only by accidentally cancelling the base formula's own
# error for THIS model's geometry (28 layers x 8 KV heads x 128 head_dim,
# not the 32x8x128 geometry the base formula assumes) - not a property of
# q4_0 itself, and actively UNSAFE (underestimate by ~11%) for any model
# whose real f16 cost actually matches the base formula's assumption.
# Fixed by storing q4_0's true, portable ratio (0.28125) instead of a
# value entangled with one model's base-formula error.
#
# Every other ratio is DERIVED from each format's known ggml block
# structure, confirmed against this repo's own submodules/llama.cpp
# static_asserts (ggml-common.h) - block size 32 elements unless noted -
# and has NOT been independently measured on real hardware. Round-2
# independent review (2026-10-03) found three of these rounded DOWN from
# their own bit-width math (the dangerous direction: an underestimate
# reports `fits: true` for a config that can genuinely OOM - see
# resolve_ctx's MIN_CTX comment below for the same asymmetry); round-3
# corrected q8_0 and q4_1's derivation (q4_1 carries BOTH a scale AND a
# min per block, not one); round-4 independent review (2026-10-03) found
# q5_0 and iq4_nl were STILL stored below their own exact ceilings (1.09%
# and 0.44% low respectively - not "a fraction of a percent", and both
# gaps larger than the one round-3 fixed for q8_0) and corrected them.
# Every non-q4_0 ratio below is now its format's exact bit-width ceiling,
# derived from its ggml block struct's real byte size - not an estimate:
#   q8_0:    half(2B) + 32B data = 34B/32el = 8.5  bits -> 8.5/16  = 0.53125
#   q5_1:    2*half(4B) + u32 qh(4B) + 16B  = 24B/32el = 6.0  bits -> 6.0/16  = 0.375
#   q4_1:    2*half(4B) + 16B data          = 20B/32el = 5.0  bits -> 5.0/16  = 0.3125
#   q5_0:    half(2B) + u32 qh(4B) + 16B    = 22B/32el = 5.5  bits -> 5.5/16  = 0.34375
#   iq4_nl:  half(2B) + 16B data            = 18B/32el = 4.5  bits -> 4.5/16  = 0.28125
# None of these five has been independently measured on real hardware -
# only q4_0 (above) has a live-measurement data point. Treat these five
# as exact-ceiling derivations, not measured constants, until each has
# its own measurement.
KV_TYPE_RATIO = {
    "f32": 2.0, "f16": 1.0, "bf16": 1.0,
    "q8_0": 0.53125, "q5_1": 0.375, "q5_0": 0.34375,
    "q4_1": 0.3125, "q4_0": 0.28125, "iq4_nl": 0.28125,
}

def kv_mb(ctx, parallel, kv_type="f16"):
    # f16-calibrated base estimate (1/8 MiB per token-slot), scaled by the
    # resolved KV cache type's measured/derived ratio - see KV_TYPE_RATIO.
    ratio = KV_TYPE_RATIO.get(kv_type, 1.0)
    return int(math.ceil(ctx * parallel * ratio / 8.0))

def resolve_ctx(name, default_ctx):
    """Per-profile context-size override: opt-in LLMCTL_CTX_<PROFILE> env
    var, same naming rule as resolve_port below. Root-caused 2026-10-03:
    models/catalog.json's "ctx" default had NO override anywhere in the
    codebase (unlike "port"), so every profile was permanently stuck at
    its catalog default regardless of what a specific host could actually
    support - confirmed live on this host that llmctl-small's model
    (Llama-3.2-3B) can serve a REAL 75000-token context with q4_0 KV
    quantization, far past its 8192-token catalog default, yet there was
    no way to actually configure that without editing the shared catalog
    file. This is the function every actual launch resolves its ctx
    through (sched_build_launch's --ctx-size), mirroring resolve_port's
    role for --port exactly.
    """
    env_name = "LLMCTL_CTX_" + name.upper().replace("-", "_")
    override = os.environ.get(env_name)
    if not override:
        return default_ctx
    # A plain int() parse (unlike resolve_port's identical-looking one) is
    # NOT safe here: round-2 independent review (2026-10-03) found 0 and
    # negative values silently accepted, and 0 is NOT harmless for ctx the
    # way it would be for a port -- llama-server's own `--ctx-size 0` means
    # "use the model's native/trained context" (confirmed in its --help),
    # which for a typical model is far larger than its catalog default and
    # would NOT fit in available VRAM, while kv_mb()'s estimate for ctx=0
    # computes as ~0 MiB, so the plan would falsely report `fits: true` for
    # a config that genuinely OOMs. MIN_CTX is an arbitrary-but-generous
    # floor (below any plausible real context) that exists purely to catch
    # 0/negative/absurdly-small typos, not to express a real minimum.
    MIN_CTX = 512
    try:
        value = int(override)
    except ValueError:
        sys.stderr.write(
            "catalog_plan_json: %s=%r is not a valid context size\n" % (env_name, override)
        )
        sys.exit(1)
    if value < MIN_CTX:
        sys.stderr.write(
            "catalog_plan_json: %s=%r must be >= %d (0 or negative has a "
            "different, dangerous meaning to llama-server's --ctx-size, not "
            "'use the catalog default')\n" % (env_name, override, MIN_CTX)
        )
        sys.exit(1)
    return value

def resolve_kv_type(name, default_type):
    """Per-profile KV-cache-type override: opt-in LLMCTL_KVTYPE_<PROFILE>
    env var. Validated against llama-server's own real --cache-type-k/-v
    allowed set (confirmed via `llama-server --help` on this host) -
    never passed through unvalidated, since an invalid value would only
    be caught at launch time by the engine itself, after the scheduler
    had already reported a (wrong) fits/footprint estimate for it.
    """
    allowed = {"f32", "f16", "bf16", "q8_0", "q4_0", "q4_1", "iq4_nl", "q5_0", "q5_1"}
    env_name = "LLMCTL_KVTYPE_" + name.upper().replace("-", "_")
    override = os.environ.get(env_name)
    value = override if override else default_type
    if value not in allowed:
        sys.stderr.write(
            "catalog_plan_json: kv_cache_type %r is not one of %s\n"
            % (value, sorted(allowed))
        )
        sys.exit(1)
    return value

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
    # "auto" selects the DYNAMIC strategy for this profile (FR-088): the port
    # is then assigned at start time by the registry allocator
    # (lib/portreg.sh), so the plan keeps the documented port as the
    # fallback/ordering key and the real port is recorded in "assigned_port"
    # once the service runs.
    if override.strip().lower() == "auto":
        return default_port
    try:
        return int(override)
    except ValueError:
        sys.stderr.write(
            "catalog_plan_json: %s=%r is not a valid port number\n" % (env_name, override)
        )
        sys.exit(1)

def overhead_field(name, dfl, key):
    """Validated defaults.<key> (overhead_mb | overhead_vram_mb): an integer in 0..65536, default 0.  Malformed is
    a loud error, never ignored."""
    v = dfl.get(key, 0)
    if isinstance(v, bool) or not isinstance(v, int) or not 0 <= v <= 65536:
        sys.stderr.write("catalog_plan_json: profile %s: defaults.%s must be an integer in 0..65536, got %r\n" % (name, key, v))
        sys.exit(1)
    return v

def footprint(name, p):
    """-> dict(mode, ram_mb, vram_mb, storage_mb, fits) or None when unfit."""
    size_mb = sum((f.get("size") or 0) for f in p["files"]) // 1048576
    dfl = p.get("defaults", {})
    ctx = resolve_ctx(name, int(dfl.get("ctx", 8192)))
    par = int(dfl.get("parallel", 1))
    if p["engine"] == "onnx":
        # Encoder-class decision runner (lib/onnx_server.py): CPU-only
        # inference (onnxruntime CPUExecutionProvider), so VRAM need is 0.
        # RAM reservation = model_size_mb * 1.5 + 512 MiB: the fp32 weights
        # are memory-mapped/loaded once (~1.0x), plus onnxruntime's session
        # working set and per-request activation buffers (~0.5x), plus a
        # fixed 512 MiB for the python3 interpreter + SentencePiece
        # tokenizer + HTTP stack. Storage need is the repo size + 10%
        # (same rule of thumb the colibri branch applies).
        ram_need = (size_mb * 3 // 2) + 512
        ok = ram_need <= ram_budget and size_mb * 11 // 10 <= storage_free
        return {"mode": "cpu", "ram_mb": ram_need, "vram_mb": 0,
                "storage_mb": size_mb, "ctx": ctx, "ngl": 0, "parallel": par,
                "flash_attn": "off", "fits": ok}
    if p["engine"] == "colibri":
        # Weights are memory-mapped from NVMe; RAM is page cache + working set.
        # No GPU KV cache (colibri's own int4-gs64 scheme is unrelated to
        # llama-server's --cache-type-k/-v), so kv_cache_type is not applicable.
        ram_need = 24576 if size_mb >= 102400 else 8192
        ok = ram_need <= ram_budget and size_mb * 11 // 10 <= storage_free
        return {"mode": "colibri", "ram_mb": ram_need, "vram_mb": 0,
                "storage_mb": size_mb, "ctx": ctx, "ngl": 0, "parallel": par,
                "flash_attn": "off", "fits": ok}
    kv_type = resolve_kv_type(name, dfl.get("kv_cache_type", "f16"))
    kv = kv_mb(ctx, par, kv_type)
    # defaults.overhead_mb / overhead_vram_mb: the MEASURED working set above weights + KV (activation / compute
    # buffers).  The flat ctx/8 KV rule cannot see it; for an encoder-class or native decision model it dominates
    # (Julia-1: 160 MiB of weights, 1.4 GiB peak with a 1024-token window).  Both come from
    # scripts/overhead_from_memory.py (rule: ceil(1.10 x (peak VmHWM - model file)); VRAM: ceil(1.10 x the peak VRAM
    # the engine pid held)) and carry their evidence in the profile's `memory` object.  Absent = 0, so every
    # profile that does not declare them keeps its footprint unchanged.
    ovh = overhead_field(name, dfl, "overhead_mb")
    ovh_v = overhead_field(name, dfl, "overhead_vram_mb")
    kv += ovh
    if vram_budget > 0 and size_mb + kv <= vram_budget and 2048 <= ram_budget:
        return {"mode": "gpu", "ram_mb": 2048, "vram_mb": size_mb + kv,
                "storage_mb": size_mb, "ctx": ctx,
                "ngl": int(dfl.get("ngl", 99)), "parallel": par,
                "flash_attn": dfl.get("flash_attn", "auto"), "kv_cache_type": kv_type,
                "fits": True}
    # cpu mode (-ngl 0): a CUDA build still offloads large-batch host ops to the GPU (measured: kev-08b 2.3 GiB of
    # VRAM, encoders 0.1-0.2 GiB), so on a host that HAS a GPU the measured offload VRAM is booked; on a CPU-only
    # host there is no offload and nothing is booked.  A host whose VRAM budget cannot hold it refuses the profile
    # (mode none) rather than silently booking 0.
    cpu_vram = ovh_v if vram_budget > 0 else 0
    if size_mb + kv <= ram_budget and cpu_vram <= vram_budget:
        return {"mode": "cpu", "ram_mb": size_mb + kv, "vram_mb": cpu_vram,
                "storage_mb": size_mb, "ctx": ctx, "ngl": 0, "parallel": par,
                "flash_attn": dfl.get("flash_attn", "auto"), "kv_cache_type": kv_type,
                "fits": True}
    return {"mode": "none", "ram_mb": size_mb + kv, "vram_mb": cpu_vram,
            "storage_mb": size_mb, "ctx": ctx, "ngl": 0, "parallel": par,
            "flash_attn": dfl.get("flash_attn", "auto"), "kv_cache_type": kv_type,
            "fits": False}

profiles = {}
for name in sorted(catalog["profiles"].keys()):
    p = catalog["profiles"][name]
    fp = footprint(name, p)
    min_tier = p.get("min_tier", "baseline")
    tier_ok = tier_rank[tier] >= tier_rank.get(min_tier, 1)
    # The port a RUNNING service was actually given (dynamic strategy, FR-088)
    # is read back from its reservation record, so `plan` shows reality.
    assigned = None
    run_rec = os.path.join(os.environ.get("LLMCTL_RUNTIME_DIR", ""), name + ".run")
    if os.environ.get("LLMCTL_RUNTIME_DIR") and os.path.isfile(run_rec):
        with open(run_rec) as rf:
            for ln in rf:
                if ln.startswith("port=") and ln[5:].strip().isdigit():
                    assigned = int(ln[5:].strip())
    if assigned is not None:
        fp["assigned_port"] = assigned
    fp.update({"port": resolve_port(name, p["port"]), "engine": p["engine"],
               "capability": p["capability"], "min_tier": min_tier,
               "tier_ok": tier_ok, "recommended": bool(fp["fits"] and tier_ok)})
    if "decide" in p.get("capability", []):
        # T139: what the planner booked above weights + KV, and the window it was measured at (None = unmeasured)
        pdfl = p.get("defaults", {})
        pmem = (p.get("memory") or {}).get("ram") or {}
        fp.update({"overhead_mb": int(pdfl.get("overhead_mb", 0)), "overhead_vram_mb": int(pdfl.get("overhead_vram_mb", 0)),
                   "window_tokens": pdfl.get("window_tokens"),
                   "memory_status": "measured" if pmem.get("status") == "measured" else "unmeasured"})
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

# Decision capacity (decide capability): per decide-capable profile, the
# maximum number of parallel server instances this host could run in GPU
# mode and in CPU mode (ALTERNATIVE placements, never additive), under the
# SAME ram_budget/vram_budget (4 GiB RAM headroom, 15% VRAM headroom)
# already computed above - no budget/headroom logic is changed, this only
# re-divides it. llama-engine profiles: GPU placement uses the same fixed
# 2048 MiB RAM reservation footprint() already uses for gpu mode; CPU
# placement is the weights+KV footprint with ngl=0. onnx-engine profiles
# are CPU-only encoder inference: instances_gpu is always 0 and the CPU
# per-instance footprint is the SAME size*1.5 + 512 MiB reservation the
# footprint() onnx branch computes. This is a READ-ONLY
# capacity report: it reserves nothing; runtime admission still goes
# through scheduler.sh's own budget check when a profile is actually
# started. Profiles that do not fit (or are tier-gated) report 0 with a
# "reason" field.
# G-030 / FR-074: the decision mode the launched servers run in. In the
# default deterministic mode a decision llama-server runs ONE slot (-np 1,
# context per slot preserved - lib/scheduler.sh sched_build_launch), so the
# parallel figure the planner reads from the catalog ("slots",
# "total_decision_slots") is the THROUGHPUT-mode figure. Both are reported:
# the catalog-parallel figures stay as they were, "slots_assume_mode" says
# which mode they assume, and the "effective_*" fields are the figures for the
# mode that is actually active.
decide_mode = (os.environ.get("LLMCTL_DECIDE_MODE") or "deterministic").strip().lower()
if decide_mode not in ("deterministic", "throughput"):
    sys.stderr.write("catalog_plan_json: LLMCTL_DECIDE_MODE=%r must be deterministic or throughput\n" % decide_mode)
    sys.exit(1)
decision_instances = {}
for name in sorted(catalog["profiles"].keys()):
    p = catalog["profiles"][name]
    if p["engine"] not in ("llama", "onnx") or "decide" not in p.get("capability", []):
        continue
    size_mb = sum((f.get("size") or 0) for f in p["files"]) // 1048576
    dfl = p.get("defaults", {})
    dpar = int(dfl.get("parallel", 1))
    dtier_ok = tier_rank[tier] >= tier_rank.get(p.get("min_tier", "baseline"), 1)
    if p["engine"] == "onnx":
        # CPU-only encoder: no GPU placement at all; per-instance RAM is
        # the footprint() onnx branch's size*1.5 + 512 MiB reservation.
        gpu_ram_mb, gpu_vram_mb = 0, 0
        cpu_ram_mb = (size_mb * 3 // 2) + 512
        cpu_vram_mb = 0
    else:
        dctx = resolve_ctx(name, int(dfl.get("ctx", 8192)))
        dkv_type = resolve_kv_type(name, dfl.get("kv_cache_type", "f16"))
        dkv = kv_mb(dctx, dpar, dkv_type) + int(dfl.get("overhead_mb", 0))   # validated by footprint() above
        gpu_ram_mb, gpu_vram_mb = 2048, size_mb + dkv
        cpu_ram_mb = size_mb + dkv
        # cpu placement on a host with a GPU also holds the measured offload VRAM (same rule as footprint())
        cpu_vram_mb = int(dfl.get("overhead_vram_mb", 0)) if vram_budget > 0 else 0
    inst_gpu = 0
    inst_cpu = 0
    reason = ""
    if p["engine"] == "onnx":
        # CPU-only encoder engine: GPU placement is not applicable (never a
        # "0-cost GPU instance" - that would divide by zero below).
        gpu_fits = False
    else:
        gpu_fits = (vram_budget > 0 and gpu_vram_mb <= vram_budget
                    and gpu_ram_mb <= ram_budget)
    cpu_fits = cpu_ram_mb <= ram_budget and cpu_vram_mb <= vram_budget
    if not dtier_ok:
        reason = "tier gate: host tier %s below min_tier %s" % (tier, p.get("min_tier", "baseline"))
    else:
        if gpu_fits:
            inst_gpu = min(vram_budget // gpu_vram_mb, ram_budget // gpu_ram_mb)
        if cpu_fits:
            inst_cpu = ram_budget // cpu_ram_mb
            if cpu_vram_mb > 0:
                inst_cpu = min(inst_cpu, vram_budget // cpu_vram_mb)
        if inst_gpu == 0 and inst_cpu == 0:
            reason = "footprint exceeds RAM and VRAM budgets"
    # per_instance reports the GPU placement when that placement fits (it
    # is the placement with the separate VRAM accounting), else the CPU
    # placement.
    if gpu_fits:
        per_instance = {"ram_mb": gpu_ram_mb, "vram_mb": gpu_vram_mb, "slots": dpar}
    else:
        per_instance = {"ram_mb": cpu_ram_mb, "vram_mb": cpu_vram_mb, "slots": dpar}
    # data-model.md section 10 (the 009 contract): total_decision_slots is the
    # capacity of the BEST SINGLE placement of this one profile alone against
    # the full current budgets (never additive across profiles or with
    # running chat profiles); per_instance reports the GPU placement when it
    # fits, else the CPU placement. Additive fields (candidate shape kept):
    #   protocol        decision.protocol of the catalog entry
    #   best_placement  "gpu"|"cpu" (the placement total_decision_slots uses,
    #                   GPU on a tie) or null when nothing fits
    #   placements      both per-instance footprints, so the scheduler's
    #                   admission probe (sched_decision_probe) and the
    #                   instance registry read ONE source of truth
    #   tier_ok         whether the host tier satisfies min_tier
    if inst_gpu > 0 and inst_gpu >= inst_cpu:
        best = "gpu"
    elif inst_cpu > 0:
        best = "cpu"
    else:
        best = None
    entry = {"instances_gpu": inst_gpu, "instances_cpu": inst_cpu,
             "per_instance": per_instance,
             "total_decision_slots": max(inst_gpu, inst_cpu) * dpar,
             "protocol": (p.get("decision") or {}).get("protocol"),
             "mode": decide_mode,
             "slots_assume_mode": "throughput",
             "effective_slots_per_instance": (1 if (decide_mode == "deterministic" and p["engine"] == "llama") else dpar),
             "effective_total_decision_slots": max(inst_gpu, inst_cpu) * (1 if (decide_mode == "deterministic" and p["engine"] == "llama") else dpar),
             "best_placement": best,
             "placements": {
                 "gpu": ({"ram_mb": gpu_ram_mb, "vram_mb": gpu_vram_mb}
                         if p["engine"] != "onnx" else None),
                 "cpu": {"ram_mb": cpu_ram_mb, "vram_mb": cpu_vram_mb}},
             "tier_ok": dtier_ok}
    if reason:
        entry["reason"] = reason
    decision_instances[name] = entry

out = {
    "tier": tier,
    "budgets": {"ram_mb": ram_budget, "vram_mb": vram_budget,
                "vram_live": vram_live, "storage_free_mb": storage_free},
    "profiles": profiles,
    "decision_instances": decision_instances,
    "decision_mode": decide_mode,
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
di = plan.get("decision_instances", {})
if di:
    print("")
    print("Decision capacity (max parallel instances per decide profile; capacity report, nothing reserved):")
    print("%-14s %-8s %-14s %-14s %-15s %s" %
          ("profile", "tier-ok", "gpu-instances", "cpu-instances", "slots/instance", "detail"))
    for name in sorted(di):
        r = di[name]
        if "reason" in r and r["instances_gpu"] == 0 and r["instances_cpu"] == 0 and "tier gate" in r["reason"]:
            tier_ok = "no"
        else:
            tier_ok = "yes"
        if r["instances_gpu"] == 0 and r["instances_cpu"] == 0 and "reason" in r:
            detail = r["reason"]
        else:
            detail = "RAM %d MiB / VRAM %d MiB per instance" % (
                r["per_instance"]["ram_mb"], r["per_instance"]["vram_mb"])
        print("%-14s %-8s %-14s %-14s %-15s %s" %
              (name, tier_ok, r["instances_gpu"], r["instances_cpu"],
               r["per_instance"]["slots"], detail))
PYEOF
}

# Footprint for a single profile out of a plan document.
# Usage: plan_get <plan-json-file-or-stdin... keep simple: reads plan JSON on stdin> <profile> <field>
catalog_plan_get() {
  local profile="$1" field="$2"
  json_stdin "d[\"profiles\"][\"$profile\"][\"$field\"]"
}
