#!/usr/bin/env bash
# test_keyring_go_cli.sh - builds the REAL Go binary (go build -o into a temp
# dir, never into the repo) and drives `llmctl-decide key doctor|show|path|
# rotate|export` in temp dirs. Port of test_keyring_cli.sh. Asserts exit codes,
# file modes, stdout hygiene (doctor/rotate never print the key), idempotent
# export, and the FR-087 placement guard inside temp git repos.
# FR-057..FR-063, FR-087; contracts/cli.md `key`.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

if ! command -v go >/dev/null 2>&1; then
  echo "SKIP-SUITE: go toolchain not installed"; exit 0
fi
BIN="${TEST_TMP}/bin/llmctl-decide"
mkdir -p "${TEST_TMP}/bin"
( cd "${LLMCTL_ROOT}" && go build -o "${BIN}" ./cmd/llmctl-decide )
assert_file_exists "${BIN}" "binary built into the temp dir"

W="${TEST_TMP}/kr"
HOMEDIR="${TEST_TMP}/home"
mkdir -p "${W}" "${HOMEDIR}"

# kr <root> <args...> : clean environment, optional extra vars via KR_ENV
kr() {
  local root="$1"; shift
  env -i PATH="${PATH}" HOME="${HOMEDIR}" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      ${KR_ENV:-} "${BIN}" key --root "${root}" "$@"
}
mode() { stat -c '%a' "$1"; }
keyof() { sed -n 's/^LLMCTL_API_KEY=//p' "$1" | head -n1; }
has() { [[ "$1" == *"$2"* ]] && echo yes || echo no; }

# --- 1. path / doctor before any key exists (no generation by doctor) --------
R1="${W}/r1"; mkdir -p "${R1}"
KR_RC=0; KR_OUT="$(kr "${R1}" path 2>&1)" || KR_RC=$?
assert_eq "0" "${KR_RC}" "path: exit 0"
assert_eq "${R1}/.env" "${KR_OUT}" "path: prints <root>/.env"
KR_RC=0; KR_OUT="$(kr "${R1}" doctor 2>&1)" || KR_RC=$?
assert_eq "0" "${KR_RC}" "doctor (no key yet): exit 0"
assert_contains "${KR_OUT}" "none" "doctor: reports source none"
assert_file_absent "${R1}/.env" "doctor must not create/generate the key file"

# --- 2. show requires --yes-print --------------------------------------------
KR_RC=0; KR_OUT="$(kr "${R1}" show 2>&1)" || KR_RC=$?
assert_eq "2" "${KR_RC}" "show without --yes-print: usage exit 2"
KR_RC=0; KR_OUT="$(kr "${R1}" show --yes-print 2>&1)" || KR_RC=$?
assert_eq "4" "${KR_RC}" "show --yes-print with no key: exit 4"

# --- 3. rotate generates + persists 0600; doctor never prints the value -------
KR_RC=0; KR_OUT="$(kr "${R1}" rotate 2>&1)" || KR_RC=$?
assert_eq "0" "${KR_RC}" "rotate (first key): exit 0"
assert_file_exists "${R1}/.env" "rotate created .env"
assert_eq "600" "$(mode "${R1}/.env")" ".env mode is 0600"
K1="$(keyof "${R1}/.env")"
assert_eq "yes" "$([[ "${K1}" =~ ^[A-Za-z0-9_-]{32,}$ ]] && echo yes || echo no)" "stored key matches format"
assert_eq "no" "$(has "${KR_OUT}" "${K1}")" "rotate output does not contain the key"
KR_RC=0; KR_OUT="$(kr "${R1}" doctor 2>&1)" || KR_RC=$?
assert_eq "0" "${KR_RC}" "doctor (file key): exit 0"
assert_eq "no" "$(has "${KR_OUT}" "${K1}")" "doctor stdout/stderr never contains the key"
assert_contains "${KR_OUT}" "file" "doctor: source file"
assert_contains "${KR_OUT}" "600" "doctor: reports mode"

KR_RC=0; KR_OUT="$(kr "${R1}" show --yes-print 2>/dev/null)" || KR_RC=$?
assert_eq "0" "${KR_RC}" "show --yes-print: exit 0"
assert_eq "${K1}" "${KR_OUT}" "show --yes-print prints exactly the stored key"

