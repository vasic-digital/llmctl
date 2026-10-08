#!/usr/bin/env bash
# test_no_stray_binaries.sh - no native executable may sit in the work tree where it does not belong.
# Why: an ad-hoc `go build ./cmd/...` (without -o) drops a 9-24 MB binary into the current directory;
# it would be committed by `git add -A` and shipped (gap G-105). This guard fails the suite instead.
#
# Scope (C3-12, stated, not implied):
#   * UNTRACKED + NOT ignored files of the main repo AND of every initialised submodule (`git ls-files --others
#     --exclude-standard` does not recurse into submodules, so each one is listed on its own);
#   * TRACKED native executables larger than 1 MiB that are not named in tests/fixtures/TRACKED_BINARIES_ALLOWLIST.txt
#     (one exact repo-relative path per line, '#' comments) - a small tracked fixture binary is legitimate, a 20 MB one
#     is a release-size accident.
# Formats (magic bytes): ELF; Mach-O thin (both endians, 32/64) and FAT/universal (0xcafebabe followed by a small
# architecture count - a Java class file shares the magic but carries a major version >= 45 there, so it is not flagged);
# Windows PE (MZ with a "PE\0\0" header at the offset stored at 0x3c); WebAssembly (\0asm).
# Instrument proof (C3-12): the control needles go through the SAME enumeration function as the real check, on a scratch
# git repository (and a scratch submodule), not through a bare predicate on a file in mktemp.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
cd "${LLMCTL_ROOT}"
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "SKIP-SUITE: not inside a git work tree (stray-binary guard needs git to list untracked files)"; exit 0
fi

TRACKED_MAX=$((1024 * 1024))

u32be() { od -An -tu1 -j"$2" -N4 "$1" 2>/dev/null | awk '{print $1*16777216+$2*65536+$3*256+$4}'; }
u32le() { od -An -tu1 -j"$2" -N4 "$1" 2>/dev/null | awk '{print $4*16777216+$3*65536+$2*256+$1}'; }

is_binary() { # $1 path -> 0 when it is a native executable / module, judged by magic bytes
  local magic n pe
  magic="$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')"
  case "${magic}" in
    7f454c46|cffaedfe|cefaedfe|feedface|feedfacf) return 0 ;;     # ELF, Mach-O thin
    0061736d) return 0 ;;                                          # WebAssembly
    cafebabe|bebafeca)                                             # fat Mach-O, or a Java class file
      n="$(u32be "$1" 4)"; [[ -n "${n}" && "${n}" -lt 20 ]] && return 0 ;;
    4d5a*)                                                         # PE: MZ + "PE\0\0" at e_lfanew
      n="$(u32le "$1" 60)"
      if [[ -n "${n}" && "${n}" -gt 0 && "${n}" -lt 1048576 ]]; then
        pe="$(od -An -tx1 -j"${n}" -N4 "$1" 2>/dev/null | tr -d ' \n')"
        [[ "${pe}" == 50450000 ]] && return 0
      fi ;;
  esac
  return 1
}

# scan_strays <repo-dir> [<tracked-allowlist-file>] -> prints "<repo-relative path>\t<untracked|tracked>" per finding.
# THE enumeration used by the real check and by the control needles.
scan_strays() {
  local root="$1" allow="${2:-}" f sm
  _scan_one() { # <git-dir> <path-prefix>
    local d="$1" pre="$2" f
    while IFS= read -r -d '' f; do
      [[ -f "${d}/${f}" ]] || continue
      if is_binary "${d}/${f}"; then printf '%s%s\tuntracked\n' "${pre}" "${f}"; fi
    done < <(git -C "${d}" ls-files --others --exclude-standard -z 2>/dev/null)
    # tracked + large: find the large regular files first (one pass; a per-file stat of ~20k tracked files is minutes),
    # then keep the ones git tracks in THIS repo
    while IFS= read -r -d '' f; do
      f="${f#"${d}"/}"
      git -C "${d}" ls-files --error-unmatch -- "${f}" >/dev/null 2>&1 || continue
      is_binary "${d}/${f}" || continue
      if [[ -n "${allow}" && -f "${allow}" ]] && grep -v '^[[:space:]]*#' "${allow}" | sed 's/[[:space:]]*$//' | grep -q -F -x -- "${pre}${f}"; then continue; fi
      printf '%s%s\ttracked\n' "${pre}" "${f}"
    done < <(find "${d}" -name .git -prune -o -type f -size +"${TRACKED_MAX}"c -print0 2>/dev/null)
  }
  _scan_one "${root}" ""
  while IFS= read -r sm; do
    [[ -n "${sm}" && -e "${root}/${sm}/.git" ]] || continue
    _scan_one "${root}/${sm}" "${sm}/"
  done < <(git -C "${root}" submodule foreach --recursive --quiet 'printf "%s\n" "$displaypath"' 2>/dev/null || true)
}

