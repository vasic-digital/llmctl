#!/usr/bin/env bash
# fake_npm.sh - hermetic stand-in for npm used by tests/test_install_agents.sh.
# Supports: view <pkg> version|dist.tarball|dist.integrity, install --prefix P ... pkg@ver.
# FAKE_NPM_BAD_INTEGRITY=1 makes the published integrity wrong (mismatch must be caught).
set -euo pipefail
D="${FAKE_NPM_DIR:?}"
tarball="${D}/pkg.tgz"
if [[ ! -f "${tarball}" ]]; then printf 'fake tarball\n' | gzip >"${tarball}"; fi
case "$1" in
  view)
    case "$3" in
      version) echo "9.9.9" ;;
      dist.tarball) echo "file://${tarball}" ;;
      dist.integrity)
        if [[ "${FAKE_NPM_BAD_INTEGRITY:-0}" == 1 ]]; then echo "sha512-AAAA"; else
          echo "sha512-$(openssl dgst -sha512 -binary "${tarball}" | openssl base64 -A)"; fi ;;
    esac ;;
  pack)
    # npm pack <pkg@ver> --pack-destination DIR : prints the tarball file name.
    # FAKE_NPM_PACK_TAMPERED=1 hands out DIFFERENT bytes than the ones the registry published an
    # integrity for (the artifact that would actually be installed is not the one that was vouched for).
    pkgspec="$2"; shift 2; dest="."
    while [[ $# -gt 0 ]]; do case "$1" in --pack-destination) dest="$2"; shift 2 ;; *) shift ;; esac; done
    name="$(printf '%s' "${pkgspec%@*}" | tr -c 'A-Za-z0-9\n' '-' | sed 's/^-*//')-9.9.9.tgz"
    if [[ "${FAKE_NPM_PACK_TAMPERED:-0}" == 1 ]]; then printf 'tampered tarball\n' | gzip >"${dest}/${name}"; else cp "${tarball}" "${dest}/${name}"; fi
    echo "${name}" ;;
  install)
    echo "$*" >>"${D}/install.args"
    shift; prefix=""; pkg=""
    while [[ $# -gt 0 ]]; do case "$1" in --prefix) prefix="$2"; shift 2 ;; -*) shift ;; *) pkg="$1"; shift ;; esac; done
    bin="${FAKE_NPM_BIN:?}"
    mkdir -p "${prefix}/node_modules/.bin"
    # shellcheck disable=SC2016  # the printf template is a literal script body
    # FAKE_NPM_HELP_CRASH=1: --help dies on a lazily loaded native module (message on STDERR, exit 1) - C3-09
    # FAKE_NPM_HELP_RC1=1: --help prints usage on stdout but exits 1 - C3-09
    # FAKE_NPM_HELP_EMPTY=1: --help exits 0 but prints nothing on stdout - C3-09 (S3)
    printf '#!/usr/bin/env bash\ncase "$1" in --version) echo "%s 9.9.9";; --help)\n  if [[ "${FAKE_NPM_HELP_CRASH:-0}" == 1 ]]; then echo "Error: Cannot find module better-sqlite3" >&2; exit 1; fi\n  if [[ "${FAKE_NPM_HELP_EMPTY:-0}" == 1 ]]; then exit 0; fi\n  if [[ "${FAKE_NPM_HELP_RC1:-0}" == 1 ]]; then echo "usage: crashed after printing"; exit 1; fi\n  echo "usage: %s -p --print --yolo";; esac\n' "${bin}" "${bin}" >"${prefix}/node_modules/.bin/${bin}"
    chmod +x "${prefix}/node_modules/.bin/${bin}"
    echo "installed ${pkg}" ;;
  *) echo "fake npm: unsupported $*" >&2; exit 1 ;;
esac
