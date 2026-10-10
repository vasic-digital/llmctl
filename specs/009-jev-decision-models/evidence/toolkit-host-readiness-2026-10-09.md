# claude_toolkit host readiness (read-only probes) - 2026-10-09

Method: ssh probes only (git ls-remote --heads <remote> main, 20 s timeout, no fetch; tool versions; `claude-install-verify`; `claude-providers list`/`list-faulty`; status.json read with secrets stripped). Nothing installed, edited or synced; no secrets printed.

## Summary table
| Item | nezha | factory |
|---|---|---|
| Checkout version | claude_toolkit-1.26.7 | claude_toolkit-1.29.0-3-gcf71def |
| (a) remotes reachable over ssh | github, gitlab, gitflic, upstream, origin: yes (main = f663816). **gitverse: NO** - remote URL is `vasic-digital/claude-toolkit` (hyphen) -> "GitVerse: Cannot find repository" | all 4 + origin + upstream: yes (main = f663816) |
| (b) claude / jq / rsync / go / node | 2.1.261 / 1.8.1 / 3.2.7 / go1.26.2 / node v22.19.0 (all present) | 2.1.295 / 1.8.1 / 3.2.7 / go1.26.4 / **node MISSING** |
| (c) claude-install-verify | on PATH, rc=0: ccr OK, cma-proxy OK (no kimi section: pre-1.27 install) | on PATH, rc=0: ccr, cma-proxy, kimi wrappers + 20 kimi-prov configs OK |
| claude-providers list (verified) | 14: kilo, kimi-code-plan-cn, kimi-code-plan-cn2, nvidia, nvidia2, nvidia3, opencode, openrouter, openrouter2-4, poe, sarvam, zai-coding-plan | 14: helixcoder, kimi-code-plan-cn/-cn2, nvidia, nvidia2, nvidia3, opencode, openrouter, openrouter2-4, poe, zai, zai-coding-plan; list-faulty empty |
| faulty/unverified | chutes, chutes1-5, deepseek (failed/existence), deepseek2, github-models (orphaned), fireworks, huggingface, hyper, hyper1-4 (failed/existence), helixagent, helixagent-native, helixllm-gateway (unverified/existence) | none listed as faulty by list-faulty; but status.json: helixagent unverified/existence, helixagent-native + helixllm-gateway orphaned |
| (d) helixagent (default gate provider) configured+verified | **NO** - alias present, status `unverified` (layer existence, checked 2026-10-09T08:36Z) | **NO** - status `unverified` (existence, checked 2026-10-08T19:01Z); no helixagent alias text found in alias-file grep. Only `helixcoder` is verified there |
| (e) ~/.local/bin symlinks | 87 links; claude-providers/-release-gate/-sync-state -> the DATA4TB checkout. 45 point elsewhere: ~40 stale `*.preunify.<ts>` links (pointing to old `claude-toolkit/` path or empty), `claude-cwd-hook` -> lava constitution multitrack hook, `kimi-cli`/`kimi-legacy` -> uv tool (benign) | 20 links, all inside the factory checkout (0 outside) |

## Implications for the release plan
- Fetch over ssh works on nezha (except gitverse remote URL typo) and on factory (all). Fetch from github/gitlab/gitflic on nezha is enough; rsync/bundle from anton is NOT required. Fix nezha's gitverse URL (`claude-toolkit` -> `claude_toolkit`) or just skip that remote for fetch.
- Both remotes already report main = f663816 (v1.30.4+1). The 006 branch merge/tag are not yet published, so nothing newer exists to pull yet.
- Release gate: default provider `helixagent` is not verified on either host, so `claude-release-gate` there needs `--provider <verified id>` (e.g. nvidia / opencode / zai-coding-plan; helixcoder on factory) or running the gate on anton only. Live gate on nezha/factory is UNCONFIRMED beyond this; not executed.
- factory: node absent (TOON util soft dep only, per assessment); go present for ccr build.
- nezha: 1.26.7 install predates kimi (1.27): after upgrade expect kimi section in install-verify; stale preunify links harmless; claude-cwd-hook points into the lava constitution (unrelated to toolkit, leave).

## Other hosts the operator has touched (names only, from known_hosts on nezha/factory; anton has no ~/.ssh/config and hashed known_hosts)
- nezha known_hosts: 10.6.100.221 (factory), 192.168.1.92, 138.201.121.227, amber.local, mistborn.local, thinker.local, nezha.local, localhost, git hosts (github.com, ssh.github.com:443, gitlab.com, gitflic.ru, gitverse.ru incl. :2222, gitee.com). nezha ~/.ssh/config has only Host github.com / gitlab.com.
- factory known_hosts: 127.0.0.1, localhost, 138.201.121.227 (port 7722), git hosts.
- Candidates beyond the three: amber.local, mistborn.local, thinker.local, 192.168.1.92, 138.201.121.227. Whether the toolkit is installed on any of them is UNCONFIRMED (not probed; no repo docs grep done for them beyond this).
