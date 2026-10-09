#!/usr/bin/env bash
# podman-audit.sh - REPORT-ONLY audit of rootless podman memory limits (never modifies containers).
#   podman-audit.sh [--all]     (default: running containers only)
# Lists every container with its memory limit (0 = UNLIMITED) and prints the sum of the
# limits against MemTotal.  Incident 2026-10-08 context: 22 of 63 containers had no limit and
# the limited ones summed to ~50 GiB on a 31 GiB host.
# env: HOSTSAFETY_PODMAN (command), HOSTSAFETY_MEMINFO
set -uo pipefail
PODMAN="${HOSTSAFETY_PODMAN:-podman}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for cand in "${here}/lib.sh" "${XDG_DATA_HOME:-${HOME}/.local/share}/hostsafety/lib.sh"; do
  # shellcheck source=lib.sh
  [[ -r "${cand}" ]] && { source "${cand}"; break; }
done
type hs_memtotal_bytes >/dev/null 2>&1 || { echo "podman-audit: lib.sh not found" >&2; exit 1; }
filter=(); [[ "${1:-}" == "--all" ]] || filter=(--filter status=running)
mapfile -t ids < <("${PODMAN}" ps "${filter[@]}" --format '{{.ID}}' 2>/dev/null)
(( ${#ids[@]} > 0 )) || { echo "podman-audit: no containers"; exit 0; }
total="$(hs_memtotal_bytes)"
printf '%-40s %-10s %s\n' NAME STATE MEMORY_LIMIT
unl=0 sum=0 n=0
while IFS='|' read -r name state mem; do
  [[ -n "${name}" ]] || continue
  n=$((n + 1))
  if [[ "${mem}" =~ ^[0-9]+$ && "${mem}" -gt 0 ]]; then
    sum=$((sum + mem)); lim="$(numfmt --to=iec "${mem}")"
  else unl=$((unl + 1)); lim="UNLIMITED"; fi
  printf '%-40s %-10s %s\n' "${name}" "${state}" "${lim}"
done < <("${PODMAN}" inspect --format '{{.Name}}|{{.State.Status}}|{{.HostConfig.Memory}}' "${ids[@]}" 2>/dev/null)
echo "----"
echo "containers: ${n}   without memory limit: ${unl}"
echo "sum of memory limits: $(numfmt --to=iec "${sum}") vs MemTotal $(numfmt --to=iec "${total}") = $(( sum * 100 / total ))%"
(( sum > total )) && echo "WARNING: limits are over-committed (sum > MemTotal)"
(( unl > 0 )) && echo "WARNING: ${unl} container(s) can grow without bound (add --memory / MemoryMax)"
exit 0
