#!/usr/bin/env bash
# hardware.sh - fully dynamic hardware probe for llmctl.
# Everything is read from real system interfaces (/proc, /sys, sysctl,
# nvidia-smi, rocm-smi, diskutil). No hardcoded assumptions about the host.
#
# Testability: when LLMCTL_FAKE_HW points at a JSON fixture file, the probe
# returns that file verbatim (after a JSON validity check). This is what makes
# the planner tests deterministic on any machine.
set -euo pipefail

_hw_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_hw_dir}/common.sh"
# shellcheck source=os_detect.sh
source "${_hw_dir}/os_detect.sh"

# ---------------------------------------------------------------------------
# CPU
# ---------------------------------------------------------------------------
_probe_cpu_model() {
  local os; os="$(llmctl_os)"
  if [[ "${os}" == "linux" ]]; then
    local model
    model="$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
    if [[ -z "${model}" ]]; then
      # ARM and other arches may not have "model name".
      model="$(awk -F': ' '/^Model|^Hardware/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
    fi
    [[ -n "${model}" ]] && { echo "${model}"; return 0; }
    return 1
  else
    sysctl -n machdep.cpu.brand_string 2>/dev/null && return 0
    sysctl -n hw.model 2>/dev/null && return 0
    return 1
  fi
}

# Space-separated SIMD feature list, best effort per OS/arch.
_probe_cpu_simd() {
  local os arch; os="$(llmctl_os)"; arch="$(llmctl_arch)"
  local simd_out=()
  if [[ "${os}" == "linux" ]]; then
    local flags
    flags="$(awk -F': ' '/^flags|^Features/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
    local f
    for f in sse4_2 avx avx2 avx512f avx512_vnni amx_tile amx_int8 amx_bf16 fma f16c neon asimd sve; do
      [[ " ${flags} " == *" ${f} "* ]] && simd_out+=("${f}")
    done
  else
    if [[ "${arch}" == "arm64" ]]; then
      simd_out+=("neon")
      [[ "$(sysctl -n hw.optional.arm.FEAT_SVE 2>/dev/null || echo 0)" == "1" ]] && simd_out+=("sve")
    else
      [[ "$(sysctl -n hw.optional.sse4_2 2>/dev/null || echo 0)" == "1" ]] && simd_out+=("sse4_2")
      [[ "$(sysctl -n hw.optional.avx1_0 2>/dev/null || echo 0)" == "1" ]] && simd_out+=("avx")
      [[ "$(sysctl -n hw.optional.avx2_0 2>/dev/null || echo 0)" == "1" ]] && simd_out+=("avx2")
      [[ "$(sysctl -n hw.optional.avx512f 2>/dev/null || echo 0)" == "1" ]] && simd_out+=("avx512f")
    fi
  fi
  echo "${simd_out[*]:-}"
}

# Apple Silicon chip name (M1..M4 etc.) or empty.
_probe_apple_chip() {
  is_apple_silicon || return 0
  local brand
  brand="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)"
  if [[ "${brand}" =~ (M[1-9][A-Za-z ]*) ]]; then
    echo "${BASH_REMATCH[1]}" | sed 's/ *$//'
  else
    echo "Apple Silicon"
  fi
}

# ---------------------------------------------------------------------------
# Memory (MiB)
# ---------------------------------------------------------------------------
_probe_mem() {
  # echoes "<total_mb> <available_mb>"
  local os; os="$(llmctl_os)"
  if [[ "${os}" == "linux" ]]; then
    local total avail
    total="$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null || true)"
    avail="$(awk '/^MemAvailable:/{print $2; exit}' /proc/meminfo 2>/dev/null || true)"
    [[ -n "${total}" ]] || return 1
    if [[ -z "${avail}" ]]; then
      avail="$(awk '/^MemFree:/{print $2; exit}' /proc/meminfo 2>/dev/null || echo "${total}")"
    fi
    echo "$(( total / 1024 )) $(( avail / 1024 ))"
    return 0
  else
    local bytes avail_bytes pagesize free_p inactive_p spec_p
    bytes="$(sysctl -n hw.memsize 2>/dev/null || true)"
    [[ -n "${bytes}" ]] || return 1
    pagesize="$(sysctl -n hw.pagesize 2>/dev/null || echo 16384)"
    if have_cmd vm_stat; then
      free_p="$(vm_stat | awk '/^Pages free/{gsub(/\./,"",$3); print $3}')"
      inactive_p="$(vm_stat | awk '/^Pages inactive/{gsub(/\./,"",$3); print $3}')"
      spec_p="$(vm_stat | awk '/^Pages speculative/{gsub(/\./,"",$3); print $3}')"
      avail_bytes=$(( ( ${free_p:-0} + ${inactive_p:-0} + ${spec_p:-0} ) * pagesize ))
    else
      avail_bytes="${bytes}"
    fi
    echo "$(( bytes / 1048576 )) $(( avail_bytes / 1048576 ))"
    return 0
  fi
}

