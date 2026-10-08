#!/usr/bin/env bash
# fake_uv.sh - hermetic stand-in for uv (tests/test_install_agents.sh): `uv tool install ... aider-chat`
# drops an `aider` executable into $UV_TOOL_BIN_DIR.
set -euo pipefail
case "$1 $2" in
  "tool install")
    [[ -z "${FAKE_UV_LOG:-}" ]] || echo "$*" >>"${FAKE_UV_LOG}"
    mkdir -p "${UV_TOOL_BIN_DIR:?}"
    # shellcheck disable=SC2016  # the printf template is a literal script body
    # FAKE_UV_VERSION_CRASH=1: the installed aider dies on --version (message on stderr, exit 1) - C3-09
    printf '#!/usr/bin/env bash\ncase "$1" in --version)\n  if [[ "${FAKE_UV_VERSION_CRASH:-0}" == 1 ]]; then echo "ImportError: no module named x" >&2; exit 1; fi\n  echo "aider 9.9.9";; --help) echo "usage: aider --message MSG --yes-always";; esac\n' >"${UV_TOOL_BIN_DIR}/aider"
    chmod +x "${UV_TOOL_BIN_DIR}/aider" ;;
  *) echo "fake uv: unsupported $*" >&2; exit 1 ;;
esac
