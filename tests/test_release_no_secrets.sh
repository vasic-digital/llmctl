#!/usr/bin/env bash
# test_release_no_secrets.sh - GREEN guard for spec 009 FR-087 / D-30:
# scripts/release/build_archive.sh must never put untracked/ignored secrets
# (.env, cert/**, *.key, *.pem) into the release tar.gz / zip.
#
# Layers:
#  1. Reuses the RED scenario (tests/fixtures/release_secrets/scenario.py, read-only,
#     not duplicated) - it carries its own control needle; must be NOT-REPRODUCED.
#  2. Real git-mode fixture (main repo + one submodule): untracked .env,
#     ignored cert/ca/ca.key and decide/log.key, and an untracked secret in the
#     submodule must be absent from BOTH archives, while tracked files (control
#     needle) and the submodule's content are present.
#  3. Defense in depth: a TRACKED secret makes the build fail non-zero and
#     leaves no archive behind.
#  4. Mutation: the pre-fix unfiltered script (git show of the old blob,
#     embedded below) run on the same fixture MUST leak -> proves this test
#     can fail.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
export PYTHONDONTWRITEBYTECODE=1

# --- 1. RED scenario must now report NOT-REPRODUCED -------------------------
rc=0
RED_RESULTS_FILE="${TEST_TMP}/d30.jsonl" bash "${LLMCTL_ROOT}/tests/fixtures/release_secrets/run.sh" >"${TEST_TMP}/red.out" 2>&1 || rc=$?
assert_eq 0 "${rc}" "D-30 RED scenario now NOT-REPRODUCED (exit 0)"
assert_contains "$(cat "${TEST_TMP}/red.out")" "control needle found in both archives" "RED scenario control needle found (instrument not blind)"

# --- 2. git-mode fixture -----------------------------------------------------
W="${TEST_TMP}/fx"
mkdir -p "${W}"
SUBUP="${W}/subup"; git init -q "${SUBUP}"
( cd "${SUBUP}"; git config user.email t@e.x; git config user.name t
  echo "sub tracked" > sub_file.txt; git add -A; git commit -qm s )
SUPER="${W}/super"; git init -q "${SUPER}"
( cd "${SUPER}"; git config user.email t@e.x; git config user.name t
  git -c protocol.file.allow=always submodule add -q "file://${SUBUP}" sub >/dev/null
  printf 'cert/\n*.key\n.env\n' > .gitignore
  echo "CONTROL-NEEDLE-TRACKED" > tracked.txt
  git add -A; git commit -qm m
  # planted, untracked / ignored secrets
  echo "FAKE-ENV" > .env
  mkdir -p cert/ca decide; echo "FAKE-CA" > cert/ca/ca.key; echo "FAKE-LOG" > decide/log.key
  echo "FAKE-SUB" > sub/sub_secret.pem )

list_both() { { tar -tzf "$1.tar.gz"; zipinfo -1 "$1.zip"; } ; }
contains_path() { grep -qE "(^|/)$2\$" <<<"$1"; }

source "${LLMCTL_ROOT}/scripts/release/build_archive.sh"
OUT="${TEST_TMP}/o/rel"; mkdir -p "$(dirname "${OUT}")"
build_archive --allow-dirty "${SUPER}" "${OUT}"   # the fixture plants UNTRACKED secrets on purpose (C2-15 refuses a dirty tree otherwise)
L="$(list_both "${OUT}")"
for f in tracked.txt sub/sub_file.txt .gitignore; do
  rc=0; contains_path "${L}" "${f}" || rc=$?
  assert_eq 0 "${rc}" "tracked file present in both archives: ${f}"
done
for f in .env cert/ca/ca.key decide/log.key sub/sub_secret.pem; do
  rc=0; contains_path "${L}" "${f}" || rc=$?
  assert_eq 1 "${rc}" "planted untracked secret absent from both archives: ${f}"
done

# --- 3. tracked secret => build fails, nothing left behind -------------------
( cd "${SUPER}"; echo "TRACKED-SECRET" > leak.key; git add -f leak.key; git commit -qm leak )
OUT2="${TEST_TMP}/o/leak"
rc=0; ( build_archive --allow-dirty "${SUPER}" "${OUT2}" ) >/dev/null 2>"${TEST_TMP}/err.txt" || rc=$?
assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "tracked secret makes build_archive exit non-zero"
assert_file_absent "${OUT2}.tar.gz" "no tar.gz left behind after secret detection"
assert_file_absent "${OUT2}.zip" "no zip left behind after secret detection"
assert_file_contains "${TEST_TMP}/err.txt" "leak.key" "failure names the offending path"
( cd "${SUPER}"; git rm -q -f leak.key; git commit -qm unleak )

