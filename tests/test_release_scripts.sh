#!/usr/bin/env bash
# test_release_scripts.sh - T126 (FR-084, OD-4): scripts/release.sh against a
# throwaway git repo fixture. Golden-good + golden-bad per subcommand. NEVER
# pushes, never touches a network, never runs real gh/glab (PATH-injected fakes
# record any call; the test asserts there were none).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
REL="${LLMCTL_ROOT}/scripts/release.sh"

FX="${TEST_TMP}/fx"; OUT="${TEST_TMP}/out"
git init -q "${FX}"
(
  cd "${FX}"
  git config user.email t@example.invalid; git config user.name t
  printf 'MIT License\n\nPermission is hereby granted, free of charge\n' > LICENSE
  printf 'hello\n' > a.txt; mkdir sub; printf 'b\n' > sub/b.txt
  printf 'module example.com/fx\n\ngo 1.25.0\n\nrequire github.com/gin-gonic/gin v1.12.0\n\nrequire (\n\tgithub.com/x/y v0.3.1 // indirect\n)\n' > go.mod
  printf 'github.com/gin-gonic/gin v1.12.0 h1:abc=\ngithub.com/gin-gonic/gin v1.12.0/go.mod h1:def=\ngithub.com/x/y v0.3.1 h1:ghi=\n' > go.sum
  printf '[submodule "submodules/eng"]\n\tpath = submodules/eng\n\turl = git@example.invalid:o/eng.git\n' > .gitmodules
  git add -A
  git update-index --add --cacheinfo 160000,4a8f04e05f3535d77c48f69b89687f9fcc896fbf,submodules/eng
  GIT_COMMITTER_DATE="2026-01-02T03:04:05Z" git commit -q -m init --date="2026-01-02T03:04:05Z"
  git tag -a v9.9.9 -m "release v9.9.9"
)
R=(--root "${FX}" --out "${OUT}" --tag v9.9.9)

# fake gh/glab: record calls
FAKEBIN="${TEST_TMP}/bin"; mkdir -p "${FAKEBIN}"
for t in gh glab; do printf '#!/bin/sh\necho "%s $*" >> "%s/calls.log"\n' "$t" "${TEST_TMP}" > "${FAKEBIN}/$t"; chmod +x "${FAKEBIN}/$t"; done
export PATH="${FAKEBIN}:${PATH}"

# --- verify-tag ---------------------------------------------------------------
rc=0; "${REL}" "${R[@]}" verify-tag >/dev/null 2>&1 || rc=$?
assert_eq 0 "${rc}" "verify-tag: annotated tag at HEAD, clean tree accepted"
rc=0; "${REL}" --root "${FX}" --out "${OUT}" --tag v0.0.0 verify-tag >/dev/null 2>&1 || rc=$?
assert_eq 1 "${rc}" "verify-tag: missing tag refused"
(cd "${FX}" && git tag lightweight-1)
rc=0; "${REL}" --root "${FX}" --out "${OUT}" --tag lightweight-1 verify-tag >/dev/null 2>&1 || rc=$?
assert_eq 1 "${rc}" "verify-tag: lightweight (non-annotated) tag refused"
(cd "${FX}" && printf 'x\n' > c.txt && git add c.txt && git commit -q -m second)
rc=0; "${REL}" "${R[@]}" verify-tag >/dev/null 2>&1 || rc=$?
assert_eq 1 "${rc}" "verify-tag: tag not at HEAD refused"
(cd "${FX}" && git reset -q --hard HEAD~1)
printf 'dirty\n' >> "${FX}/a.txt"
rc=0; "${REL}" "${R[@]}" verify-tag >/dev/null 2>&1 || rc=$?
assert_eq 1 "${rc}" "verify-tag: dirty tree refused"
rc=0; "${REL}" "${R[@]}" --allow-dirty verify-tag >/dev/null 2>&1 || rc=$?
assert_eq 0 "${rc}" "verify-tag: --allow-dirty is the explicit escape"
(cd "${FX}" && git checkout -q -- a.txt)

# --- archive: reproducible ----------------------------------------------------
"${REL}" "${R[@]}" archive >/dev/null
A="${OUT}/llmctl-v9.9.9.tar.gz"
h1="$(sha256sum "${A}" | cut -d' ' -f1)"
sleep 1.1; rm -f "${A}"
"${REL}" "${R[@]}" archive >/dev/null
h2="$(sha256sum "${A}" | cut -d' ' -f1)"
assert_eq "${h1}" "${h2}" "archive: two runs are byte-identical"
lst="$(tar -tzf "${A}")"
assert_contains "${lst}" "a.txt" "archive: tracked file present"
assert_eq "$(printf "%s\n" "${lst}" | LC_ALL=C sort | head -n1)" "$(printf '%s\n' "${lst}" | head -n1)" "archive: entries sorted by name"
own="$(tar -tvzf "${A}" | awk '{print $2}' | sort -u)"
assert_eq "0/0" "${own}" "archive: fixed owner 0/0"
assert_eq "2026-01-02" "$(tar -tvzf "${A}" | awk '{print $4}' | sort -u)" "archive: mtime fixed to commit date"
printf 'untracked secret\n' > "${FX}/untracked.env"
rm -f "${A}"; "${REL}" "${R[@]}" archive >/dev/null
case "$(tar -tzf "${A}")" in *untracked.env*) assert_eq "absent" "present" "archive: untracked file excluded";; *) assert_eq 1 1 "archive: untracked file excluded";; esac
rm -f "${FX}/untracked.env"
assert_eq 1 "$(gzip -l "${A}" >/dev/null 2>&1 && printf '%s' "$(head -c10 "${A}" | od -An -tx1 | tr -d ' ' | cut -c9-16 | grep -c '^00000000$')")" "archive: gzip header mtime zero (gzip -n)"

