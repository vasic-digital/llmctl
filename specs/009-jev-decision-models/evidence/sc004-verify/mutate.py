#!/usr/bin/env python3
"""Apply ONE named reverted-fix mutation to the scratch copy M (from pristine G), or restore.
usage: mutate.py <name>|restore   - every anchor must match exactly once, else exit 3."""
import os, shutil, sys

S = os.path.dirname(os.path.abspath(__file__))
G, M = os.path.join(S, "G"), os.path.join(S, "M")

MUT = {
    # D-01: premise-only truncation -> whole-pair end-truncation (candidate's encode_pair behaviour)
    "D-01": ("lib/onnx_server.py",
             "            p_ids = p_ids[:budget]\n            ids = [self.cls_id] + p_ids + [self.sep_id] + h_ids + [self.sep_id]\n",
             "            ids = ([self.cls_id] + p_ids + [self.sep_id] + h_ids + [self.sep_id])[:self.max_tokens]\n            p_ids = p_ids[:budget]\n"),
    # D-02: the gateway never sends the engine key (candidate: proxy/CLI sent no key -> 401/502)
    "D-02": ("internal/gateway/driver.go",
             '\tif key != "" {\n\t\treq.Header.Set("Authorization", "Bearer "+key)\n\t}\n',
             '\t_ = key\n'),
    # D-03: scheduler puts the encoder key VALUE on argv again
    "D-03": ("lib/scheduler.sh",
             '                  --api-key-file "${keyfile}")\n',
             '                  --api-key "$(cat "${keyfile}" 2>/dev/null || true)")\n'),
    # D-04: encoder runtime accepts any --host (no loopback guard)
    "D-04": ("lib/onnx_server.py",
             "    if args.host != LOOPBACK:\n",
             "    if False and args.host != LOOPBACK:\n"),
    # D-05: stop signals whatever pid the pidfile names (identity verification removed; pid<=1 guard KEPT)
    "D-05": ("internal/gateway/proc.go",
             "\tif err := VerifyServeProcessInfo(info, binName); err != nil {\n\t\treturn StopRefused, fmt.Errorf(\"pid %d is alive but is not the gateway",
             "\tif err := VerifyServeProcessInfo(info, binName); err != nil && false {\n\t\treturn StopRefused, fmt.Errorf(\"pid %d is alive but is not the gateway"),
    # D-29: credential variable reverted to the retired candidate name
    "D-29": ("internal/keyring/keyring.go",
             '\tKeyVar       = "LLMCTL_API_KEY"\n',
             '\tKeyVar       = "LLMCTL_DECIDE_API_KEY"\n'),
    # D-30: archive file list = whole filesystem walk instead of tracked files only
    "D-30": ("scripts/release/build_archive.sh",
             '      git -C "${src}" ls-files -z --recurse-submodules\n',
             '      ( cd "${src}" && find . -mindepth 1 -path ./.git -prune -o \\( -type f -o -type l \\) -print0 )\n'),
    # D-30b: as D-30 AND the defense-in-depth archive post-scan disabled (so the leak reaches the assertion)
    "D-30b": ("scripts/release/build_archive.sh",
              '      git -C "${src}" ls-files -z --recurse-submodules\n',
              '      ( cd "${src}" && find . -mindepth 1 -path ./.git -prune -o \\( -type f -o -type l \\) -print0 )\n',
              '  if ! _ba_scan_archives "${out}.tar.gz" "${out}.zip"; then\n',
              '  if false && ! _ba_scan_archives "${out}.tar.gz" "${out}.zip"; then\n'),
    # N-01: the bash front end turns --state-file into an argv --state VALUE again
    "N-01": ("lib/decide.sh",
             '    if [[ "${a}" == "--interactive" ]]; then wiz=1; else rest+=("${a}"); fi\n  done\n',
             '    if [[ "${a}" == "--interactive" ]]; then wiz=1; else rest+=("${a}"); fi\n  done\n'
             '  local i; for ((i=0;i<${#rest[@]};i++)); do if [[ "${rest[i]}" == "--state-file" ]]; then rest[i]="--state"; rest[i+1]="$(cat "${rest[i+1]}")"; fi; done\n'),
}


def restore():
    for rel, *_ in MUT.values():
        shutil.copy2(os.path.join(G, rel), os.path.join(M, rel))


def main():
    name = sys.argv[1]
    restore()
    if name == "restore":
        print("restored")
        return 0
    rel, *pairs = MUT[name]
    p = os.path.join(M, rel)
    src = open(p).read()
    for old, new in zip(pairs[0::2], pairs[1::2]):
        n = src.count(old)
        if n != 1:
            print("anchor for %s found %d times in %s" % (name, n, rel))
            return 3
        src = src.replace(old, new)
    open(p, "w").write(src)
    print("mutated %s: %s" % (name, rel))
    return 0


sys.exit(main())
