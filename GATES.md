# Gates: llmctl v3.1.0 + claude_toolkit v1.30.5 release finish

Scope: complete the unfinished release work from the previous Claude Code session:
- verify llmctl full validate gate is green and run constitution gates,
- flip OpenAPI/CHANGELOG draft markers and tag v3.1.0,
- build/publish llmctl release assets and re-verify checksums,
- push claude_toolkit bookkeeping commit, run its hermetic and live gates,
- tag claude_toolkit v1.30.5, publish releases, and sync to anton/nezha/factory.

- [x] G0: this ledger states outcomes that can fail
  CHECK: node /home/milosvasic/.agents/skills/unlazy/scripts/gate-lint.mjs /home/milosvasic/Projects/llmctl/GATES.md
  EXPECT: LINT OK
  EVIDENCE: exit=0; shell=/bin/sh; cwd=/home/milosvasic/Projects/llmctl; path=ce9cbba1f87f/39 entries; EXPECT=matched; output-sha256=48630b7361dd44ee870917b12c3d19b9d7bdea738aaca16bb04d4cab83b772d2; output-bytes=8

## llmctl gates

- [x] G1: llmctl working tree is clean and on main before any release mutation (the untracked GATES.md ledger is expected)
  CHECK: cd /home/milosvasic/Projects/llmctl && test "$(git branch --show-current)" = "main" && test -z "$(git status --short | grep -v '^?? GATES.md$')" && echo "llmctl clean on main"
  EXPECT: llmctl clean on main
  EVIDENCE: exit=0; shell=/bin/sh; cwd=/home/milosvasic/Projects/llmctl; path=ce9cbba1f87f/39 entries; EXPECT=matched; output-sha256=b1b01e8b4d8675947856e9679016f237870db5e99fa1939a8bce09c904358637; output-bytes=21

- [x] G2: llmctl make validate passes on the final commit
  CHECK: cd /home/milosvasic/Projects/llmctl && f=$(mktemp /tmp/llmctl-g2.XXXXXX) && timeout 7200 make validate >"$f" 2>&1; rc=$?; tail -n 5 "$f"; rm -f "$f"; test "$rc" -eq 0 && echo "llmctl make validate PASS"
  EXPECT: llmctl make validate PASS
  EVIDENCE: exit=0; shell=/bin/sh; cwd=/home/milosvasic/Projects/llmctl; path=ce9cbba1f87f/39 entries; EXPECT=matched; output-sha256=68b357bd14c8d199dc72b6bd0ae0b50485d8e6d4683889c86ad816623ea881bd; output-bytes=395

- [x] G3: llmctl constitution run_verification passes
  CHECK: cd /home/milosvasic/Projects/llmctl && timeout 1800 bash constitution/scripts/validation/run_verification.sh && echo "constitution run_verification PASS"
  EXPECT: constitution run_verification PASS
  EVIDENCE: exit=0; shell=/bin/sh; cwd=/home/milosvasic/Projects/llmctl; path=ce9cbba1f87f/39 entries; EXPECT=matched; output-sha256=cb62927f726e85f048fc3b7e4db379ed4f5b4b39f75ce07b64d9810d8349d499; output-bytes=29677

- [x] G4: llmctl meta_test_verification passes
  CHECK: cd /home/milosvasic/Projects/llmctl && timeout 1800 bash constitution/scripts/validation/meta_test_verification.sh && echo "constitution meta_test PASS"
  EXPECT: constitution meta_test PASS
  EVIDENCE: exit=0; shell=/bin/sh; cwd=/home/milosvasic/Projects/llmctl; path=ce9cbba1f87f/39 entries; EXPECT=matched; output-sha256=3ff6a493d331cbec705cac9a3cb644d63d702bbeee935e7c30d760d36f96ab03; output-bytes=1345

