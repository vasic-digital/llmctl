# Operator decisions (answers to the interactive questions, 2026-10-07)

| OD | Decision | Effect |
|---|---|---|
| Commit/push policy | **Commit and push per phase** (operator answer). Fast-forward only, never force, fetch-first, to every configured remote; each phase commit only after its gates and independent review pass. | Commits/pushes happen at each green phase gate. |
| OD-1 | Attempt the llama.cpp engine advance, **gated** (scratch build, bounded -j, chat regression + live smoke, then switch pin). | T093 proceeds. |
| OD-3 | Download **shellcheck, coverage.py (scratch venv), testssl.sh, Hurl** (all four). Pinned versions, sha256-verified, user-local, logged. | gap G-012 closes via private install. |
| OD-5 | Install **all three** missing agents (aider, continue CLI, Cline) with their official installers; unrunnable headless = not exercised. | T100. |
| OD-6 | The vision server MAY be stopped whenever needed for live tests; restarted and verified afterwards. | Larger profiles can be live-tested. |
| OD-13 | **Any paid provider already configured** may drive agents (Claude Code included); usage logged. | T101 driver table widened. |
| OD-4 | Release signing "the same way as previous releases": v3.0.0-3.0.2 are annotated, unsigned git tags + gh/glab releases. Follow that; SHA256SUMS + SBOM added. | T126/T127. |
| OD-2/OD-12 | Podman vantage (rootless, via Containers submodule) **and** a second LAN machine `amber.local` (192.168.1.134, user milosvasic). Credentials were pasted in chat and are NOT stored anywhere; key-based SSH must be set up by the operator (`ssh-copy-id`). External/cloud vantage: none. | Real-LAN subset runs once key auth works; cloud = documented, not exercised. |
| OD-14 | Follow the 2026-09-15 no-cap decision for decision units; measured peaks recorded. | T080. |
| OD-15 | Measure and report coverage only; no enforcement gate. | T028. |
| OD-18 | `fixed` default, `dynamic` opt-in; **and "make sure everything is fully dynamic"**: every service (chat, decision instances, encoder runtime, gateway) must be able to run under the dynamic strategy and be discoverable through the registry; tests/QA derive everything from the live host (no hardcoded host names, paths or numbers). | T077 extended: gateway port also dynamic-capable. |
| QA evidence | Restore real numbers from b09a79a, stop tests overwriting tracked evidence (write only when `LLMCTL_QA_EVIDENCE=1`), and make the QA evidence fully host-dynamic (probe and record the live host identity). | gap G-015/G-016. |
| OD-11 | Constitution amendment 2.1.0 approved earlier ("Yes, do T030 as drafted"). | T030 done. |
| OD-7/8/9/10/16/17/19 | Defaults accepted by not objecting (CA+leaf; cert/ under ~/llmctl and key in installation-root .env; gateway as boot service; ports 8103+ free range with 8097 for decide-max; engines loopback-only; tag `v3.1.0` like previous releases; Containers submodule accepted, `install_upstreams.sh` run when its content has been inspected). | |

## Additional host (operator, 2026-10-07 19:2x): nezha.local

`nezha.local` (192.168.1.90) is provided for my use. Probed read-only over SSH with the **existing key** (no password used or stored anywhere): Intel i7-1165G7, 8 threads, 62 GiB RAM (53 free), 47 GiB swap, 155 GB free disk, Intel Iris Xe iGPU (Vulkan available, no NVIDIA/CUDA), ALT Linux (kernel 6.12), go 1.26.2, podman 5.7.1, cmake/gcc/make, no docker, no llmctl checkout. Conventions: all work in `~/llmctl-work/` only; I create and delete only paths I created by exact name; no system-wide installs; builds with bounded `-j`; I stop any process I started. It is the "more powerful" host in RAM (2x), not in GPU.