# --- 4. mutation: pre-fix unfiltered behaviour MUST leak on this fixture -----
OLD="${TEST_TMP}/old_build_archive.sh"
cat > "${OLD}" <<'OLDEOF'
set -euo pipefail
old_build_archive() {
  local src="$1" out="$2"; src="$(cd "${src}" && pwd)"
  local parent base; parent="$(dirname "${src}")"; base="$(basename "${src}")"
  tar --exclude='*/build/*' -czf "${out}.tar.gz" -C "${parent}" "${base}"
  ( cd "${parent}" && zip -qr "${out}.zip" "${base}" -x "*/build/*" )
}
OLDEOF
# shellcheck disable=SC1090  # OLD is a generated temp file (the pre-fix script body), not resolvable statically
( source "${OLD}"; old_build_archive "${SUPER}" "${TEST_TMP}/o/old" )
LO="$(list_both "${TEST_TMP}/o/old")"
rc=0; contains_path "${LO}" ".env" || rc=$?
assert_eq 0 "${rc}" "MUTATION: old unfiltered script leaks planted .env (test can fail)"
rc=0; contains_path "${LO}" "cert/ca/ca.key" || rc=$?
assert_eq 0 "${rc}" "MUTATION: old unfiltered script leaks cert/ca/ca.key (test can fail)"

# --- 5. deny-list unit table: EVERY class + every exemption-escape path (C-03 / C-21) ----------
# Each row is its own mutation target: dropping any one class from the predicate fails its row.
# shellcheck disable=SC1090
source "${LLMCTL_ROOT}/scripts/release/build_archive.sh"
denied=(
  ".env" "app/.env" ".ENV" "x/.Env.local" ".env.production" "a/b/.env.staging"
  "server.key" "x/ca.KEY" "tls/server.pem" "dir/Cert.PEM" "k/store.p12" "k/store.pfx" "k/app.jks" "k/app.keystore"
  "id_rsa" "home/.ssh/id_rsa.pub" "id_ed25519" "x/id_ed25519_sk" "id_ecdsa" "id_dsa"
  "home/.netrc" ".pgpass" "x/.PGPASS" "credentials.json" "gcp/credentials-prod.json"
  "cert/ca.crt" "x/cert/ca/ca.crt" "tests/fixtures/cert/ca.key"
  # exemption escapes of the old case-glob: `*` matched across `/`
  "submodules/a/b/docs/x.pem" "submodules/llama.cpp/vendor/docs/.env" "tests/fixtures/real/.env"
  "tests/fixtures/cert/ca.key" "submodules/x/docs/y/z.key" "secrets/creds.p12"
)
for pth in "${denied[@]}"; do
  rc=0; _ba_is_secret_path "${pth}" || rc=$?
  assert_eq 0 "${rc}" "denied: ${pth}"
done
allowed_ok=( ".env.example" "x/.env.example" "README.md" "lib/keyring.sh" "docs/monkey.md" "src/keystone.go" "certificate.md" "tests/test_certs.sh" "x/.git/config" "submodules/llama.cpp/docs/development/llama-star/idea-arch.key" "submodules/containers/tests/configs/.env.docker" )
for pth in "${allowed_ok[@]}"; do
  rc=0; _ba_is_secret_path "${pth}" || rc=$?
  assert_eq 1 "${rc}" "allowed (control, no false positive): ${pth}"