- [x] G5: OpenAPI draft marker is flipped and CHANGELOG date is 2026-10-10, committed
  CHECK: cd /home/milosvasic/Projects/llmctl && grep -RFn "3.1.0-draft" --exclude-dir=.git --exclude-dir=submodules --exclude-dir=constitution --exclude=release-3.1.0-checklist.md --exclude=GATES.md --exclude='tasks-status-2026-10-09.md' . >/dev/null 2>&1 && { echo "draft marker remains"; exit 1; }; grep -q "^## 3.1.0 (2026-10-10)" CHANGELOG.md && git log -1 --pretty=%s | grep -q "release: 3.1.0" && echo "draft flip committed"
  EXPECT: draft flip committed
  EVIDENCE: exit=0; shell=/bin/sh; cwd=/home/milosvasic/Projects/llmctl; path=ce9cbba1f87f/39 entries; EXPECT=matched; output-sha256=771b4f1640ed7b6543f279c02e79e8249b221d58b5ff9017f23129d7c1384d4a; output-bytes=21

- [x] G6: llmctl v3.1.0 annotated tag exists on the release commit
  CHECK: cd /home/milosvasic/Projects/llmctl && test "$(git cat-file -t refs/tags/v3.1.0)" = "tag" && git rev-parse "v3.1.0^{commit}" && echo "llmctl v3.1.0 tag present"
  EXPECT: llmctl v3.1.0 tag present
  EVIDENCE: exit=0; shell=/bin/sh; cwd=/home/milosvasic/Projects/llmctl; path=ce9cbba1f87f/39 entries; EXPECT=matched; output-sha256=2afa95cd8e4b6bb876814d61ca7ec7af5ae3546e353d99606fcf7bb94b9834a6; output-bytes=67

- [ ] G7: llmctl main and v3.1.0 tag are present and consistent on all five remotes
  CHECK: cd /home/milosvasic/Projects/llmctl && REL=$(git rev-parse HEAD) && TAGOBJ=$(git rev-parse refs/tags/v3.1.0) && for r in codeberg gitflic github gitlab gitverse; do m=$(git ls-remote "$r" refs/heads/main 2>/dev/null | cut -f1); t=$(git ls-remote "$r" refs/tags/v3.1.0 2>/dev/null | cut -f1); p=$(git ls-remote "$r" 'refs/tags/v3.1.0^{}' 2>/dev/null | cut -f1); [ "$m" = "$REL" ] && [ "$t" = "$TAGOBJ" ] && [ "$p" = "$REL" ] || { echo "$r MISMATCH"; exit 1; }; echo "$r OK"; done && echo "all remotes verified"
  EXPECT: all remotes verified
  EVIDENCE: pending

ABANDON: G7 gitverse (gitverse.ru) is unreachable from this host: SSH returns "Connection reset by peer" and HTTPS times out/502. The v3.1.0 tag and main are present and consistent on codeberg, gitflic, github, and gitlab; gitverse cannot be pushed or verified from here.

- [x] G8: llmctl release assets built, checksums verify, and archive scan is clean
  CHECK: cd /home/milosvasic/Projects/llmctl && OUT="$HOME/llmctl-release-3.1.0" && test -f "$OUT/llmctl-v3.1.0.tar.gz" && test -f "$OUT/SHA256SUMS" && (cd "$OUT" && sha256sum -c SHA256SUMS) && python3 -I scripts/release/scan_archive.py --allow scripts/release/public_allowlist.txt "$OUT/llmctl-v3.1.0.tar.gz" && echo "llmctl assets OK"
  EXPECT: llmctl assets OK
  EVIDENCE: exit=0; shell=/bin/sh; cwd=/home/milosvasic/Projects/llmctl; path=ce9cbba1f87f/39 entries; EXPECT=matched; output-sha256=106e8f822aee58f0c54d3720625c5fb44b54907649ac6c5094b1f7dc28b20185; output-bytes=101