# --- control (C3-12): a scratch repo + scratch submodule, scanned by the SAME function ---------------------------------
ctl="$(mktemp -d)"; trap 'rm -rf "${ctl}"' EXIT
mkbin() { # mkbin <kind> <path>
  case "$1" in
    elf)  printf '\x7fELF\x02\x01\x01\x00' ;;
    macho) printf '\xcf\xfa\xed\xfe\x07\x00\x00\x01' ;;
    fat)  printf '\xca\xfe\xba\xbe\x00\x00\x00\x02' ;;
    java) printf '\xca\xfe\xba\xbe\x00\x00\x00\x34' ;;
    wasm) printf '\x00asm\x01\x00\x00\x00' ;;
    pe)   { printf 'MZ'; head -c 58 /dev/zero; printf '\x40\x00\x00\x00'; printf 'PE\x00\x00'; } ;;
    mz_text) printf 'MZ is a nice prefix for a text file\n' ;;
    text) printf 'plain text\n' ;;
  esac >"$2"
}
CT="${ctl}/repo"; SMU="${ctl}/smup"
git init -q "${SMU}"; ( cd "${SMU}"; git config user.email t@e.x; git config user.name t; echo s > s.txt; git add s.txt; git commit -qm s )
git init -q "${CT}"
( cd "${CT}"; git config user.email t@e.x; git config user.name t
  git -c protocol.file.allow=always submodule add -q "file://${SMU}" sub >/dev/null 2>&1
  echo tracked > tracked.txt; printf 'ignored_elf\n' > .gitignore; git add -A; git commit -qm base )
mkbin elf "${CT}/stray_elf"; mkbin macho "${CT}/stray_macho"; mkbin fat "${CT}/stray_fat"; mkbin wasm "${CT}/stray.wasm"
mkbin pe "${CT}/stray.exe"; mkbin elf "${CT}/ignored_elf"; mkbin java "${CT}/Foo.class"; mkbin mz_text "${CT}/mz.txt"
mkbin text "${CT}/text"; mkbin elf "${CT}/sub/stray_in_sub"
found="$(scan_strays "${CT}")"
for want in stray_elf stray_macho stray_fat stray.wasm stray.exe sub/stray_in_sub; do
  assert_contains "${found}" "${want}	untracked" "control: the enumeration reports an untracked ${want}"
done
for notwant in ignored_elf Foo.class mz.txt text tracked.txt; do
  case "${found}" in *"${notwant}	"*) assert_eq "absent" "present" "control: ${notwant} must NOT be flagged (ignored / Java class / text)" ;; *) assert_eq 0 0 "control: ${notwant} is not flagged" ;; esac
done
# tracked + big + not allow-listed -> flagged; allow-listed -> not
head -c $((TRACKED_MAX + 4096)) /dev/zero > "${CT}/big.bin"; printf '\x7fELF' | dd of="${CT}/big.bin" conv=notrunc 2>/dev/null
head -c 4096 /dev/zero > "${CT}/small.bin"; printf '\x7fELF' | dd of="${CT}/small.bin" conv=notrunc 2>/dev/null
( cd "${CT}"; git add -f big.bin small.bin; git commit -qm bins )
found="$(scan_strays "${CT}")"
assert_contains "${found}" "big.bin	tracked" "control: a TRACKED native executable above 1 MiB is flagged"
case "${found}" in *"small.bin	tracked"*) assert_eq "absent" "present" "control: a small tracked fixture binary is not flagged" ;; *) assert_eq 0 0 "control: a small tracked fixture binary is not flagged" ;; esac
printf '# reviewed\nbig.bin\n' > "${ctl}/allow.txt"
found="$(scan_strays "${CT}" "${ctl}/allow.txt")"
case "${found}" in *"big.bin	tracked"*) assert_eq "absent" "present" "control: an allow-listed tracked binary is not flagged" ;; *) assert_eq 0 0 "control: an allow-listed tracked binary is not flagged" ;; esac

# --- the real check ---
stray="$(scan_strays "${LLMCTL_ROOT}" "${LLMCTL_ROOT}/tests/fixtures/TRACKED_BINARIES_ALLOWLIST.txt")"
if [[ -z "${stray}" ]]; then
  assert_eq 0 0 "no stray native executable in the work tree (untracked, in any submodule, or tracked and > 1 MiB)"
else
  printf '  stray binaries:\n' >&2; printf '    %s\n' "${stray}" >&2
  assert_eq "" "${stray}" "no stray native executable in the work tree (untracked, in any submodule, or tracked and > 1 MiB)"
fi
test_finish