KR_RC=0; KR_OUT="$(kr "${R1}" rotate --grace 600 2>&1)" || KR_RC=$?
assert_eq "0" "${KR_RC}" "rotate --grace: exit 0"
K2="$(keyof "${R1}/.env")"
assert_eq "yes" "$([[ "${K2}" != "${K1}" ]] && echo yes || echo no)" "rotated key differs"
assert_file_contains "${R1}/.env" "LLMCTL_API_KEY_PREVIOUS=${K1}" "previous key kept in file during grace"
assert_file_contains "${R1}/.env" "LLMCTL_API_KEY_PREVIOUS_EXPIRES=" "previous key has an expiry"
assert_eq "600" "$(mode "${R1}/.env")" ".env stays 0600 after rotate"
assert_eq "no" "$([[ "$(has "${KR_OUT}" "${K2}")" == yes || "$(has "${KR_OUT}" "${K1}")" == yes ]] && echo yes || echo no)" "rotate --grace output has no key values"

# --- 4. environment wins and is reported as shadowing -------------------------
ENVKEY="EnvK3y-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-QwErTy"   # a shadowing key must pass the entropy floor (review A-06)
KR_RC=0; KR_OUT="$(KR_ENV="LLMCTL_API_KEY=${ENVKEY}" kr "${R1}" doctor 2>&1)" || KR_RC=$?
assert_eq "0" "${KR_RC}" "doctor with env key: exit 0"
assert_contains "${KR_OUT}" "env" "doctor: source env"
assert_contains "${KR_OUT}" "shadow" "doctor: reports .env shadowed by env"
assert_eq "no" "$(has "${KR_OUT}" "${ENVKEY}")" "doctor does not print env key"

# --- 5. malformed env value -> exit 4; loose perms tightened -----------------
KR_RC=0; KR_OUT="$(KR_ENV="LLMCTL_API_KEY=short" kr "${R1}" doctor 2>&1)" || KR_RC=$?
assert_eq "4" "${KR_RC}" "doctor with malformed env key: exit 4"
KR_RC=0; KR_OUT="$(KR_ENV="LLMCTL_API_KEY=" kr "${R1}" show --yes-print 2>&1)" || KR_RC=$?
assert_eq "4" "${KR_RC}" "blank env key is an error (exit 4), not 'no key'"
chmod 644 "${R1}/.env"
KR_RC=0; KR_OUT="$(kr "${R1}" doctor 2>&1)" || KR_RC=$?
assert_eq "0" "${KR_RC}" "doctor on loose-mode .env: exit 0 after tightening"
assert_eq "600" "$(mode "${R1}/.env")" "loose .env tightened to 0600"

# --- 6. LLMCTL_ENV_FILE override ----------------------------------------------
R2="${W}/r2"; mkdir -p "${R2}"
OVR="${W}/elsewhere/my.env"
KR_RC=0; KR_OUT="$(KR_ENV="LLMCTL_ENV_FILE=${OVR}" kr "${R2}" path 2>&1)" || KR_RC=$?
assert_eq "${OVR}" "${KR_OUT}" "path honours LLMCTL_ENV_FILE"
KR_RC=0; KR_ENV="LLMCTL_ENV_FILE=${OVR}" kr "${R2}" rotate >/dev/null 2>&1 || KR_RC=$?
assert_eq "0" "${KR_RC}" "rotate into overridden path: exit 0"
assert_file_exists "${OVR}" "key written to LLMCTL_ENV_FILE"
assert_file_absent "${R2}/.env" "default .env untouched when overridden"