done
# the manifest exemption is an EXACT line: a sibling of a listed file is still denied
rc=0; _ba_is_secret_path "submodules/llama.cpp/docs/development/llama-star/other.key" || rc=$?
assert_eq 0 "${rc}" "a sibling of an exempted file is NOT exempt (exact-path exemption, no subtree)"
# a glob entry in a manifest is refused
printf 'tests/fixtures/*\n' > "${TEST_TMP}/glob.txt"
rc=0; ( export BA_PUBLIC_ALLOWLIST="${TEST_TMP}/glob.txt"; _BA_ALLOW_LOADED=0; _ba_load_allow ) >/dev/null 2>"${TEST_TMP}/glob.err" || rc=$?
assert_eq 1 "${rc}" "a glob entry in an allow manifest is refused"
assert_file_contains "${TEST_TMP}/glob.err" "no globs" "...with the reason"
printf '# public\ntests/fixtures/ok/public.pem\n' > "${TEST_TMP}/ok.txt"
rc=0; ( export BA_PUBLIC_ALLOWLIST="${TEST_TMP}/ok.txt"; _BA_ALLOW_LOADED=0; _ba_is_secret_path tests/fixtures/ok/public.pem ) || rc=$?
assert_eq 1 "${rc}" "a path listed EXACTLY in a manifest is exempt"
rc=0; ( export BA_PUBLIC_ALLOWLIST="${TEST_TMP}/ok.txt"; _BA_ALLOW_LOADED=0; _ba_is_secret_path tests/fixtures/ok/private.pem ) || rc=$?
assert_eq 0 "${rc}" "...and its unlisted neighbour is not"

# --- 6. the independent scanner (python tarfile/zipfile), one archive per class --------------------
SC="${LLMCTL_ROOT}/scripts/release/scan_archive.py"
mkarc() { # mkarc <dir-name> <path> <content>  -> $TEST_TMP/arc/<name>.tar.gz
  local d="${TEST_TMP}/arc/$1/root"; rm -rf "${TEST_TMP}/arc/$1"; mkdir -p "$(dirname "${d}/$2")"
  printf '%b' "$3" > "${d}/$2"
  ( cd "${TEST_TMP}/arc/$1" && tar -czf ../"$1".tar.gz root && zip -qr ../"$1".zip root )
}
for cls in ".env" "x/.ENV.local" "a.key" "b.PEM" "c.p12" "d.pfx" "e.jks" "f.keystore" "id_rsa" "id_ed25519" ".netrc" ".pgpass" "credentials.json" "cert/ca.crt"; do
  n="cls_$(printf '%s' "${cls}" | tr -c 'A-Za-z0-9' '_')"
  mkarc "${n}" "${cls}" 'x\n'
  rc=0; python3 -I "${SC}" "${TEST_TMP}/arc/${n}.tar.gz" "${TEST_TMP}/arc/${n}.zip" 2>"${TEST_TMP}/sc.err" || rc=$?
  assert_eq 1 "${rc}" "scan_archive flags ${cls}"
  assert_file_contains "${TEST_TMP}/sc.err" "${cls}" "scan_archive names ${cls}"