# --- sbom ----------------------------------------------------------------------
"${REL}" "${R[@]}" sbom >/dev/null
S="${OUT}/llmctl-v9.9.9.sbom.cdx.json"
assert_eq "CycloneDX" "$(jq -r .bomFormat "${S}")" "sbom: valid JSON, bomFormat CycloneDX"
assert_eq "1.5" "$(jq -r .specVersion "${S}")" "sbom: specVersion 1.5"
assert_eq "1" "$(jq '[.components[]|select(.purl=="pkg:golang/github.com/gin-gonic/gin@v1.12.0")]|length' "${S}")" "sbom: Go direct module listed"
assert_eq "1" "$(jq '[.components[]|select(.purl=="pkg:golang/github.com/x/y@v0.3.1")]|length' "${S}")" "sbom: Go indirect module listed"
assert_eq "github.com/gin-gonic/gin" "$(jq -r '[.components[]|select(.name=="github.com/gin-gonic/gin")][0].name' "${S}")" "sbom: module name"
assert_eq "4a8f04e05f3535d77c48f69b89687f9fcc896fbf" "$(jq -r '[.components[]|select(.name=="submodules/eng")][0].version' "${S}")" "sbom: submodule pinned commit as version"
assert_eq "NOASSERTION" "$(jq -r '[.components[]|select(.name=="submodules/eng")][0].licenses[0].license.name' "${S}")" "sbom: unpopulated submodule licence is NOASSERTION (not guessed)"
assert_eq "MIT" "$(jq -r '.metadata.component.licenses[0].license.id' "${S}")" "sbom: root licence detected from LICENSE"
# golden-bad: go.mod without go.sum entry is flagged
(cd "${FX}" && printf 'github.com/gin-gonic/gin v1.12.0 h1:abc=\n' > go.sum && git commit -qam nosum && git tag -a v9.9.10 -m x)
"${REL}" --root "${FX}" --out "${OUT}" --tag v9.9.10 sbom >/dev/null
assert_eq "false" "$(jq -r '[.components[]|select(.name=="github.com/x/y")][0].properties[]|select(.name=="llmctl:go.sum-hash")|.value' "${OUT}/llmctl-v9.9.10.sbom.cdx.json")" "sbom: module lacking go.sum hash is marked false"
(cd "${FX}" && git reset -q --hard v9.9.9 && git tag -d v9.9.10 >/dev/null)

# --- notice --------------------------------------------------------------------
"${REL}" "${R[@]}" notice >/dev/null
N="${OUT}/NOTICE-THIRD-PARTY.txt"
assert_file_contains "${N}" "github.com/gin-gonic/gin v1.12.0" "notice: lists Go module"
assert_file_contains "${N}" "submodules/eng" "notice: lists submodule"

# --- checksums: good, tampered ---------------------------------------------------
"${REL}" "${R[@]}" checksums >/dev/null
assert_file_contains "${OUT}/SHA256SUMS" "llmctl-v9.9.9.tar.gz" "checksums: archive listed"
assert_file_contains "${OUT}/SHA256SUMS" "NOTICE-THIRD-PARTY.txt" "checksums: notice listed"
rc=0; "${REL}" "${R[@]}" checksums --verify >/dev/null 2>&1 || rc=$?
assert_eq 0 "${rc}" "checksums --verify: untouched assets verify"
printf 'tamper' >> "${OUT}/NOTICE-THIRD-PARTY.txt"
rc=0; out="$("${REL}" "${R[@]}" checksums --verify 2>&1)" || rc=$?
assert_eq 1 "${rc}" "checksums --verify: tampered asset DETECTED"
assert_contains "${out}" "NOTICE-THIRD-PARTY.txt" "checksums --verify: names the tampered asset"
"${REL}" "${R[@]}" notice >/dev/null

# --- all + publish dry-run ---------------------------------------------------------
rm -rf "${OUT}"
rc=0; "${REL}" "${R[@]}" all >/dev/null 2>&1 || rc=$?
assert_eq 0 "${rc}" "all: runs verify-tag, archive, sbom, notice, checksums"
rc=0; "${REL}" "${R[@]}" checksums --verify >/dev/null 2>&1 || rc=$?
assert_eq 0 "${rc}" "all: SHA256SUMS verifies"
pub="$("${REL}" "${R[@]}" --publish all 2>&1)"
assert_contains "${pub}" "gh release create v9.9.9" "publish (no env guard): prints gh command"
assert_contains "${pub}" "glab release create v9.9.9" "publish (no env guard): prints glab command"
assert_contains "${pub}" "DRY-RUN" "publish (no env guard): labelled dry-run"
assert_eq "no" "$([[ -s "${TEST_TMP}/calls.log" ]] && echo yes || echo no)" "publish: fake gh/glab were NEVER invoked"
assert_eq "0" "$(git -C "${FX}" remote | wc -l)" "fixture has no remotes (nothing could be pushed)"
test_finish
