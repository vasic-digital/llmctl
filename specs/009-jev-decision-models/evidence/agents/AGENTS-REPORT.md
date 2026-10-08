# T101 report: coding agents exercised live against the real decision gateway

Date: 2026-10-08 (UTC 10:20-10:40), host `anton` (31 GB RAM, about 4-5 GB available, swap full). Tree uncommitted; nothing staged, committed or pushed.
Governing decisions: OD-13 (any configured paid provider, Claude Code included), OD-27 (minimal matrix, hard cap about 100 model requests).

## 1. Result matrix

Pass criterion (SC-007): the gateway's own decision log shows a request in the run's time window with the expected profile and question type
(`types.choice = 1`, `status 200`) AND the agent's final answer equals the gateway's answer. The agent's own text is never evidence.

| Agent | Profile | Driver (provider / model) | Result | Gateway decision-log lines from the run | Agent answer vs gateway | Model requests (driver side) |
|---|---|---|---|---|---|---|
| Claude Code 2.1.293 | decide-laya | Anthropic / `haiku` (resolved `claude-haiku-5-5`) | **PASS** | 1 (`10:24:36Z`, choice, 200, `choice_index 1` = `no`) | `no` = `no` | 2 (`num_turns`) |
| Claude Code | decide-julia | same | **PASS** | 1 (`10:39:22Z`, choice, 200, `choice_index 0` = `yes`) | `yes` = `yes` | 2 |
| pi 0.85.1 | decide-laya | local `llama32` (Llama-3.2-3B-Instruct Q4_K_M, our `small` profile model, GPU) | **FAIL** (driver did not issue the call) | 0 in 3 attempts (prompts A, B, C) | `No.` / `"Yes"` / `"choices": ["Yes","No"]` - fabricated from the model's own head, never from the gateway | 1 + 1 + (see 3) |
| pi | decide-laya | local Gemma-3-4B (`vision` profile, port 8082) | **FAIL** (same) | 0 | `yes` - fabricated | 1 |
| opencode 1.18.30 | decide-laya | Gemma-3-4B | **FAIL** | 0 | printed a fake ```` ```tool_code ```` block as text, or "I'm ready" | see 3 (a runaway loop) |
| opencode | decide-laya | Llama-3.2-3B | **FAIL** (prompt A: a real `bash` tool call, but the command was truncated to `printf `; prompt C: dozens of real `bash` calls with `--state rm -rf ...` unquoted, all rejected by `llmctl-decide` with `flag provided but not defined: -rf`) | 0 | final text "llmctl-decide ask is not available" | see 3 |
| crush v0.91.2 | decide-laya | Gemma-3-4B | **NOT EXERCISED / FAIL** (server rejected crush's first request: chat template `Conversation roles must alternate user/assistant`) | 0 | none | 1 (rejected) |
| crush | decide-laya | Llama-3.2-3B | **FAIL** (prompt A: crush crashed parsing the reply `Message content is shorter than read bytes: 12 < 86`; prompt C: answered `yes` with no tool call) | 0 | `yes` - fabricated | see 3 |
| aider 0.86.2 | any | - | **NOT EXERCISED** | - | - | 0 |
| Continue `cn` 1.5.47 | any | - | **NOT EXERCISED** | - | - | 0 |
| Cline 3.0.69 | any | - | **NOT EXERCISED** | - | - | 0 |
| julia profile for pi / opencode / crush | decide-julia | - | **NOT EXERCISED** (nothing to add: these agents never reached the gateway on laya) | - | - | 0 |

Why aider / cn / cline were not run: after the opencode runaway (section 3) the request cap was exhausted by the upper-bound accounting, and the
instruction was to stop at the cap and record what was not run. Their `--check` result is in `install-check.txt` (all seven installed). I expect
aider to end "model produced no shell command" and cn/cline to depend on the same weak local drivers; that expectation is UNCONFIRMED.
Only Claude Code is a driver capable of reliably issuing the call on this host (the configured Anthropic session; every other configured provider was
either unavailable or unusable, see 4).

The only two PASSes therefore prove: the Claude Code path (`claude -p ... --allowedTools 'Bash(llmctl-decide *)' 'Bash(printf *)'`, the kit's shell form)
reaches a real HTTPS gateway with the real key and CA and the answer reaches the user. They do NOT show that pi / opencode / crush work with the kit:
their hook/plugin gates were not exercised live either (this task exercised the decision call, not the gating hooks).

## 2. How it was run (all reproducible from this directory)

* Gateway: the project's `llmctl-decide serve` (`bin/llmctl decide serve --foreground --bind 127.0.0.1 --port 8095`), HTTPS, CA + leaf under a scratch
  `LLMCTL_HOME`, key generated into a scratch `LLMCTL_ENV_FILE` (0600, never printed), `LLMCTL_DECIDE_NATIVE=1`, `LLMCTL_DECIDE_RESOLVER=static`,
  `LLMCTL_DECIDE_DECISION_LOG=<scratch>/decisions.jsonl` (0600, no state text; `decision-log-full.jsonl`) and `LLMCTL_DECIDE_LOG` (request log;
  `request-log-full.jsonl`). The gateway binary was rebuilt from the current tree into the scratch directory because `build/llmctl-decide`
  (Oct 8 02:58) predates the decision-log code and did not create the log (found and fixed by rebuilding, not by editing code).
* Engines: ONE at a time, started by hand with the catalog's exact arguments, `nice -n 10`, `env -u LD_LIBRARY_PATH`, per-profile key file
  (`--api-key-file`, 0600): `decide-laya` on 8107, then `decide-julia` on 8103. **Not started through `llmctl start`**: at the moment of the run the
  scheduler budget was 941 MiB RAM (`MemAvailable - 4 GiB`) and refused laya (996 MiB) and julia (1448 MiB) exactly as in NATIVE-REPORT.md. Starting
  by hand is the allowed fallback in this task's brief; the measured peaks in NATIVE-REPORT.md (laya 920 MiB, julia 820 MiB VmHWM) fit the real free RAM.
* Agents: each in an isolated scratch HOME / XDG tree with a per-invocation provider config (opencode `opencode.json`, pi `models.json`, crush
  `crush.json`); the operator's real agent configs were not read for values or modified. Claude Code ran in the operator's alias (its own auth),
  from a scratch project directory.
* Command lines (key only by environment reference; `$LLMCTL_API_KEY`, `$LLMCTL_CACERT` come from the shell environment, `llmctl-decide` is on PATH):
  * `claude -p "$PROMPT" --model haiku --allowedTools 'Bash(llmctl-decide *)' 'Bash(printf *)' --output-format json --max-turns 4 --strict-mcp-config --disable-slash-commands`
  * `pi -p --provider llmctlvision --model llama32 --no-extensions --no-skills --no-session "$PROMPT"`
  * `opencode run -m llmctlvision/llama32 --format json --print-logs "$PROMPT"` (isolated HOME, see the kit fix)
  * `crush run -q -m llmctlvision/llama32 "$PROMPT"`
  * Prompt A (the task text): ask the gateway, not the model, whether `rm -rf /var/lib/app` is dangerous, running
    `printf '%s' 'rm -rf /var/lib/app' | llmctl-decide ask --stdin --type choice --profile decide-laya --instructions ... --criteria '{"yes":..,"no":..}' --json`,
    then answer `answers.q.choice`. Prompt B: the same with "you must call your bash tool now". Prompt C: the quote-light form
    `llmctl-decide ask --question-file question.json --state 'rm -rf /var/lib/app' --profile decide-laya --json` (the kit's `question.json`).
* Credential sources (names only): Claude Code - the operator's authenticated Claude Code session (agent's own login, provider Anthropic);
  pi / opencode / crush local drivers - no credential (loopback llama.cpp servers, key `none`). The gateway access key and the per-engine keys
  were generated into scratch files and are not in this directory (leak scan below).
* Local drivers: the existing `llmctl-llama@vision` unit (Gemma-3-4B on 8082) was used and never stopped or restarted; for the second driver a
  Llama-3.2-3B instance (the catalog `small` model file) was started by hand on 127.0.0.1:8185 (GPU, ctx 16384) and stopped by exact pid. The other
  operator llama-server on port 18434 and the helixagent/helixllm services were NOT used or touched. Configured paid/cloud alternatives were
  checked: `KIMI_API_KEY` in the environment returned HTTP 401 from the Moonshot and Kimi endpoints (key rejected, so unusable; no model request
  was made), the opencode `helixagent` provider reports `no_serving_backend` for every model, and no other provider key exists in the environment.
* Every process this run started was stopped by exact pid after verifying its cmdline and `LLMCTL_HOME` environment (gateway pid 2115408 and the
  earlier gateway 2088546, engines 2079600 laya / 2703219 llama32 / julia). `llmctl-llama@vision` kept running and answers on 8082 (`{"status":"ok"}`).

## 3. Request accounting against the OD-27 cap (honest: the cap was exceeded by local, free requests)

| Counter | Value | Source |
|---|---|---|
| Paid requests (Claude Code, haiku) | **4** (2 + 2) | `num_turns` in `claude-code/*/stdout.txt` |
| Local Llama-3.2-3B requests (engine side) | **142** | the engine's own `processing task` counter (`driver-llama32-engine-task-count.txt`); nearly all from opencode prompt C |
| Local Gemma-3-4B requests | not measurable (that server is not ours and logs no requests); upper bound about 130, almost all HTTP 400 "exceeds the available context" rejections that generate no tokens | opencode retry rate observed with `--print-logs` (19 streams in 60 s) x the wall time of the unbounded runs (240 s + 100 s + 60 s) |
| Gateway requests caused by the agents | 2 (both Claude Code); 3 more gateway requests are my own smoke checks (`10:22:04Z`, `10:35:49Z`, `10:38:52Z`) | `decision-log-full.jsonl` |

Total by the upper-bound rule is well above the cap of about 100. Cause (root cause established from the logs): opencode `run` has no step
limit and retries a failing call without bound - a rejected oversized request, then a failing `llmctl-decide` invocation. The cost was zero
paid tokens (local engines), but the cap was breached and I stopped issuing further agent runs at that point, except the 2-request Claude Code run
on julia (paid, small, and the only agent able to reach the gateway) which I judged worth finishing. If the operator wants aider / cn / cline /
julia rows, that needs an explicit decision; the runner (`run_agent.sh`) already bounds every run with `timeout`.

## 4. Root causes of the failures (systematic debugging; reproduced before explaining)

1. **opencode, first runs (Gemma): no output and a 240 s hang.** Reproduced with `--print-logs`: opencode puts every skill under `$HOME/.agents/skills`
   and `$HOME/.claude/skills` in the system prompt, giving a **104,712 to 104,987-token** request; the 24k-context driver answers HTTP 400 and
   opencode retries (build, then compaction) forever. With an isolated HOME the same prompt is about 3k tokens. Fixed in the kit docs (below).
2. **opencode without `--print-logs` hangs when stdout is a file** (two of two runs); with logs it completed in 5 s. Cause UNCONFIRMED; documented as such.
3. **pi: never calls the gateway.** Request size 1,734 tokens, one request, the model answers directly in all three prompt variants. The driver is
   too weak (Llama-3.2-3B / Gemma-3-4B); it is a driver limit, not a kit defect. The fabricated answers look plausible - exactly why the pass test is the gateway log.
4. **opencode on Llama-3.2-3B: malformed tool arguments.** Real `bash` tool calls were emitted, but the 3B model dropped the quoting (command `printf ` /
   `--state rm -rf /var/lib/app`). The kit's long pipeline and even the quote-light form need correct quoting; a weak driver cannot be relied on for it.
5. **crush:** Gemma template rejects crush's message roles; Llama-3.2-3B reply broke crush's parser (`Message content is shorter than read bytes`).
   Both are agent/driver interactions, unfixed. Nothing in the gateway or client was involved (0 gateway requests).

## 5. Kit fixes (test-first)

All under the files this task owns. Test: `tests/test_agent_kit.sh`, new section "docs record the measured live-exercise facts".
* RED (before the docs change): `RESULT: FAIL (7 assertion failure(s))` - README "Driving models" section, "weak driver", the quote-light call form,
  opencode "isolated HOME" and "timeout", crush "alternate", claude "--model haiku" all missing.
* GREEN (after): `tests/test_agent_kit.sh` `RESULT: PASS`; also PASS: `tests/test_install_agents.sh`, `tests/test_docs_no_literal_keys.sh`,
  `tests/test_syntax.sh`; `make lint` rc 0 (shellcheck 0.11.0).
* Docs changed: `docs/agents/README.md` (new "Driving models (measured, T101)" section: only a capable driver reaches the gateway; the quote-light form;
  always bound a headless run), `docs/agents/opencode.md` (isolate HOME/XDG, `timeout`, the 105k-token skills finding, scratch provider config),
  `docs/agents/crush.md` (scratch config, the two measured failures), `docs/agents/claude-code.md` (the exact cheapest live form incl. `Bash(printf *)`
  for pipelines). `status` lines of those pages still say "live result recorded by the SC-007 exercise" - this report is that record.
* Not changed: templates (no template defect found). The kit's `question.json` plus `--state` form worked for Claude-class drivers and from the shell
  (`llmctl-decide ask --question-file question.json --state 'rm -rf /var/lib/app' --profile decide-laya --json` returned `block`).

## 6. Things that must change outside my files

* Nothing in gateway / client / calibrate Go code was found defective. Observation for whoever owns the build: `build/llmctl-decide` is stale (predates
  the decision-log source); a gateway started from it silently ignores `LLMCTL_DECIDE_DECISION_LOG`. `llmctl build decide` should be re-run before any
  release evidence run (I built a private copy and did not touch `build/`).
* `lib/scheduler.sh` / `llmctl plan`: at 941 MiB budget laya (996) and julia (1448) are refused; I did not alter the headroom.
* The plan's expectation "the other six drive through a local chat profile" is not met: neither local 3-4B chat profile on this host reliably
  drives an agent. A stronger local chat profile (`fast` Llama-3.1-8B, `ws-moe-30b`) needs more RAM than is free now; recommend repeating the matrix
  for pi / opencode / crush / aider / cn / cline after the operator frees memory (OD-31), with a step limit or `timeout` on every run.

## 7. Evidence layout and integrity

`specs/009-jev-decision-models/evidence/agents/<agent>/<profile>[--driver-...--prompt-...]/{stdout.txt,stderr.txt,run.json,decision-log-excerpt.jsonl,request-log-excerpt.jsonl}`;
`decision-log-full.jsonl`, `request-log-full.jsonl`, `install-check.txt`, `driver-llama32-engine-task-count.txt`; `MANIFEST.json` + `SHA256SUMS`
(`python3 tests/evidence/manifest.py build|verify`). Leak scan (`tests/evidence/leak_scan.py`, literal secrets = the gateway access key and both engine
keys, control needle found, status `clean`) over this directory, `docs/agents`, `templates/agents`, `tests/test_agent_kit.sh`: no findings. No file
had to be deleted. The Claude Code JSON output contains the session id and token counts only.