done
mkarc ctl "docs/readme.md" '# fine\n'
rc=0; python3 -I "${SC}" "${TEST_TMP}/arc/ctl.tar.gz" "${TEST_TMP}/arc/ctl.zip" || rc=$?
assert_eq 0 "${rc}" "scan_archive passes a clean archive (control)"
mkarc pem "src/blob.txt" '-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEAxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\nabcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRS\n-----END RSA PRIVATE KEY-----\n'
rc=0; python3 -I "${SC}" "${TEST_TMP}/arc/pem.tar.gz" "${TEST_TMP}/arc/pem.zip" 2>"${TEST_TMP}/sc.err" || rc=$?
assert_eq 1 "${rc}" "scan_archive flags a PEM private-key block in a content file"
mkarc pemquote "src/scan.py" 'HDR = "-----BEGIN RSA PRIVATE KEY-----"\n'
rc=0; python3 -I "${SC}" "${TEST_TMP}/arc/pemquote.tar.gz" "${TEST_TMP}/arc/pemquote.zip" || rc=$?
assert_eq 0 "${rc}" "...but a source line merely QUOTING the header is not a key block"
# --- 6b. C2-16: the scanner descends into NESTED archives (a tracked archive/llmctl.zip ships in every release) ---
mknested() { # mknested <name> <inner-path> <content>: outer.tar.gz and outer.zip each holding inner.zip + inner.tar.gz
  local d="${TEST_TMP}/narc/$1"; rm -rf "${d}"; mkdir -p "${d}/inner/pkg" "${d}/outer/root/archive"
  mkdir -p "${d}/inner/pkg/$(dirname "$2")"; printf '%b' "$3" > "${d}/inner/pkg/$2"
  ( cd "${d}/inner" && zip -qr ../outer/root/archive/inner.zip pkg && tar -czf ../outer/root/archive/inner.tar.gz pkg )
  ( cd "${d}/outer" && tar -czf ../outer.tar.gz root && zip -qr ../outer.zip root )
}
mknested nsec ".env" 'SECRET=1\n'
rc=0; python3 -I "${SC}" "${TEST_TMP}/narc/nsec/outer.tar.gz" "${TEST_TMP}/narc/nsec/outer.zip" 2>"${TEST_TMP}/sc.err" || rc=$?
assert_eq 1 "${rc}" "C2-16: a secret path inside a NESTED archive is flagged"
assert_file_contains "${TEST_TMP}/sc.err" "inner.zip" "C2-16: ...naming the nested zip"
assert_file_contains "${TEST_TMP}/sc.err" "inner.tar.gz" "C2-16: ...and the nested tar.gz"
mknested nkey "src/blob.txt" '-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEAxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\nabcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRS\n-----END RSA PRIVATE KEY-----\n'
rc=0; python3 -I "${SC}" "${TEST_TMP}/narc/nkey/outer.tar.gz" "${TEST_TMP}/narc/nkey/outer.zip" 2>"${TEST_TMP}/sc.err" || rc=$?
assert_eq 1 "${rc}" "C2-16: a PEM private-key block inside a NESTED archive is flagged"
mknested nclean "docs/readme.md" '# fine\n'
rc=0; python3 -I "${SC}" "${TEST_TMP}/narc/nclean/outer.tar.gz" "${TEST_TMP}/narc/nclean/outer.zip" || rc=$?
assert_eq 0 "${rc}" "C2-16: a clean nested archive passes (control: not a blanket refusal)"
rc=0; SCAN_ARCHIVE_MAX_NEST_BYTES=10 python3 -I "${SC}" "${TEST_TMP}/narc/nclean/outer.tar.gz" 2>"${TEST_TMP}/sc.err" || rc=$?
assert_eq 1 "${rc}" "C2-16: a nested archive over the size bound FAILS CLOSED"
assert_file_contains "${TEST_TMP}/sc.err" "too large to scan" "C2-16: ...with the reason"
rc=0; SCAN_ARCHIVE_MAX_NEST_DEPTH=0 python3 -I "${SC}" "${TEST_TMP}/narc/nclean/outer.tar.gz" 2>"${TEST_TMP}/sc.err" || rc=$?
assert_eq 1 "${rc}" "C2-16: a nested archive over the depth bound FAILS CLOSED"
printf 'archive/inner.zip\narchive/inner.tar.gz\n' > "${TEST_TMP}/narc/allow.txt"
rc=0; python3 -I "${SC}" --allow "${TEST_TMP}/narc/allow.txt" "${TEST_TMP}/narc/nsec/outer.tar.gz" || rc=$?
assert_eq 0 "${rc}" "C2-16: an EXACT allow entry is the explicit opt-out for a nested archive"
mkarc gitstate ".git/refs/stash" 'abc\n'
rc=0; python3 -I "${SC}" "${TEST_TMP}/arc/gitstate.tar.gz" "${TEST_TMP}/arc/gitstate.zip" 2>"${TEST_TMP}/sc.err" || rc=$?
assert_eq 1 "${rc}" "scan_archive flags a shipped stash ref"
mkarc gitcfg ".git/config" '[remote "origin"]\n\turl = https://bob:ghp_abc@example.com/x.git\n'
rc=0; python3 -I "${SC}" "${TEST_TMP}/arc/gitcfg.tar.gz" "${TEST_TMP}/arc/gitcfg.zip" 2>"${TEST_TMP}/sc.err" || rc=$?
assert_eq 1 "${rc}" "scan_archive flags a git config remote with embedded credentials"

