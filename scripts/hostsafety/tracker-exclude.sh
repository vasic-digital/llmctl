#!/usr/bin/env bash
# tracker-exclude.sh - keep GNOME localsearch/tracker out of build/dependency trees.
#   tracker-exclude.sh [--dry-run | --revert]
# Incident 2026-10-08: localsearch-3 indexed ~/go/pkg/mod and wrote 2.3M journal messages.
# Tracker3 matches `ignored-directories` on directory BASENAMES (globs), so generic
# build-tree names are added there; the Go module cache (basename "mod", far too generic)
# is excluded with a `.trackerignore` marker file instead (listed in
# `ignored-directories-with-content`).  The key is only changed if it exists; before/after
# values are printed; only entries WE added are removed by --revert.
# env: HOSTSAFETY_GSETTINGS (command, default gsettings), HOSTSAFETY_DATA_HOME,
#      HOSTSAFETY_GOMOD (default ~/go/pkg/mod)
set -uo pipefail
GS="${HOSTSAFETY_GSETTINGS:-gsettings}"
SCHEMA=org.freedesktop.Tracker3.Miner.Files
KEY=ignored-directories
DATA_HOME="${HOSTSAFETY_DATA_HOME:-${XDG_DATA_HOME:-${HOME}/.local/share}}"
ADDED="${DATA_HOME}/hostsafety/tracker-added"
CREATED="${DATA_HOME}/hostsafety/trackerignore-created"   # exists only if WE created ${GOMOD}/.trackerignore
GOMOD="${HOSTSAFETY_GOMOD:-${HOME}/go/pkg/mod}"
WANT=(node_modules .cache __pycache__ .venv .gradle .m2 .npm .cargo .terraform)
mode=apply
case "${1:-}" in --dry-run) mode=dry ;; --revert) mode=revert ;; "") ;; *) echo "usage: $0 [--dry-run|--revert]" >&2; exit 2 ;; esac

if ! "${GS}" list-keys "${SCHEMA}" 2>/dev/null | grep -qx "${KEY}"; then
  echo "hostsafety: tracker: key ${SCHEMA} ${KEY} not present - skipping"; exit 0
fi
before="$("${GS}" get "${SCHEMA}" "${KEY}")"
echo "hostsafety: tracker: before ${KEY} = ${before}"

# parse GVariant string array ("['a', 'b']" or "@as []") with python (no eval of untrusted code: literal_eval)
to_list() { python3 -I -c 'import ast,sys; t=sys.argv[1].replace("@as ",""); print("\n".join(ast.literal_eval(t)))' "$1"; }
from_list() { python3 -I -c 'import sys; print("[" + ", ".join("\x27"+x+"\x27" for x in sys.stdin.read().split("\n") if x) + "]")'; }

# the .trackerignore marker is removed on --revert ONLY if this script created it (a pre-existing one is the operator's)
revert_gomod() {
  if [[ -e "${CREATED}" ]]; then
    [[ -s "${GOMOD}/.trackerignore" ]] || rm -f "${GOMOD}/.trackerignore"
    rm -f "${CREATED}"; echo "hostsafety: tracker: removed ${GOMOD}/.trackerignore (we created it)"
  elif [[ -e "${GOMOD}/.trackerignore" ]]; then echo "hostsafety: tracker: kept ${GOMOD}/.trackerignore (not created by hostsafety)"; fi
}

mapfile -t cur < <(to_list "${before}")
case "${mode}" in
  revert)
    [[ -f "${ADDED}" ]] || { echo "hostsafety: tracker: nothing recorded to revert"; revert_gomod; exit 0; }
    new=()
    for e in "${cur[@]}"; do grep -qxF -- "${e}" "${ADDED}" || new+=("${e}"); done
    ;;
  *)
    new=("${cur[@]}"); added=()
    for w in "${WANT[@]}"; do
      printf '%s\n' "${cur[@]}" | grep -qxF -- "${w}" || { new+=("${w}"); added+=("${w}"); }
    done
    ;;
esac
newval="$(printf '%s\n' "${new[@]}" | from_list)"
if [[ "${newval}" == "$(printf '%s\n' "${cur[@]}" | from_list)" ]]; then
  echo "hostsafety: tracker: unchanged (already configured)"
else
  if [[ "${mode}" == dry ]]; then echo "hostsafety: tracker: WOULD set ${KEY} = ${newval}"
  else
    "${GS}" set "${SCHEMA}" "${KEY}" "${newval}" || { echo "hostsafety: tracker: gsettings set failed" >&2; exit 1; }
    if [[ "${mode}" == apply ]]; then
      mkdir -p "$(dirname "${ADDED}")"; printf '%s\n' "${added[@]}" >>"${ADDED}"
    else rm -f "${ADDED}"; fi
    echo "hostsafety: tracker: after  ${KEY} = $("${GS}" get "${SCHEMA}" "${KEY}")"
  fi
fi
if [[ -d "${GOMOD}" ]]; then
  case "${mode}" in
    apply) [[ -e "${GOMOD}/.trackerignore" ]] || { : >"${GOMOD}/.trackerignore" && mkdir -p "$(dirname "${CREATED}")" && : >"${CREATED}" && echo "hostsafety: tracker: created ${GOMOD}/.trackerignore"; } ;;
    dry) [[ -e "${GOMOD}/.trackerignore" ]] || echo "hostsafety: tracker: WOULD create ${GOMOD}/.trackerignore" ;;
    revert) revert_gomod ;;
  esac
fi
echo "hostsafety: tracker: note - restart the miner to apply at once: systemctl --user restart localsearch-3"