# ---------------------------------------------------------------------------
# GPUs - one line per GPU: vendor|name|vram_mb|driver|extra
# ---------------------------------------------------------------------------
_probe_gpus() {
  local os; os="$(llmctl_os)"

  # NVIDIA (any OS with nvidia-smi).
  if have_cmd nvidia-smi; then
    local cuda=""
    cuda="$(nvidia-smi 2>/dev/null | sed -n 's/.*CUDA Version: \([0-9.]*\).*/\1/p' | head -1)"
    while IFS=',' read -r name vram driver; do
      name="${name# }"; vram="${vram// /}"; driver="${driver# }"
      [[ -n "${name}" && -n "${vram}" ]] && printf 'nvidia|%s|%s|%s|cuda=%s\n' "${name}" "${vram}" "${driver:-unknown}" "${cuda:-unknown}"
    done < <(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader,nounits 2>/dev/null || true)
  fi

  # AMD (Linux): rocm-smi first, then /sys fallback.
  if [[ "${os}" == "linux" ]]; then
    if have_cmd rocm-smi; then
      local ids
      ids="$(rocm-smi --showid --csv 2>/dev/null | awk -F',' 'NR>1 && $1!=""{print $1}' || true)"
      local id name vram
      for id in ${ids}; do
        name="$(rocm-smi --showproductname -d "${id}" --csv 2>/dev/null | awk -F',' 'NR>1{print $2; exit}' || true)"
        vram="$(rocm-smi --showmeminfo vram -d "${id}" --csv 2>/dev/null | awk -F',' 'NR>1{print $2; exit}' || true)"
        [[ -n "${vram}" ]] && vram=$(( vram / 1048576 )) || vram=0
        printf 'amd|%s|%s|rocm|%s\n' "${name:-AMD GPU (ROCm)}" "${vram}" "card${id}"
      done
    elif compgen -G "/sys/class/drm/card[0-9]" >/dev/null; then
      local card vram name drv
      for card in /sys/class/drm/card[0-9]; do
        [[ -e "${card}/device" ]] || continue
        drv="$(basename "$(readlink -f "${card}/device/driver" 2>/dev/null || echo unknown)")"
        case "${drv}" in
          amdgpu)
            vram="$(cat "${card}/device/mem_info_vram_total" 2>/dev/null || echo 0)"
            name="AMD GPU (amdgpu)"
            printf 'amd|%s|%s|%s|%s\n' "${name}" "$(( vram / 1048576 ))" "driver=${drv}" "$(basename "${card}")"
            ;;
          i915|xe)
            printf 'intel|Intel integrated GPU (%s)|0|driver=%s|%s\n' "${drv}" "${drv}" "$(basename "${card}")"
            ;;
        esac
      done
    fi
  fi

  # Apple Silicon: unified memory -> usable VRAM estimate (0.7 x total RAM,
  # matching what macOS exposes to Metal via recommendedMaxWorkingSetSize).
  if is_apple_silicon; then
    local mem chip vram
    mem="$(_probe_mem)" || mem="0 0"
    chip="$(_probe_apple_chip)"
    vram=$(( ${mem%% *} * 7 / 10 ))
    printf 'apple|%s|%s|unified|unified-memory\n' "${chip:-Apple Silicon}" "${vram}"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Storage at the models directory: "<free_mb> <type>" with type in