- [x] G9: llmctl GitHub and GitLab releases exist for v3.1.0
  CHECK: gh release view v3.1.0 --repo vasic-digital/llmctl >/dev/null 2>&1 && glab release view v3.1.0 --repo vasic-digital/llmctl >/dev/null 2>&1 && echo "llmctl forge releases present"
  EXPECT: llmctl forge releases present
  EVIDENCE: exit=0; shell=/bin/sh; cwd=/home/milosvasic/Projects/llmctl; path=ce9cbba1f87f/39 entries; EXPECT=matched; output-sha256=e817595fc8d8a3872f082b117634bcf8e53e4b27f8f87200ca6d8da060a9ee61; output-bytes=30

- [x] G10: re-downloaded llmctl release assets match published checksums and the GitHub/GitLab archives are identical
  CHECK: set -euo pipefail; V=$(mktemp -d "$HOME/llmctl-verify.XXXXXX"); cd "$V"; gh release download v3.1.0 --repo vasic-digital/llmctl -p 'llmctl-v3.1.0.tar.gz' -p 'SHA256SUMS' -p 'NOTICE-THIRD-PARTY.txt' -p 'llmctl-v3.1.0.sbom.cdx.json'; sha256sum -c SHA256SUMS; mkdir gl && cd gl; for f in llmctl-v3.1.0.tar.gz SHA256SUMS NOTICE-THIRD-PARTY.txt llmctl-v3.1.0.sbom.cdx.json; do curl -fsSL -o "$f" "https://gitlab.com/vasic-digital/llmctl/-/releases/v3.1.0/downloads/$f"; done; cd ..; sha256sum -c gl/SHA256SUMS; cmp llmctl-v3.1.0.tar.gz gl/llmctl-v3.1.0.tar.gz; echo "llmctl redownload verified"
  EXPECT: llmctl redownload verified
  EVIDENCE: exit=0; shell=/bin/sh; cwd=/home/milosvasic/Projects/llmctl; path=ce9cbba1f87f/39 entries; EXPECT=matched; output-sha256=48f8ffde430790482d4b10cab63ab4619320d5f3228ffb604b11c1ddac940400; output-bytes=195

## claude_toolkit gates

- [ ] G11: claude_toolkit working tree is clean, on main, and the bookkeeping commit is pushed to all four remotes
  CHECK: cd /home/milosvasic/Projects/claude_toolkit && test "$(git branch --show-current)" = "main" && test -z "$(git status --short)" && HEAD=$(git rev-parse HEAD) && for r in github gitlab gitflic gitverse; do m=$(git ls-remote "$r" refs/heads/main 2>/dev/null | cut -f1); [ "$m" = "$HEAD" ] || { echo "$r not at $HEAD"; exit 1; }; echo "$r OK"; done && echo "claude_toolkit pushed and clean"
  EXPECT: claude_toolkit pushed and clean
  EVIDENCE: pending

ABANDON: G11 gitverse (gitverse.ru) is unreachable from this host: SSH returns "Connection reset by peer" and HTTPS times out/502. The bookkeeping commit is present and consistent on github, gitlab, and gitflic; gitverse cannot be pushed or verified from here.

- [x] G12: claude_toolkit hermetic test suite passes
  CHECK: cd /home/milosvasic/Projects/claude_toolkit && timeout 1800 bash scripts/tests/run-all.sh && echo "claude_toolkit hermetic PASS"
  EXPECT: claude_toolkit hermetic PASS
  EVIDENCE: exit=0; shell=/bin/sh; cwd=/home/milosvasic/Projects/llmctl; path=ce9cbba1f87f/39 entries; EXPECT=matched; output-sha256=16332fa868085cf71b104527960882e5843bdcda21ad265d4e6ac649c5da8294; output-bytes=565434

- [ ] G13: claude_toolkit live gate passes with a verified provider
  CHECK: cd /home/milosvasic/Projects/claude_toolkit && timeout 1800 bash scripts/tests/run-proof.sh && echo "claude_toolkit live gate PASS"
  EXPECT: claude_toolkit live gate PASS
  EVIDENCE: pending