# --- 7. export: explicit, idempotent, backup, reference form default ----------
RC="${W}/fakerc"
printf 'alias ll=ls\n' > "${RC}"
KR_RC=0; KR_OUT="$(kr "${R1}" export 2>&1)" || KR_RC=$?
assert_eq "2" "${KR_RC}" "export without --file: usage exit 2 (never guesses a startup file)"
assert_eq "alias ll=ls" "$(cat "${RC}")" "startup file untouched without explicit command"
KR_RC=0; KR_OUT="$(kr "${R1}" export --file "${RC}" 2>&1)" || KR_RC=$?
assert_eq "0" "${KR_RC}" "export --file: exit 0"
assert_contains "${KR_OUT}" "export LLMCTL_API_KEY=" "export shows exactly what it writes"
assert_eq "no" "$(has "${KR_OUT}" "${K2}")" "reference-form export does not print the key"
assert_file_contains "${RC}" ">>> llmctl key (managed) >>>" "managed begin marker present"
SNAP="$(cat "${RC}")"
KR_RC=0; KR_OUT="$(kr "${R1}" export --file "${RC}" 2>&1)" || KR_RC=$?
assert_eq "0" "${KR_RC}" "second export: exit 0"
assert_eq "${SNAP}" "$(cat "${RC}")" "second export is idempotent (file byte-identical)"
assert_eq "1" "$(grep -c '>>> llmctl key' "${RC}")" "exactly one managed block after two exports"
BAKS="$(find "${W}" -maxdepth 1 -name 'fakerc*bak*' | wc -l)"
assert_eq "1" "$([[ "${BAKS}" -ge 1 ]] && echo 1 || echo 0)" "backup file made"
assert_eq "yes" "$(head -n1 "$(find "${W}" -maxdepth 1 -name 'fakerc*bak*' | head -1)" | grep -qx 'alias ll=ls' && echo yes || echo no)" "backup holds original content"
RC2="${W}/fakerc2"
KR_RC=0; KR_OUT="$(kr "${R1}" export --file "${RC2}" --inline 2>&1)" || KR_RC=$?
assert_eq "2" "${KR_RC}" "export --inline without --yes-print: usage exit 2"
assert_file_absent "${RC2}" "inline refused: nothing written"
KR_RC=0; KR_OUT="$(kr "${R1}" export --file "${RC2}" --inline --yes-print 2>&1)" || KR_RC=$?
assert_eq "0" "${KR_RC}" "export --inline --yes-print: exit 0"
assert_file_contains "${RC2}" "export LLMCTL_API_KEY=\"${K2}\"" "inline form carries the literal key"

# --- 8. placement guard (FR-087) in a temp git repo ---------------------------
R3="${W}/repo"; mkdir -p "${R3}"
git -C "${R3}" init -q
KR_RC=0; KR_OUT="$(kr "${R3}" rotate 2>&1)" || KR_RC=$?
assert_eq "4" "${KR_RC}" "inside git work tree, not ignored: refused (exit 4)"
assert_contains "${KR_OUT}" "${R3}/.env" "refusal names the path"
assert_contains "${KR_OUT}" ".gitignore" "refusal names the fix"
assert_file_absent "${R3}/.env" "nothing created when refused"
printf '.env\n' > "${R3}/.gitignore"
KR_RC=0; KR_OUT="$(kr "${R3}" rotate 2>&1)" || KR_RC=$?
assert_eq "0" "${KR_RC}" "inside git work tree, ignored: allowed"
assert_eq "600" "$(mode "${R3}/.env")" "ignored .env created 0600"
git -C "${R3}" add -A >/dev/null 2>&1 || true
assert_eq "no" "$(git -C "${R3}" ls-files --error-unmatch .env >/dev/null 2>&1 && echo yes || echo no)" "ignored .env is not tracked"

# --- 9. concurrent first starts make exactly one key --------------------------
R4="${W}/r4"; mkdir -p "${R4}"
for _ in $(seq 1 8); do ( kr "${R4}" rotate >/dev/null 2>&1 || true ) & done
wait
assert_eq "1" "$(grep -c '^LLMCTL_API_KEY=' "${R4}/.env")" "concurrent rotations leave exactly one key line"
assert_eq "600" "$(mode "${R4}/.env")" "concurrent writes leave 0600"
assert_eq "1" "$(find "${R4}" -maxdepth 1 -type f | wc -l | tr -d ' ')" "no temp files left behind"

# --- 10. symlinked env file refused; unknown command / usage -------------------
R5="${W}/r5"; mkdir -p "${R5}"
printf 'LLMCTL_API_KEY=%s\n' "${K1}" > "${R5}/real.env"; chmod 600 "${R5}/real.env"
ln -s "${R5}/real.env" "${R5}/.env"
KR_RC=0; kr "${R5}" doctor >/dev/null 2>&1 || KR_RC=$?
assert_eq "4" "${KR_RC}" "symlinked .env refused (exit 4)"
KR_RC=0; kr "${R1}" frobnicate >/dev/null 2>&1 || KR_RC=$?
assert_eq "2" "${KR_RC}" "unknown command: exit 2"

# --- 11. nothing written into the repository tree ------------------------------
assert_eq "0" "$(git -C "${LLMCTL_ROOT}" status --porcelain --ignored -- 'llmctl-decide' 2>/dev/null | wc -l | tr -d ' ')" "no binary dropped in the repo root"

test_finish