# --- 6c. C3-05 / C3-15(S2): nested-archive scanning is not defeated by a single top directory, allow entries are qualified,
# and the DECOMPRESSED size is budgeted (zip bomb) ------------------------------------------------------------------------
mknest2() { # mknest2 <name> <inner-kind zip|tgz> <member...>: nested archive holding the given members, wrapped in outer.tar.gz
  local n="$1" kind="$2"; shift 2
  local d="${TEST_TMP}/n2/${n}"; rm -rf "${d}"; mkdir -p "${d}/inner" "${d}/outer/root/archive"
  local m; for m in "$@"; do mkdir -p "${d}/inner/$(dirname "${m}")"; printf 'x\n' > "${d}/inner/${m}"; done
  # shellcheck disable=SC2046  # intentional: member names are plain test words
  if [[ "${kind}" == zip ]]; then ( cd "${d}/inner" && zip -qr "../outer/root/archive/n.zip" $(printf '%s\n' "$@" | cut -d/ -f1 | sort -u) )
  else ( cd "${d}/inner" && tar -czf "../outer/root/archive/n.tgz" $(printf '%s\n' "$@" | cut -d/ -f1 | sort -u) ); fi
  ( cd "${d}/outer" && tar -czf ../outer.tar.gz root )
}
mknest2 envtop tgz ".env/prod"
rc=0; python3 -I "${SC}" "${TEST_TMP}/n2/envtop/outer.tar.gz" 2>"${TEST_TMP}/sc.err" || rc=$?
assert_eq 1 "${rc}" "C3-05: a nested archive whose single top directory IS '.env/' is flagged (top not stripped away)"
assert_file_contains "${TEST_TMP}/sc.err" ".env/prod" "C3-05: ...naming the unstripped path"
mknest2 certtop zip "cert/README"
rc=0; python3 -I "${SC}" "${TEST_TMP}/n2/certtop/outer.tar.gz" 2>"${TEST_TMP}/sc.err" || rc=$?
assert_eq 1 "${rc}" "C3-05: a nested zip whose single top directory is 'cert/' is flagged"
mknest2 notop tgz ".env" "README"
rc=0; python3 -I "${SC}" "${TEST_TMP}/n2/notop/outer.tar.gz" 2>"${TEST_TMP}/sc.err" || rc=$?
assert_eq 1 "${rc}" "C3-15/S2: a nested archive WITHOUT a common top (a top-level .env) is flagged (strip only for a single top)"
mknest2 twotops tgz "a/.env" "b/x"
rc=0; python3 -I "${SC}" "${TEST_TMP}/n2/twotops/outer.tar.gz" 2>"${TEST_TMP}/sc.err" || rc=$?
assert_eq 1 "${rc}" "C3-15/S2: two tops, a/.env flagged"
mknest2 clean2 tgz "pkg/docs/readme.md"
rc=0; python3 -I "${SC}" "${TEST_TMP}/n2/clean2/outer.tar.gz" || rc=$?
assert_eq 0 "${rc}" "C3-05 control: a clean nested archive with a single top passes"
# allow entries apply ONLY to the path they were granted for: a plain repo-relative entry must not exempt the same
# relative path INSIDE a nested archive; the nested form is '<outer-path>!<inner-path>'
mknest2 allowk zip "pkg/docs/x.key"
printf 'docs/x.key\n' > "${TEST_TMP}/n2/allow_plain.txt"
rc=0; python3 -I "${SC}" --allow "${TEST_TMP}/n2/allow_plain.txt" "${TEST_TMP}/n2/allowk/outer.tar.gz" 2>"${TEST_TMP}/sc.err" || rc=$?
assert_eq 1 "${rc}" "C3-05: a plain allow entry does NOT exempt that path inside a nested archive"
printf 'archive/n.zip!docs/x.key\n' > "${TEST_TMP}/n2/allow_nested.txt"
rc=0; python3 -I "${SC}" --allow "${TEST_TMP}/n2/allow_nested.txt" "${TEST_TMP}/n2/allowk/outer.tar.gz" 2>"${TEST_TMP}/sc.err" || rc=$?
assert_eq 0 "${rc}" "C3-05: the qualified '<outer>!<inner>' entry exempts exactly that nested path"
printf 'archive/other.zip!docs/x.key\n' > "${TEST_TMP}/n2/allow_wrong.txt"
rc=0; python3 -I "${SC}" --allow "${TEST_TMP}/n2/allow_wrong.txt" "${TEST_TMP}/n2/allowk/outer.tar.gz" 2>/dev/null || rc=$?
assert_eq 1 "${rc}" "C3-05: ...and a qualified entry for a DIFFERENT outer path exempts nothing"
# decompressed-size budget: a tiny nested tar.gz that inflates far beyond the budget FAILS CLOSED, quickly
BOMB="${TEST_TMP}/n2/bomb"; mkdir -p "${BOMB}/outer/root/archive"
python3 -I - "${BOMB}/outer/root/archive/bomb.tgz" <<'PYEOF'
import sys, tarfile, io
with tarfile.open(sys.argv[1], "w:gz", compresslevel=1) as tf:
    ti = tarfile.TarInfo("pkg/zeros.bin"); ti.size = 64 * 1024 * 1024
    class Z(io.RawIOBase):
        def __init__(s): s.left = ti.size
        def readable(s): return True
        def readinto(s, b):
            n = min(len(b), s.left); b[:n] = bytes(n); s.left -= n; return n
    tf.addfile(ti, io.BufferedReader(Z()))
