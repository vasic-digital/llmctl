#!/usr/bin/env bash
# release.sh - T126 (spec 009 FR-084, OD-4): release assets for llmctl.
#
# Usage: release.sh [--root DIR] [--out DIR] [--tag TAG] [--allow-dirty]
#                   [--publish] <assets|verify-tag|archive|checksums [--verify]|sbom|notice|all>
#
#   assets      list the asset set and whether each exists in --out
#   verify-tag  TAG must exist, be ANNOTATED, peel to HEAD; tree must be clean
#   archive     reproducible llmctl-<TAG>.tar.gz of TRACKED files (sorted names,
#               owner 0/0, mtime = commit date, gzip -n). Submodule CONTENT is not
#               included; it is pinned in the SBOM (use build_archive.sh for the
#               self-contained tree).
#   checksums   SHA256SUMS over the assets; `--verify` re-checks and fails on tamper
#   sbom        CycloneDX 1.5 JSON: Go modules (go.mod + go.sum hash presence),
#               submodules (pinned commit from the gitlink), licences (NOASSERTION
#               when a licence cannot be read - never guessed)
#   notice      NOTICE-THIRD-PARTY.txt
#   all         verify-tag, archive, sbom, notice, [signature], checksums
#
# Safety: nothing here pushes, tags or publishes. `--publish` only PRINTS the exact
# gh/glab commands (DRY-RUN) unless LLMCTL_RELEASE_PUBLISH=1 is also exported.
# Optional signature: LLMCTL_RELEASE_SIGN=1 and gpg present -> SHA256SUMS.asc.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; OUT=""; TAG=""; ALLOW_DIRTY=0; PUBLISH=0; CMD=""; VERIFY=0
while (($#)); do
  case "$1" in
    --root) ROOT="$(cd "$2" && pwd)"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --tag) TAG="$2"; shift 2;;
    --allow-dirty) ALLOW_DIRTY=1; shift;;
    --publish) PUBLISH=1; shift;;
    --verify) VERIFY=1; shift;;
    assets|verify-tag|archive|checksums|sbom|notice|all) CMD="$1"; shift;;
    *) echo "release.sh: unknown argument: $1" >&2; exit 2;;
  esac
done
[[ -n "${CMD}" ]] || { echo "release.sh: subcommand required" >&2; exit 2; }
[[ -n "${TAG}" ]] || TAG="$(git -C "${ROOT}" describe --tags --abbrev=0 2>/dev/null || true)"
[[ -n "${TAG}" ]] || { echo "release.sh: --tag required (none derivable)" >&2; exit 2; }
[[ -n "${OUT}" ]] || OUT="${ROOT}/dist"
G() { git -C "${ROOT}" "$@"; }
NAME="llmctl-${TAG}"
ARCHIVE="${NAME}.tar.gz"; SBOM="${NAME}.sbom.cdx.json"; NOTICE="NOTICE-THIRD-PARTY.txt"

cmd_verify_tag() {
  G rev-parse -q --verify "refs/tags/${TAG}" >/dev/null || { echo "verify-tag: tag ${TAG} does not exist" >&2; return 1; }
  [[ "$(G cat-file -t "refs/tags/${TAG}")" == tag ]] || { echo "verify-tag: ${TAG} is not an annotated tag" >&2; return 1; }
  local at head; at="$(G rev-parse "${TAG}^{commit}")"; head="$(G rev-parse HEAD)"
  [[ "${at}" == "${head}" ]] || { echo "verify-tag: ${TAG} -> ${at} but HEAD is ${head}" >&2; return 1; }
  if ((ALLOW_DIRTY==0)) && [[ -n "$(G status --porcelain --untracked-files=no --ignore-submodules=all)" ]]; then
    echo "verify-tag: working tree has tracked modifications (use --allow-dirty to override explicitly)" >&2; return 1
  fi
  echo "verify-tag: ok ${TAG} -> ${head}"
}

cmd_archive() {
  mkdir -p "${OUT}"
  local ct list; ct="$(G log -1 --format=%ct "${TAG}^{commit}")"; list="$(mktemp)"
  # tracked non-gitlink files, byte-sorted
  G ls-files -s -z | python3 -c '
import sys
for e in sys.stdin.buffer.read().split(b"\0"):
    if not e: continue
    meta, path = e.split(b"\t",1)
    if meta.split()[0]==b"160000": continue
    sys.stdout.buffer.write(path+b"\0")' | LC_ALL=C sort -z > "${list}"
  (cd "${ROOT}" && LC_ALL=C tar --null --no-recursion --sort=name --mtime="@${ct}" \
      --owner=0 --group=0 --numeric-owner --format=gnu --transform "s,^,${NAME}/," -T "${list}" -cf -) \
    | gzip -n -9 > "${OUT}/${ARCHIVE}"
  rm -f "${list}"; echo "archive: ${OUT}/${ARCHIVE}"
}