ABANDON: G13 the only verified provider on this host (helixllm-anton-qwen2-5-coder-3b-instruct-q4_k_m-f6771589d190) is rejected by Claude Code with claude-code:unrecognized_model followed by Request too large (max 32MB); available non-Claude legs are green (constitution 7/7, opencode 9/9, quota 61/62 probes answered). Evidence: scripts/tests/proof/volatile/providers-helixllm-anton-qwen2-5-coder-3b-instruct-q4_k_m-f6771589d190-superpowers.txt

- [ ] G14: claude_toolkit v1.30.5 annotated tag exists and is pushed to all four remotes
  CHECK: cd /home/milosvasic/Projects/claude_toolkit && test "$(git cat-file -t refs/tags/v1.30.5)" = "tag" && REL=$(git rev-parse 'v1.30.5^{commit}') && for r in github gitlab gitflic gitverse; do t=$(git ls-remote "$r" refs/tags/v1.30.5 2>/dev/null | cut -f1); p=$(git ls-remote "$r" 'refs/tags/v1.30.5^{}' 2>/dev/null | cut -f1); [ "$t" = "$(git rev-parse refs/tags/v1.30.5)" ] && [ "$p" = "$REL" ] || { echo "$r tag MISMATCH"; exit 1; }; echo "$r tag OK"; done && echo "claude_toolkit v1.30.5 tag verified"
  EXPECT: claude_toolkit v1.30.5 tag verified
  EVIDENCE: pending

ABANDON: G14 gitverse (gitverse.ru) is unreachable from this host: SSH returns "Connection reset by peer" and HTTPS times out/502. The v1.30.5 tag is present and consistent on github, gitlab, and gitflic; gitverse cannot be pushed or verified from here.

- [x] G15: claude_toolkit GitHub and GitLab releases exist for v1.30.5
  CHECK: gh release view v1.30.5 --repo vasic-digital/claude_toolkit >/dev/null 2>&1 && glab release view v1.30.5 --repo vasic-digital/claude_toolkit >/dev/null 2>&1 && echo "claude_toolkit forge releases present"
  EXPECT: claude_toolkit forge releases present
  EVIDENCE: exit=0; shell=/bin/sh; cwd=/home/milosvasic/Projects/llmctl; path=ce9cbba1f87f/39 entries; EXPECT=matched; output-sha256=cc1684609bd6e1f2cb6a19c37ec0bc4566ec03728a5a08e28a90fd4b2b0a7c64; output-bytes=38

- [ ] G16: claude_toolkit is installed and synced on anton, nezha, and factory
  CHECK: bash /home/milosvasic/Projects/claude_toolkit/scripts/install/sync-check.sh v1.30.5 && echo "claude_toolkit sync verified"
  EXPECT: claude_toolkit sync verified
  EVIDENCE: pending

ABANDON: G16 the target hosts are unreachable from this host: anton fails SSH host-key verification; nezha and factory do not resolve (DNS lookup failure). The release assets and tag are published; install/sync must be completed from a host that can reach the targets.

## Final gates

- [x] G17: final git status and ls-remote checks are clean for both repos and own-org submodules
  CHECK: cd /home/milosvasic/Projects/llmctl && test -z "$(git status --short | grep -v '^?? GATES.md$')" && git ls-remote codeberg refs/heads/main >/dev/null && cd /home/milosvasic/Projects/claude_toolkit && test -z "$(git status --short)" && git ls-remote github refs/heads/main >/dev/null && cd /home/milosvasic/Projects/llmctl/submodules/containers && test -z "$(git status --short)" && test "$(git rev-parse HEAD)" = "$(git ls-remote origin refs/heads/main 2>/dev/null | cut -f1)" && echo "final status clean"
  EXPECT: final status clean
  EVIDENCE: exit=0; shell=/bin/sh; cwd=/home/milosvasic/Projects/llmctl; path=ce9cbba1f87f/39 entries; EXPECT=matched; output-sha256=4b89c82bff9187be4e404cfc7130328ac93a646b99a3acf97173a92c6a21e0d6; output-bytes=19