PYEOF
( cd "${BOMB}/outer" && tar -czf ../outer.tar.gz root )
assert_eq 1 "$(( $(stat -c%s "${BOMB}/outer/root/archive/bomb.tgz" 2>/dev/null || stat -f%z "${BOMB}/outer/root/archive/bomb.tgz") < 1048576 ? 1 : 0 ))" "C3-05 fixture: the bomb is tiny compressed (<1 MiB)"
t0="$(date +%s)"
rc=0; SCAN_ARCHIVE_MAX_NEST_DECOMPRESSED=$((1024*1024)) python3 -I "${SC}" "${BOMB}/outer.tar.gz" 2>"${TEST_TMP}/sc.err" || rc=$?
t1="$(date +%s)"
assert_eq 1 "${rc}" "C3-05: a nested archive inflating beyond the decompressed budget FAILS CLOSED"
assert_file_contains "${TEST_TMP}/sc.err" "decompress" "C3-05: ...with the reason"
assert_eq 1 "$(( t1 - t0 < 10 ? 1 : 0 ))" "C3-05: ...and refuses quickly (streamed budget, not a full inflate)"
rc=0; python3 -I "${SC}" "${BOMB}/outer.tar.gz" 2>/dev/null || rc=$?
assert_eq 0 "${rc}" "C3-05 control: the same 64 MiB nested archive is accepted under the default budget (not a blanket refusal)"

# --- 7. C-02: the shipped .git carries ONLY the release commit's history -----------------------------
W2="${TEST_TMP}/gx"; mkdir -p "${W2}"
SUB2="${W2}/subup"; git init -q "${SUB2}"
( cd "${SUB2}"; git config user.email t@e.x; git config user.name t; echo s > s.txt; git add -A; git commit -qm s )
SUP2="${W2}/super"; git init -q "${SUP2}"
( cd "${SUP2}"; git config user.email t@e.x; git config user.name t
  git -c protocol.file.allow=always submodule add -q "file://${SUB2}" sub >/dev/null
  printf '*.log\n' > .gitignore; echo release > rel.txt; git add -A; git commit -qm m
  # (a) a stash holding an untracked .env as a blob
  echo "STASHED-ENV-SECRET-MARKER" > .env; echo wip >> rel.txt
  git stash push -u -q -m wip
  STASH_SHA="$(git rev-parse refs/stash)"
  ENV_BLOB="$(git rev-parse "refs/stash^3:.env")"
  # (b) a local-only branch with its own file
  git checkout -q -b local-only-wip; echo "LOCAL-ONLY-BRANCH-MARKER" > only_on_branch.txt; git add -A; git commit -qm lw
  LOCAL_SHA="$(git rev-parse HEAD)"
  git checkout -q -
  # (c) a remote URL with an embedded token, a credential helper, an executable hook
  git remote add origin "https://ci-user:ghp_TOKENMARKER123@example.invalid/x.git"
  git config credential.helper store
  printf '#!/bin/sh\necho HOOK-MARKER\n' > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit
  # (d) the SUBMODULE gets the same treatment
  cd sub; echo SUBSTASH-MARKER > .env; git stash push -u -q -m w2; SUBBLOB="$(git rev-parse 'refs/stash^3:.env')"
  git remote set-url origin "https://u:SUBTOKEN456@example.invalid/s.git"; cd ..
  printf '%s %s %s %s\n' "${STASH_SHA}" "${ENV_BLOB}" "${LOCAL_SHA}" "${SUBBLOB}" > "${TEST_TMP}/shas.txt" )