# nvme|ssd|hdd|unknown
# ---------------------------------------------------------------------------
_probe_storage() {
  local dir="${1:-${LLMCTL_MODELS_DIR}}"
  ensure_dir "${dir}"
  local free_mb dev base type="unknown" os
  os="$(llmctl_os)"

  free_mb="$(df -Pm "${dir}" 2>/dev/null | awk 'NR==2{print $4}')"
  [[ -n "${free_mb}" ]] || return 1

  if [[ "${os}" == "linux" ]]; then
    dev="$(df -P "${dir}" 2>/dev/null | awk 'NR==2{print $1}')"
    if have_cmd lsblk && [[ -b "${dev}" ]]; then
      # Walk up to the parent whole-disk and read its rotational flag.
      local row name rota
      row="$(lsblk -npo NAME,ROTA "${dev}" 2>/dev/null | head -1 || true)"
      name="${row%% *}"; rota="${row##* }"
      base="$(basename "${name:-${dev}}")"
      if [[ "${base}" == nvme* ]]; then
        type="nvme"
      elif [[ "${rota}" == "0" ]]; then
        type="ssd"
      elif [[ "${rota}" == "1" ]]; then
        type="hdd"
      fi
    else
      base="$(basename "${dev:-/}")"
      base="${base%%[0-9]*p*}"; base="${base%[0-9]}"
      if [[ "${base}" == nvme* ]]; then
        type="nvme"
      elif [[ -e "/sys/block/${base}/queue/rotational" ]]; then
        case "$(cat "/sys/block/${base}/queue/rotational")" in
          0) type="ssd" ;; 1) type="hdd" ;;
        esac
      fi
    fi
  else
    local info
    info="$(diskutil info "${dir}" 2>/dev/null || diskutil info / 2>/dev/null || true)"
    if [[ -n "${info}" ]]; then
      local solid proto
      solid="$(printf '%s\n' "${info}" | awk -F': *' '/Solid State/{print $2; exit}' | tr -d ' ')"
      proto="$(printf '%s\n' "${info}" | awk -F': *' '/Protocol/{print $2; exit}')"
      if [[ "${solid}" == "Yes" ]]; then
        case "${proto}" in
          *PCI*|*NVMe*|*Apple*) type="nvme" ;;
          *)                     type="ssd" ;;
        esac
      elif [[ "${solid}" == "No" ]]; then
        type="hdd"
      fi
    fi
  fi
  echo "${free_mb} ${type} ${dir}"
}