# parse go.mod/go.sum/.gitmodules/gitlinks -> JSON model on stdout
model() {
  ROOT="${ROOT}" python3 - <<'PY'
import json, os, re, subprocess
root=os.environ["ROOT"]
def git(*a):
    return subprocess.run(["git","-C",root,*a],capture_output=True,text=True)
def detect(path, extra=True):
    t=open(path,errors="replace").read(400).lower()
    table=[("mit license","MIT"),("apache license","Apache-2.0"),("gnu general public","GPL-3.0-or-later")]
    if extra: table.append(("bsd","BSD-3-Clause"))
    for needle,sp in table:
        if needle in t: return sp
    return "NOASSERTION"
mods=[]; seen=set()
try: gomod=open(os.path.join(root,"go.mod")).read()
except OSError: gomod=""
sums=set()
try:
    for l in open(os.path.join(root,"go.sum")):
        p=l.split()
        if len(p)==3 and not p[1].endswith("/go.mod"): sums.add((p[0],p[1]))
except OSError: pass
inblock=False
for raw in gomod.splitlines():
    l=raw.strip()
    if l.startswith("require ("): inblock=True; continue
    if inblock and l==")": inblock=False; continue
    m=None
    if inblock: m=re.match(r"(\S+)\s+(\S+)(.*)",l)
    elif l.startswith("require "): m=re.match(r"require\s+(\S+)\s+(\S+)(.*)",l)
    if m and (m.group(1),m.group(2)) not in seen:
        seen.add((m.group(1),m.group(2)))
        mods.append(dict(name=m.group(1),version=m.group(2),indirect="// indirect" in m.group(3),
                         sumhash=(m.group(1),m.group(2)) in sums))
subs=[]
gm=os.path.join(root,".gitmodules")
if os.path.exists(gm):
    r=subprocess.run(["git","config","-f",gm,"--get-regexp",r"^submodule\..*\.(path|url)$"],capture_output=True,text=True).stdout
    d={}
    for l in r.splitlines():
        k,v=l.split(" ",1); n,f=k[len("submodule."):].rsplit(".",1); d.setdefault(n,{})[f]=v
    for n,v in sorted(d.items(), key=lambda x:x[1].get("path","")):
        p=v.get("path")
        ls=git("ls-tree","HEAD","--",p).stdout.split()
        sha=ls[2] if len(ls)>=3 and ls[0]=="160000" else "UNKNOWN"
        lic="NOASSERTION"
        for c in ("LICENSE","LICENSE.md","COPYING","LICENSE.txt"):
            fp=os.path.join(root,p,c)
            if os.path.isfile(fp): lic=detect(fp); break
        subs.append(dict(name=p,url=v.get("url",""),commit=sha,license=lic))
rootlic="NOASSERTION"
fp=os.path.join(root,"LICENSE")
if os.path.isfile(fp): rootlic=detect(fp,False)
print(json.dumps(dict(mods=mods,subs=subs,rootlic=rootlic,
      commit=git("rev-parse","HEAD").stdout.strip(),
      ct=git("log","-1","--format=%cI","HEAD").stdout.strip())))
PY
}

cmd_sbom() {
  mkdir -p "${OUT}"
  model | jq --arg tag "${TAG}" '
    def lic(x): if x=="NOASSERTION" then [{license:{name:"NOASSERTION"}}] else [{license:{id:x}}] end;
    {
      bomFormat:"CycloneDX", specVersion:"1.5", version:1,
      serialNumber:("urn:uuid:00000000-0000-0000-0000-" + (.commit[0:12])),
      metadata:{ timestamp:.ct,
        tools:[{vendor:"llmctl",name:"scripts/release.sh"}],
        component:{type:"application",name:"llmctl",version:$tag,licenses:lic(.rootlic),
                   properties:[{name:"llmctl:commit",value:.commit}]} },
      components: (
        [ .mods[] | {type:"library", name:.name, version:.version,
            purl:("pkg:golang/"+.name+"@"+.version),
            scope:(if .indirect then "optional" else "required" end),
            licenses:[{license:{name:"NOASSERTION"}}],
            properties:[{name:"llmctl:go.sum-hash",value:(.sumhash|tostring)}] } ]
        + [ .subs[] | {type:"library", name:.name, version:.commit,
            licenses:lic(.license),
            externalReferences:[{type:"vcs",url:.url}],
            properties:[{name:"llmctl:kind",value:"git-submodule"}] } ] )
    }' > "${OUT}/${SBOM}"
  jq -e . "${OUT}/${SBOM}" >/dev/null
  echo "sbom: ${OUT}/${SBOM}"
}