read -r STASH_SHA ENV_BLOB LOCAL_SHA SUBBLOB < "${TEST_TMP}/shas.txt"
OUT3="${TEST_TMP}/o/gx"; build_archive "${SUP2}" "${OUT3}"
for fmt in tar zip; do
  X="${TEST_TMP}/x_${fmt}"; rm -rf "${X}"; mkdir -p "${X}"
  if [[ ${fmt} == tar ]]; then tar -xzf "${OUT3}.tar.gz" -C "${X}"; else ( cd "${X}" && unzip -q "${OUT3}.zip" ); fi
  R="${X}/super"
  assert_eq "" "$(git -C "${R}" stash list 2>&1)" "${fmt}: no stash in the shipped .git"
  assert_eq "" "$(git -C "${R}" for-each-ref refs/stash 2>&1)" "${fmt}: no refs/stash"
  rc=0; git -C "${R}" cat-file -e "${ENV_BLOB}" 2>/dev/null || rc=$?
  assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "${fmt}: the stashed .env BLOB is not in the object store"
  rc=0; git -C "${R}" cat-file -e "${STASH_SHA}" 2>/dev/null || rc=$?
  assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "${fmt}: the stash commit is not in the object store"
  rc=0; git -C "${R}" cat-file -e "${LOCAL_SHA}" 2>/dev/null || rc=$?
  assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "${fmt}: the local-only branch commit is not in the object store"
  assert_eq "" "$(git -C "${R}" branch --list local-only-wip)" "${fmt}: the local-only branch is not shipped"
  assert_eq "" "$(git -C "${R}" remote -v)" "${fmt}: no remote configured"
  rc=0; grep -rq -e "TOKENMARKER" -e "SUBTOKEN" -e "credential" "${R}/.git" 2>/dev/null || rc=$?
  assert_eq 1 "${rc}" "${fmt}: no token / credential helper anywhere under .git"
  assert_eq "" "$(find "${R}/.git" "${R}/.git/hooks" -path '*hooks/*' -type f 2>/dev/null)" "${fmt}: no hook shipped"
  assert_eq "" "$(find "${R}/.git" -path '*logs*' -type f 2>/dev/null)" "${fmt}: no reflog shipped"
  rc=0; git -C "${R}/sub" cat-file -e "${SUBBLOB}" 2>/dev/null || rc=$?
  assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "${fmt}: the SUBMODULE's stashed .env blob is not shipped"
  assert_eq "" "$(git -C "${R}/sub" remote -v)" "${fmt}: no submodule remote"
  assert_eq "$(git -C "${SUP2}" rev-parse HEAD)" "$(git -C "${R}" rev-parse HEAD)" "${fmt}: the release commit itself is present (control)"
  assert_eq "$(git -C "${SUP2}/sub" rev-parse HEAD)" "$(git -C "${R}/sub" rev-parse HEAD)" "${fmt}: the submodule release commit is present (control)"
  assert_eq "release" "$(cat "${R}/rel.txt" | head -1)" "${fmt}: the working-tree file is shipped (control)"
done

# --- 8. C2-05: the shipped .git carries the HEAD history, so the history is judged too (by PATH) ---------------------
# A secret committed in one commit and `git rm`'d in the next is absent from the work tree but its blob ships in
# the bundle. Control needles: a deleted benign file must pass; an EXACT allow entry is the opt-out.
W5="${TEST_TMP}/hx"; mkdir -p "${W5}"
HSUP="${W5}/super"; git init -q "${HSUP}"
( cd "${HSUP}"; git config user.email t@e.x; git config user.name t
  echo keep > keep.txt; echo notes > old_notes.txt; git add -A; git commit -qm base
  git rm -q old_notes.txt; git commit -qm "drop benign file" )
HOUT="${TEST_TMP}/o/hist_ok"
rc=0; ( build_archive "${HSUP}" "${HOUT}" ) >/dev/null 2>&1 || rc=$?
assert_eq 0 "${rc}" "C2-05 control: a repo whose history only ever held benign deleted files builds"
( cd "${HSUP}"; echo "OLD-SECRET-LINE" > deploy_old.key; git add -f deploy_old.key; git commit -qm "oops"; git rm -q deploy_old.key; git commit -qm "remove it" )
HOUT2="${TEST_TMP}/o/hist_leak"
rc=0; ( build_archive "${HSUP}" "${HOUT2}" ) >/dev/null 2>"${TEST_TMP}/hist.err" || rc=$?
assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "C2-05: a committed-then-deleted secret in the shipped history makes build_archive fail"
assert_file_contains "${TEST_TMP}/hist.err" "deploy_old.key" "C2-05: ...naming the historical path"
assert_file_absent "${HOUT2}.tar.gz" "C2-05: ...leaving no archive behind"
printf 'deploy_old.key\n' > "${TEST_TMP}/hist_allow.txt"
rc=0; ( BA_PUBLIC_ALLOWLIST="${TEST_TMP}/hist_allow.txt:${LLMCTL_ROOT}/scripts/release/public_allowlist.txt"; export BA_PUBLIC_ALLOWLIST; _BA_ALLOW_LOADED=0; build_archive "${HSUP}" "${TEST_TMP}/o/hist_allowed" ) >/dev/null 2>&1 || rc=$?
assert_eq 0 "${rc}" "C2-05: an EXACT allow entry exempts that historical path"
# the submodule's own history is judged with the full repo-relative path
HSUB="${W5}/subup"; git init -q "${HSUB}"
( cd "${HSUB}"; git config user.email t@e.x; git config user.name t; echo s > s.txt; echo K > gone.pem; git add -f -A; git commit -qm s; git rm -q gone.pem; git commit -qm rm )
HSUP2="${W5}/super2"; git init -q "${HSUP2}"
( cd "${HSUP2}"; git config user.email t@e.x; git config user.name t
  git -c protocol.file.allow=always submodule add -q "file://${HSUB}" sub >/dev/null; git add -A; git commit -qm m )