# ---------------------------------------------------------------------------
# Probe assembly
# ---------------------------------------------------------------------------
hw_probe_json() {
  # Fixture override keeps tests deterministic on any host.
  if [[ -n "${LLMCTL_FAKE_HW:-}" ]]; then
    [[ -r "${LLMCTL_FAKE_HW}" ]] || die "LLMCTL_FAKE_HW is set but unreadable: ${LLMCTL_FAKE_HW}"
    json_query "${LLMCTL_FAKE_HW}" 'd' >/dev/null || die "LLMCTL_FAKE_HW fixture is not valid JSON: ${LLMCTL_FAKE_HW}"
    cat "${LLMCTL_FAKE_HW}"
    return 0
  fi

  local os arch cores model simd chip memline mem_total mem_avail storage_line s_free s_type s_path
  os="$(llmctl_os)" || die "unsupported operating system: $(uname -s)"
  arch="$(llmctl_arch)"
  cores="$(llmctl_nproc)"
  [[ "${cores}" =~ ^[0-9]+$ && "${cores}" -ge 1 ]] || die "hardware probe failed: cannot determine CPU core count"
  model="$(_probe_cpu_model)" || die "hardware probe failed: cannot determine CPU model"
  simd="$(_probe_cpu_simd)"
  chip=""
  if is_apple_silicon; then chip="$(_probe_apple_chip)"; fi

  memline="$(_probe_mem)" || die "hardware probe failed: cannot determine system memory"
  mem_total="${memline%% *}"; mem_avail="${memline##* }"
  [[ "${mem_total}" -gt 0 ]] || die "hardware probe failed: total memory reported as ${mem_total} MiB"

  storage_line="$(_probe_storage "${LLMCTL_MODELS_DIR}")" || die "hardware probe failed: cannot determine free space at ${LLMCTL_MODELS_DIR}"
  s_free="$(echo "${storage_line}" | awk '{print $1}')"
  s_type="$(echo "${storage_line}" | awk '{print $2}')"
  s_path="$(echo "${storage_line}" | awk '{print $3}')"

  local gpu_lines
  gpu_lines="$(_probe_gpus)"

  LLMCTL_HW_OS="${os}" LLMCTL_HW_ARCH="${arch}" LLMCTL_HW_CORES="${cores}" \
  LLMCTL_HW_MODEL="${model}" LLMCTL_HW_SIMD="${simd}" LLMCTL_HW_CHIP="${chip}" \
  LLMCTL_HW_MEM_TOTAL="${mem_total}" LLMCTL_HW_MEM_AVAIL="${mem_avail}" \
  LLMCTL_HW_S_FREE="${s_free}" LLMCTL_HW_S_TYPE="${s_type}" LLMCTL_HW_S_PATH="${s_path}" \
  LLMCTL_HW_GPUS="${gpu_lines}" \
  python3 - <<'PYEOF'
import json, os, sys

def env(k, d=""):
    return os.environ.get(k, d)

gpus = []
for line in env("LLMCTL_HW_GPUS").splitlines():
    line = line.strip()
    if not line:
        continue
    parts = line.split("|")
    if len(parts) < 5:
        continue
    vendor, name, vram, driver, extra = parts[0], parts[1], parts[2], parts[3], parts[4]
    try:
        vram_mb = int(vram)
    except ValueError:
        vram_mb = 0
    g = {"vendor": vendor, "name": name, "vram_mb": vram_mb}
    if vendor == "nvidia":
        g["driver"] = driver
        g["cuda_version"] = extra.split("=", 1)[-1] if "=" in extra else extra
    elif vendor == "amd":
        g["stack"] = driver
        g["node"] = extra
    elif vendor == "apple":
        g["unified_memory"] = True
    else:
        g["driver"] = driver
        g["node"] = extra
    gpus.append(g)

doc = {
    "os": env("LLMCTL_HW_OS"),
    "arch": env("LLMCTL_HW_ARCH"),
    "cpu": {
        "cores": int(env("LLMCTL_HW_CORES", "1")),
        "model": env("LLMCTL_HW_MODEL"),
        "arch": env("LLMCTL_HW_ARCH"),
        "simd": [s for s in env("LLMCTL_HW_SIMD").split() if s],
        "apple_silicon": bool(env("LLMCTL_HW_CHIP")),
        "apple_chip": env("LLMCTL_HW_CHIP") or None,
    },
    "memory": {
        "total_mb": int(env("LLMCTL_HW_MEM_TOTAL", "0")),
        "available_mb": int(env("LLMCTL_HW_MEM_AVAIL", "0")),
    },
    "gpus": gpus,
    "gpu_total_vram_mb": sum(g["vram_mb"] for g in gpus),
    "storage": {
        "path": env("LLMCTL_HW_S_PATH"),
        "free_mb": int(env("LLMCTL_HW_S_FREE", "0")),
        "type": env("LLMCTL_HW_S_TYPE", "unknown"),
    },
}
json.dump(doc, sys.stdout, indent=2)
sys.stdout.write("\n")
PYEOF
}

# Human-readable rendering of a probe JSON document (stdin or fresh probe).
hw_probe_human() {
  local json_doc
  if [[ -n "${1:-}" ]]; then
    json_doc="$1"
  else
    json_doc="$(hw_probe_json)"
  fi
  LLMCTL_HW_DOC="${json_doc}" python3 - <<'PYEOF'
import json, os
d = json.loads(os.environ["LLMCTL_HW_DOC"])
c = d["cpu"]
print("OS:        %s (%s)" % (d["os"], d["arch"]))
print("CPU:       %s" % c["model"])
print("  cores:   %d" % c["cores"])
print("  simd:    %s" % (", ".join(c["simd"]) if c["simd"] else "(none detected)"))
if c.get("apple_silicon"):
    print("  chip:    %s (Apple Silicon, unified memory)" % c.get("apple_chip"))
m = d["memory"]
print("RAM:       %d MiB total, %d MiB available" % (m["total_mb"], m["available_mb"]))
if d["gpus"]:
    print("GPUs:      %d detected, %d MiB total VRAM" % (len(d["gpus"]), d["gpu_total_vram_mb"]))
    for g in d["gpus"]:
        extra = ""
        if g.get("cuda_version"):
            extra = " [driver %s, CUDA %s]" % (g.get("driver", "?"), g["cuda_version"])
        elif g.get("unified_memory"):
            extra = " [unified memory, VRAM = 0.7 x RAM estimate]"
        print("  - %s %s: %d MiB VRAM%s" % (g["vendor"], g["name"], g["vram_mb"], extra))
else:
    print("GPUs:      none detected (CPU-only host)")
s = d["storage"]
print("Storage:   %d MiB free at %s (type: %s)" % (s["free_mb"], s["path"], s["type"]))
PYEOF
}