Planned use (tasks in tasks.md T058n/T062n/T093n/T130):
1. REAL second LAN machine for the transport matrix (replaces/augments the podman vantage for FR-064/FR-069; amber.local not needed for that if nezha suffices).
2. Larger decision models live-tested CPU-only (RAM headroom), including native `/v1/systemone` models after the engine advance (build there first: scratch build of llama.cpp >= b11361, no CUDA).
3. Portability run: the whole suite + Go tests on a second Linux distribution (ALT Linux) — evidence of cross-host behaviour (macOS still not available).
4. Offloading heavy builds from this host (swap is full here).

`amber.local`: still needs key authentication; the operator must run `ssh-copy-id milosvasic@amber.local` themselves (the password pasted earlier is not stored by me and should be rotated).

## Decisions of 2026-10-08 (interactive, operator)
- **OD-20 archives**: KEEP archive/llmctl.zip and archive/llmctl.tar.gz (no-silent-removal rule; the scanner scans nested archives, both clean). Closes G-122.
- **OD-21 cluster CLI (G-106)**: FIX within 3.1.0 (SAN-carrying certs + client cert/trust options from lib/cluster.sh, end-to-end tests). Task T131 moves into scope.
- **OD-22 golden-set labels (G-110)**: SHIP with every accuracy number labelled "provisional - labels agent-authored, human review pending"; review after the release.
- **OD-23 undelivered commands**: IMPLEMENT ALL FOUR before the release: `decide scale`, `decide calibrate`, `decide probe-order`, `decide completions` (FR-080 calibration, FR-081 completions). Supersedes the "planned, not in 3.1.0" markers in contracts/cli.md (to be reverted once implemented and tested).
- **OD-24 maturity (SC-003)**: SHIP ALL admitted profiles; every TYPE whose measured Wilson lower bound does not clear the majority/chance baseline is labelled `experimental` (per profile x type) in /v1/models, `llmctl plan`/docs tables and response metadata. Nothing hidden. Applies to all profile families (letter-logit, native, encoder) once measured.

## Blocker round of 2026-10-08 (interactive, operator)
- **OD-25 manual QA (T125)**: WAIVED for 3.1.0. The release proceeds after the automated gates, the final independent review and the full suite. The waiver is recorded verbatim in CHANGELOG/release notes ("manual QA waived by the operator, 2026-10-08") and in the readiness verdict; the constitution's §11.4.185 gate is acknowledged as operator-waived, not satisfied.
- **OD-26 amber.local**: DROPPED. nezha.local is the second host. The pasted password is not used; operator should still rotate it. Closes G-024/G-058.
- **OD-27 agent exercise budget (T101)**: MINIMAL matrix on the cheapest configured provider per agent: one short real task per agent per profile that fits (about 7 x 3 runs), hard cap ~100 model requests in total, request counts recorded.
- **OD-28 publishing scope**: main repo fast-forward to all five remotes (github, gitlab, gitflic, gitverse, codeberg) + annotated tag v3.1.0 there; `install_upstreams.sh` for the Containers submodule after inspecting it; matching tag on the Containers submodule remotes. Never force. gh and glab are logged in.
- **OD-29 macOS**: ship labelled "verified statically only" (docs, changelog, doctor). Linux is the live-verified platform.
- **OD-30 HTTP/3 curl**: BUILD curl with HTTP/3 in a private user-space prefix and verify the cluster CLI with the real curl (no root).
- **OD-31 host RAM**: the OPERATOR frees memory on this host for the final local runs; I announce the moment the re-runs of refused profiles are needed.
- Hygiene (no question needed, follows the earlier "tests must not overwrite tracked evidence" rule): llmctld DDoS/stress observation tests write to a temp location unless LLMCTL_QA_EVIDENCE=1; docs/qa/008 observation files restored to HEAD.
- **OD-27 clarification (lead, 2026-10-08)**: the ~100-request cap is a cap on PAID provider requests (4 used so far). Local-model requests cost nothing and are bounded by per-run timeouts instead.