rc=0; ( build_archive "${HSUP2}" "${TEST_TMP}/o/hist_sub" ) >/dev/null 2>"${TEST_TMP}/hist2.err" || rc=$?
assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "C2-05: a deleted secret in a SUBMODULE's history fails the build"
assert_file_contains "${TEST_TMP}/hist2.err" "sub/gone.pem" "C2-05: ...named with the full repo-relative path"

# --- 8b. C3-03/C3-04: history is walked PATH-BY-PATH and NUL-safely -----------------------------------------------------
# `rev-list --objects` lists every blob ONCE (under the first path it meets) and cuts a path at its first newline, so a
# duplicate-content secret path and a newline-named key escaped. The walk is `git log -m --no-renames --name-only -z`.
W6="${TEST_TMP}/hy"; mkdir -p "${W6}"
H3="${W6}/super"; git init -q "${H3}"
( cd "${H3}"; git config user.email t@e.x; git config user.name t
  echo keep > keep.txt; git add -A; git commit -qm base
  printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\n-----END OPENSSH PRIVATE KEY-----\n' > "$(printf 'notes\nid_rsa')"
  git add -A; git commit -qm "newline-named key"; git rm -q -- "$(printf 'notes\nid_rsa')"; git commit -qm rm )
rc=0; ( build_archive "${H3}" "${TEST_TMP}/o/hist_nl" ) >/dev/null 2>"${TEST_TMP}/hist3.err" || rc=$?
assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "C3-03: a newline-named key committed then deleted fails the build"
assert_file_contains "${TEST_TMP}/hist3.err" "newline" "C3-03: ...saying the historical path holds a newline"
assert_file_absent "${TEST_TMP}/o/hist_nl.tar.gz" "C3-03: ...leaving no archive behind"
H4="${W6}/super2"; git init -q "${H4}"
( cd "${H4}"; git config user.email t@e.x; git config user.name t
  echo same > a.txt; echo same > b.key; git add -f -A; git commit -qm dup; git rm -q b.key; git commit -qm rm )
rc=0; ( build_archive "${H4}" "${TEST_TMP}/o/hist_dup" ) >/dev/null 2>"${TEST_TMP}/hist4.err" || rc=$?
assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "C3-04: a deleted secret PATH whose blob is identical to another path's is still judged"
assert_file_contains "${TEST_TMP}/hist4.err" "b.key" "C3-04: ...naming the duplicate-content path"
# an allow entry that is consulted exempts exactly that historical path; one that matches nothing is REPORTED
printf 'b.key\nnever/existed.key\n' > "${TEST_TMP}/hist4_allow.txt"
rc=0; ( BA_PUBLIC_ALLOWLIST="${TEST_TMP}/hist4_allow.txt"; export BA_PUBLIC_ALLOWLIST; _BA_ALLOW_LOADED=0; build_archive "${H4}" "${TEST_TMP}/o/hist_dup_ok" ) >/dev/null 2>"${TEST_TMP}/hist4b.err" || rc=$?
assert_eq 0 "${rc}" "C3-04: the exact allow entry for the duplicate-content historical path is consulted and exempts it"
assert_file_contains "${TEST_TMP}/hist4b.err" "unused allow entry: never/existed.key" "C3-04: an allow entry matching no tree/history path is reported"
assert_eq 0 "$(grep -c 'unused allow entry: b.key' "${TEST_TMP}/hist4b.err" || true)" "C3-04: ...but a consulted entry is not reported as unused"

test_finish