cmd_notice() {
  mkdir -p "${OUT}"
  model | jq -r '
    "llmctl third-party notice\nGenerated from go.mod and .gitmodules. Licences marked NOASSERTION were not readable and are not guessed.\n\nGo modules:",
    (.mods[] | "  " + .name + " " + .version + (if .indirect then " (indirect)" else "" end)),
    "\nSubmodules (pinned commits):",
    (.subs[] | "  " + .name + " @ " + .commit + "  licence: " + .license + "  " + .url)' > "${OUT}/${NOTICE}"
  echo "notice: ${OUT}/${NOTICE}"
}

assets_list() { printf '%s\n' "${ARCHIVE}" "${SBOM}" "${NOTICE}"; }

cmd_assets() {
  local a rc=0
  while read -r a; do
    if [[ -f "${OUT}/${a}" ]]; then echo "present  ${a}"; else echo "missing  ${a}"; rc=1; fi
  done < <(assets_list)
  if [[ -f "${OUT}/SHA256SUMS" ]]; then echo "present  SHA256SUMS"; else echo "missing  SHA256SUMS"; rc=1; fi
  return "${rc}"
}

cmd_checksums() {
  if ((VERIFY)); then
    (cd "${OUT}" && sha256sum -c SHA256SUMS) 2>&1 || { echo "checksums: VERIFICATION FAILED" >&2; return 1; }
    return 0
  fi
  local a; for a in $(assets_list); do [[ -f "${OUT}/${a}" ]] || { echo "checksums: missing asset ${a}" >&2; return 1; }; done
  local -a sorted; mapfile -t sorted < <(assets_list | LC_ALL=C sort); (cd "${OUT}" && LC_ALL=C sha256sum "${sorted[@]}" > SHA256SUMS)
  if [[ "${LLMCTL_RELEASE_SIGN:-0}" == 1 ]]; then
    if command -v gpg >/dev/null; then
      gpg --batch --yes --armor --detach-sign -o "${OUT}/SHA256SUMS.asc" "${OUT}/SHA256SUMS" && echo "signature: SHA256SUMS.asc"
    else echo "signature: SKIPPED (gpg not installed)"; fi
  fi
  echo "checksums: ${OUT}/SHA256SUMS"
}

publish_plan() {
  local files=("${OUT}/${ARCHIVE}" "${OUT}/${SBOM}" "${OUT}/${NOTICE}" "${OUT}/SHA256SUMS")
  [[ -f "${OUT}/SHA256SUMS.asc" ]] && files+=("${OUT}/SHA256SUMS.asc")
  local gh=(gh release create "${TAG}" "${files[@]}" --verify-tag --title "${TAG}" --notes-file "${OUT}/RELEASE_NOTES.md")
  local gl=(glab release create "${TAG}" "${files[@]}" --name "${TAG}" --notes-file "${OUT}/RELEASE_NOTES.md")
  if [[ "${LLMCTL_RELEASE_PUBLISH:-0}" != 1 ]]; then
    echo "DRY-RUN (set LLMCTL_RELEASE_PUBLISH=1 to execute):"
    echo "  ${gh[*]}"; echo "  ${gl[*]}"
  else
    [[ -f "${OUT}/RELEASE_NOTES.md" ]] || { echo "publish: ${OUT}/RELEASE_NOTES.md required" >&2; return 1; }
    "${gh[@]}"; "${gl[@]}"
  fi
}

case "${CMD}" in
  assets) cmd_assets;;
  verify-tag) cmd_verify_tag;;
  archive) cmd_archive;;
  sbom) cmd_sbom;;
  notice) cmd_notice;;
  checksums) cmd_checksums;;
  all) cmd_verify_tag; cmd_archive; cmd_sbom; cmd_notice; cmd_checksums; if ((PUBLISH)); then publish_plan; fi;;
esac
