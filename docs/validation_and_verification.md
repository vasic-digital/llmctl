# Validation and Verification, Anti-Bluff, Anti-AI-Slop

Why is so important to request from CLI agent to perform validation and verification of all work done fully deterministically?

## Answers

Because a CLI agent is a probabilistic text generator with shell access. It can write plausible code, plausible explanations, and plausible claims that it “tested everything.” Without deterministic validation and verification, you’re often asking the agent to grade its own homework.

Requesting fully deterministic V&V is important because it turns trust from a narrative into evidence.

### Why it matters

1. **AI agents are not reliable self-verifiers**
   - They can hallucinate success, skip edge cases, ignore failed commands, or misread output.
   - “I ran the tests and they passed” is not evidence unless you see the exact command, exit code, and raw output.

2. **Deterministic checks are objective**
   - Same code, same environment, same command → same result.
   - Exit codes, test reports, linter output, type errors, build artifacts, and diffs are hard to fake and easy to rerun.
   - This removes subjective judgment like “looks correct” or “should work.”

3. **It separates generation from verification**
   - The agent writes or changes code.
   - Deterministic tools judge the result: tests, type checkers, linters, builds, security scanners, coverage gates.
   - This reduces self-preference bias and overconfidence.

4. **It makes results reproducible and auditable**
   - Anyone can rerun the same commands and get the same pass/fail.
   - That is essential for debugging, code review, CI/CD, compliance, and incident analysis.
   - If something breaks later, you have a reproducible baseline.

5. **It catches real failures early**
   - Broken builds, failing tests, type errors, lint violations, regressions, dependency issues, secrets, and obvious security problems.
   - Catching these before merge or deployment is far cheaper than catching them in production.

6. **It enables safe autonomy**
   - You can let an agent work more independently if it must prove its work with deterministic checks.
   - The agent’s output becomes gated by executable truth, not by its confidence.
   - This is the difference between “trust me” and “here is the command and the result.”

7. **It makes failures actionable**
   - A deterministic failure gives a clear error, stack trace, or diff.
   - The agent can then fix the specific issue and rerun the same check.
   - This creates a tight plan → act → verify loop.

8. **It reduces human review burden**
   - Humans should review design, intent, edge cases, and trade-offs.
   - They should not have to manually verify that the code compiles or that unit tests pass.
   - Deterministic V&V handles the mechanical correctness so humans can focus on what matters.

### Important nuance

“Fully deterministic” is not always possible. Some things require human judgment: UX, business intent, security threat modeling, architectural fit. Also, deterministic tests can still be incomplete or wrong. Passing tests does not guarantee correctness; it only proves the checked properties hold.

But where deterministic checks are possible, they are necessary. They make claims falsifiable. They turn “the agent says it works” into “the agent ran these commands, and here is the raw output.”

### Practical rule

Ask the CLI agent to:
- run exact, reproducible commands,
- show exit codes and raw output,
- run the full relevant suite, not just a happy path,
- stop and fix if any check fails,
- report what was not verified and why.

Bottom line: deterministic V&V is how you keep an AI coding agent honest. It replaces probabilistic self-assessment with executable, repeatable proof. Without it, you are trusting a model’s confidence. With it, you are trusting evidence.

## Are there some rock.solid Skills repos we could use to enforce this fully with fully deterministiv validation and verification, zero bluff or ai slop?

Yes, there are several open-source "skill" repos and frameworks designed to enforce deterministic validation and verification, moving beyond an AI's self-assessment to executable proof. They generally fall into a few categories: **dedicated verification skills** that a CLI agent can invoke, **deterministic gate/harness frameworks** that wrap agent output, and **specialized tools** for security and skill validation.

### 🛡️ Dedicated Verification & Proof Skills

These are packaged as "skills" (often `SKILL.md` files) that you can install into agents like Claude Code, Codex, or Cursor to run repo-specific checks.

* **`verification` (ArcBlock/agent-skills)**: Runs a repo's deterministic verification gate (build, lint, types, tests) and posts a measured report. It's repo-agnostic; the check list comes from the consuming repo's own config. The core guardrail: a check's **exit code** decides pass/fail, not a narrative.
* **`verify` (KeyValueSoftwareSystems/maestro)**: Runs deterministic checks and produces an evidence-backed **proof report** plus a machine-readable `last-verify.json` marker. It never modifies code—only writes proof artifacts. The proof is produced by the command, not assumed.
* **`repo-qa` (okwinds/skills-runtime-sdk)**: Performs deterministic regression verification within a workspace using `shell_exec`. It recommends using `python -c` with `assert` for minimal, reproducible evidence without extra frameworks.
* **`repo-proof` (Gary06868/repo-proof)**: Treats a repository's `README.md` as a contract. It audits for drift, proves the visible workflow works in a **cleanroom copy**, and generates patches for documentation/config drift.
* **`cli-validation` (krzemienski/deepest-plan-plugin)**: Validates CLI platforms by direct binary execution, capturing stdout, stderr, exit codes, and file output.

### 🚦 Deterministic Gate & Harness Frameworks

These are more substantial systems (often Python packages or Rust binaries) that act as a deterministic layer around a probabilistic agent.

* **DoneSpec (`xryv/DoneSpec`)**: A deterministic **completion layer** for AI coding agents. It turns "done" into a local, machine-checkable contract via a `done.json` file. A task is not done until `donespec validate done.json` passes, checking for files, commands, and forbidden paths.
* **Determ8 (`determ8`)**: A deterministic pipeline that wraps a probabilistic model. The agent proposes a candidate answer; the pipeline passes it through a series of gates (Schema, FSM, Idempotency, Graph). The guarantee: **same input + same gate config = same verdict, always**.
* **Kedge (`SturdyRobot/kedge`)**: A deterministic AI agent execution and verification harness written in **Rust**. It includes a ReAct engine, hard budgets, Shadow-Guard interception, and SQLite replay.
* **Agentic Validation (`Tyler-R-Kendrick/agentic_validation`)**: Delivers high-assurance validation as a GitHub Copilot Plugin and consumable skill. It includes formal checking via **SMT/Lean** expression rules and result interpretation.

### 🔒 Specialized: Security & Skill Validation

If your concern is also validating the skills themselves for safety and correctness:

* **Skill Doctor (`KalarisLabs/Skill-Doctor`)**: A single statically linked Rust binary for **deterministic, multi-layer security analysis** of AI agent skill files. It detects malicious prompt injections and obfuscation with no interpreter, API key, or network required.
* **SkillCheck (`@sixscripts-ai/skillcheck`)**: A deterministic SDK, CLI, and GitHub Action that produces **fingerprint-bound evidence** that a skill package was scanned and tested.
* **Agent Skills CLI (`blackwell-systems/agentskills-cli`)**: An ecosystem-aware CLI for **validating and upgrading Agent Skills**, enforcing spec compliance and detecting vendor extensions.

### 💡 How to Approach This

No single repo is a magic "zero bluff" button. The strongest strategy is to **compose a stack**:

1. **Pick a core gate skill** (e.g., `verification`, `verify`, or `repo-qa`) and configure it with your repo's exact build/test/lint commands.
2. **Add a completion contract** (e.g., DoneSpec) to define what "done" means for a task in a machine-readable way.
3. **Wrap it in a deterministic harness** (e.g., Determ8) if you need a formal, replayable pipeline for high-stakes workflows.
4. **Validate the skills themselves** (e.g., with Skill Doctor) before trusting them in your agent's runtime.

The common thread across all these tools is that they replace the model's **narrative** ("I ran the tests and they passed") with **executable evidence**: exact commands, exit codes, and raw output. That is the practical mechanism for achieving zero bluff.

## Find us now same for UI / UX based apps, especially the Web, Desktop, TUI and Mobile apps!

You're right to push for the same rigor in UI/UX. While the domain is more visual and subjective, the industry is indeed building a solid stack of deterministic, evidence-producing tools for Web, Desktop, TUI, and Mobile—designed to be "agent-ready" and eliminate "vibes-based" verification.

Here's a breakdown of some of the most promising rock-solid options.

### 🌐 Web Applications: E2E, Visual & Governance

These tools focus on browser-based flows, visual consistency, and design system governance, providing structured, parseable evidence for agents.

* **Verfix** (`verfix-dev/verfix`): A local-first browser verification runtime. It runs deterministic browser flows (defined in JSON) from the CLI and returns structured JSON with typed failure codes and `fix_hint`s, allowing an agent to parse failures and act on them automatically. It has a "strict" mode that is fully deterministic with zero AI/token cost.
* **`@blazediff/agent`**: A deterministic CLI for visual regression testing. It discovers routes, screenshots them with Playwright, and diffs against committed baselines. Its key feature is handing ambiguous visual diffs to a coding agent (like Claude Code or Cursor) as compact "region tiles" instead of full PNGs, which is far more token-efficient and easier for an agent to judge.
* **`ux-audit`**: A deterministic UI/UX testing platform for AI-assisted remediation. It audits URLs using deterministic checks (Axe for accessibility, Lighthouse for performance) and writes a structured evidence bundle your agent can use to prioritize and implement fixes.
* **`ui-governance-gate`** (Agent Skill): A "skill" you can install into agents like Claude Code or Codex. It enforces a hard, deterministic gate for UI consistency, checking for things like Tailwind style drift, hard-coded colors, and contract misuse. It records all evidence in a structured run directory.
* **`verify-ui`** (Agent Skill): A skill that uses deterministic computed style checks to verify that CSS/UI changes match what the user requested. It explicitly states its purpose is to **avoid LLM confirmation bias** by checking against a "requirement contract" rather than inventing its own pass criteria.

### 📱 Mobile Applications: Native & Flutter

These tools drive real devices or simulators deterministically, with zero LLM in the verification loop.

* **Zeno Mobile Runner (ZMR)**: A small binary that gives you a deterministic yes/no on whether your AI agent's change broke the mobile app. It runs saved scenarios (plain JSON) on real iOS/Android devices, drives the native UI (React Native, Expo, Flutter, native), and returns typed pass/fail results with replayable traces. It has **no LLM inside**, ensuring the same answer every time with zero per-run cost.
* **Mobilewright**: Described as "Playwright for iOS and Android." It provides a unified API for testing across real devices, emulators, and simulators. Crucially, it exposes the device's **accessibility tree directly**, providing deterministic, token-efficient, and structured context for AI agents without needing a vision model.

### 💻 Desktop Applications: Native & Electron

These adapters bring deterministic automation to Windows and macOS native apps.

* **`vibe-tester`**: An AI-driven UI automation framework with pluggable adapters. It ships with a deterministic CLI and AI assets (agents, skills). Its **windows-desktop** adapter drives WinUI3, Win32, WPF, and WebView2 apps. It does **not embed an LLM**; your AI tool provides intelligence, and the CLI executes deterministic Gherkin feature files against a recorded element store.
* **`comber`**: An "every-click AI QA agent" that has drivers for web (Playwright), API, native (iOS/Android), and **desktop (Windows UI Automation or macOS Accessibility)** under a universal contract. This allows a single agent workflow to verify across platforms.
* **`@bun-win32/uia`**: A package that acts as "Playwright for the Windows desktop." It lets an AI agent (e.g., via MCP) drive the entire desktop through the accessibility tree, which is a deterministic and structured interface.

### 🖥️ TUI Applications: Terminal & tmux

For Terminal User Interfaces, the approach often involves deterministic scripting against a pseudo-terminal.

* **`tuitest`**: A black-box end-to-end harness for TUI applications. It drives the real top-level Bubble Tea model through a real program, testing the full event path. It waits for **visible outcomes** rather than using arbitrary sleep delays, making tests more reliable.
* **TUI Puppeteering with `tmux`** (Agent Skill): A skill for automating isolated TUI testing workflows using `tmux`-based scripts. This provides a deterministic way to script interactions with any TUI app in a controlled terminal environment.

### 🧠 How to Approach This for Your Stack

The strongest strategy is to compose a stack, just as with CLI tools:

1.  **Choose a platform-specific E2E runner**: For Web, use **Verfix** or **`ux-audit`**. For Mobile, **ZMR** or **Mobilewright**. For Desktop, **`vibe-tester`** or **`comber`**. For TUI, **`tuitest`** or a **tmux skill**.
2.  **Add a visual regression layer** (for Web/Desktop/Mobile): Use **`@blazediff/agent`** to catch unintended visual changes.
3.  **Enforce design system & accessibility contracts**: Use skills like **`ui-governance-gate`** and **`verify-ui`** to prevent drift and ensure compliance.
4.  **Wrap it all in a deterministic gate**: The goal is for your agent to run these tools and receive structured JSON evidence (pass/fail, typed errors, traces) that it can parse and act on, closing the loop without human interpretation of "vibes."

The common thread is the same as before: these tools replace the agent's narrative with **executable evidence**—deterministic flows, computed styles, accessibility trees, and replayable traces.

## Are there skills, plugins or mcps for them as well available we could use?

Yes, most of the UI/UX tools from the previous list now have skills, plugins, or MCP servers available. Here's the ecosystem mapped out.

### 🌐 Web Applications

* **Verfix**: MCP/skill packaging is on the roadmap (Phase 5) as a GitHub issue; the `AGENTS.md` stub already exists, but it's not shipped yet.
* **@blazediff/agent**: Ships a portable `SKILL.md` playbook. Install it to `~/.codex/skills/blazediff/` and the `/blazediff` command works globally.
* **ux-audit**: Has a dedicated MCP server (`ux-audit-mcp`) that orchestrates via `skills/_orchestrator/SKILL.md`. It uses Chrome MCP or Playwright MCP for browser automation.
* **ui-governance-gate**: Available as an Agent Skill (installable via `npx skills add`) for Claude Code and Codex. It runs deterministic UI governance checks and orchestrates ESLint/Stylelint/Playwright under one evidence directory.
* **verify-ui**: Backed by the `rolepod-uiproof` MCP server. The `/verify-ui` skill drives a real browser session and calls `rolepod_verify_ui_flow` on that MCP server to assert outcomes.
* **Other Web MCP servers**: `@shiplightai/mcp` (deterministic browser actions driven by element indices, no AI API key needed), `@stateproof-dev/mcp-server` (frontend state machine validation in headless Chromium), `ui-craft-mcp` (deterministic design-quality gate with anti-slop rules), and `OrchestrUI` (UI policy and quality gates).

### 📱 Mobile Applications

* **Zeno Mobile Runner (ZMR)**: Has a full MCP server (`zmr mcp`). It exposes **26 mobile-native tools** over MCP, JSON-RPC, or a JSON-output CLI. Agents can discover traces, explore semantic snapshots, and draft scenarios offline.
* **Mobilewright**: Has an MCP server (`mobilewright-mcp`). It exposes the device's accessibility tree directly, so agents use deterministic semantic actions instead of vision models. Works with mobile-mcp, Claude, Cursor, or any coding agent.
* **Other Mobile MCP servers**: `@luxurylabs/maestro-mcp` (32 tools for Android/iOS via Maestro CLI), `@mobilepixel/mcp` (20 tools built on Appium), `MetaMask/device-mcp` (iOS, Android, and BrowserStack), `@mobilenext/mobile-mcp`, and `phantom-mcp` (22 tools for iOS/Android from Claude Code).

### 💻 Desktop Applications

* **vibe-tester**: Explicitly **does not** run an MCP server. It ships AI assets (agents, skills, `AGENTS.md` template) and a deterministic CLI. Your AI tool provides the intelligence; the CLI is the integration surface.
* **comber**: Has an MCP server (`comber-mcp`). Point your editor's agent at a preview URL and it walks the app, reporting broken clicks, dead ends, console errors, and broken links inline.
* **@bun-win32/uia**: Is itself an MCP server (registered as `io.github.ObscuritySRL/bun-uia`). Install with `claude mcp add uia -- bunx bun-uia`; it exposes **61 policy-gated tools** (55 under the default safe profile) for driving the entire Windows desktop through the accessibility tree.
* **Other Desktop MCP servers**: `windows-desktop-mcp` (21 tools, 319 actions for UI Automation + Playwright), `windows-computer-use-mcp`, `windows-mcp`, and `mcp-windows-desktop-automation` (AutoIt-based).

### 🖥️ TUI Applications

* **tuitest**: No direct MCP found, but the tmux-based testing ecosystem covers the same ground.
* **tmux TUI testing**: Multiple MCP servers and skills exist: `@dragoscirjan/mcp-tuikit` (tmux + native terminal backends, end-to-end TUI testing), `imprint` (lets AI agents control a terminal via MCP for precise TUI testing), and `terminal-use-mcp` (tmux provider). There are also skills like `tmux-python/libtmux-mcp` and `testing-mcp-with-cli-agents` for driving interactive agent TUIs.
* **Other TUI MCP servers**: `tuiwright` (Playwright-style MCP for TUI apps), `tui-mcp` (launch any TUI app, take screenshots, send keystrokes), and `textual-mcp-server` (headless Textual TUI inspection via Pilot API).

### 🔍 General Visual Regression MCP Servers

Beyond specific tools, there's a growing set of visual regression MCP servers: `@tanguito/visual-regression-mcp` (pixel comparison + diff generation), `@visualq/mcp` (43 tools, multi-pillar audit), `@lastest/mcp-server` (24 tools for run/verify/approve baselines), and `vrt-mcp` (Odiff-based with Figma integration).

### 💡 The Practical Takeaway

The pattern is consistent: **tools that need an MCP server have one; tools designed as CLI-first ship a `SKILL.md` instead.** For a zero-bluff stack, you can install the skill or MCP for each platform layer and let your agent call them as deterministic gates. The evidence each one produces (exit codes, structured JSON, typed failure codes, accessibility-tree snapshots, replayable traces) is what replaces the agent's narrative.

## Give us all of this exact proven opensource soultions and repos in one big consistent list

Here is the complete, consolidated list of open-source solutions, repos, skills, plugins, and MCP servers for deterministic UI/UX validation and verification, organized by platform.

---

### 🛡️ General Deterministic Verification Frameworks (CLI-First)

These are foundational layers that can gate any agent's output.

*   **DoneSpec**: A deterministic completion layer for AI coding agents. It turns "done" into a machine-checkable contract via a `done.json` file. A task is not done until `donespec validate done.json` passes.
*   **Determ8**: Wraps a probabilistic model in a deterministic pipeline. The agent proposes, and the pipeline proves via Schema, FSM, Idempotency, and Graph gates. Same input + same config = same verdict, always.
*   **Kedge**: A deterministic AI agent execution and verification harness written in Rust. It includes a ReAct engine, hard budgets, Shadow-Guard interception, MCP server, and SQLite replay.
*   **Skill Doctor**: A statically linked Rust binary for deterministic, multi-layer security analysis of AI agent skill files. It detects malicious prompt injections and obfuscation with no interpreter or network required.
*   **Agent Skills CLI (blackwell-systems)**: An ecosystem-aware CLI for validating and upgrading Agent Skills. It enforces spec compliance, detects vendor extensions, and converts large skills into progressive disclosure.
*   **check-skills**: A vendor-neutral CLI for validating, linting, and improving portable Agent Skills that follow the agentskills.io specification.

### 🌐 Web Applications: E2E, Visual & Governance

These tools focus on browser-based flows, visual consistency, and design system governance, providing structured, parseable evidence for agents.

**CLI Tools & Skills**

*   **Verfix**: A local-first browser verification runtime. It runs deterministic browser flows from the CLI and returns structured JSON with typed failure codes. It has a "strict" mode that is fully deterministic with zero AI/token cost.
*   **@blazediff/agent**: A deterministic CLI for visual regression testing. It discovers routes, screenshots them with Playwright, and diffs against committed baselines. It hands ambiguous visual diffs to a coding agent as compact "region tiles" instead of full PNGs.
*   **ux-audit**: A deterministic UI/UX testing platform. It audits URLs using deterministic checks (Axe for accessibility, Lighthouse for performance) and writes a structured evidence bundle your agent can use to prioritize fixes.
*   **ui-governance-gate**: An Agent Skill that enforces a hard, deterministic gate for UI consistency, checking for Tailwind style drift, hard-coded colors, and contract misuse. It records all evidence in a structured run directory.
*   **verify-ui**: An Agent Skill backed by the `rolepod-uiproof` MCP server. It drives a real browser session and asserts outcomes, including console errors, network failures, and visual state.

**MCP Servers**

*   **@shiplightai/mcp**: A deterministic browser MCP server. Actions are driven by element indices returned from `inspect_page`, not by a model. Every action returns replay-ready locator data.
*   **@stateproof-dev/mcp-server**: An MCP server bridge for Stateproof frontend runtime validation. It forces loading, empty, error, and offline states at the browser wire via CDP with zero app code tampering.
*   **ui-craft-mcp**: A deterministic design-quality gate exposed as a stdio MCP server. It provides tools for anti-slop, token lint, acceptance bar, and a composite UI score.
*   **OrchestrUI**: Provides deterministic UI policy, discovery, and quality gates for coding agents. It exposes read-only MCP tools for listing libraries, recommending stacks, and auditing plans.

### 📱 Mobile Applications: Native & Flutter

These tools drive real devices or simulators deterministically, with zero LLM in the verification loop.

**CLI Tools & Skills**

*   **Zeno Mobile Runner (ZMR)**: A small Zig binary that gives a deterministic yes/no on whether an AI agent's change broke the mobile app. It runs saved scenarios on real iOS/Android devices and returns typed pass/fail results with replayable traces. No LLM inside.
*   **Mobilewright**: A dev framework for Mobile App Testing and Automation. It exposes the device's accessibility tree directly, providing deterministic, token-efficient, and structured context for AI agents without needing a vision model.

**MCP Servers**

*   **ZMR MCP**: Zeno Mobile Runner exposes 26 mobile-native tools over MCP. Agents can discover traces, explore semantic snapshots, and draft scenarios offline.
*   **mobilewright-mcp**: An MCP Server for Mobilewright device automation.
*   **@luxurylabs/maestro-mcp**: An MCP server that gives any AI assistant full control over Android emulators and iOS simulators through Maestro CLI, generating and running mobile flows from natural language.
*   **@mobilepixel/mcp**: An MCP server built on Appium. It provides 20 essential tools for iOS and Android testing.
*   **@metamask/device-mcp**: An MCP server for mobile device interaction across iOS (IDB), Android (ADB), and remote devices (Appium/BrowserStack).
*   **@mobilenext/mobile-mcp**: An MCP server for mobile development and automation that enables scalable mobile automation through a platform-agnostic interface for iOS, Android, emulators, simulators, and real devices.
*   **Appium MCP**: An MCP server for mobile development and automation with Appium on steroids.

### 💻 Desktop Applications: Native & Electron

These adapters bring deterministic automation to Windows and macOS native apps.

**CLI Tools & Skills**

*   **vibe-tester**: An AI-driven UI automation framework with pluggable adapters. Its **windows-desktop** adapter drives WinUI3, Win32, WPF, and WebView2 apps. It does not embed an LLM; your AI tool provides intelligence, and the CLI executes deterministic Gherkin feature files.
*   **comber**: An "every-click AI QA agent" with drivers for web, API, native, and desktop (Windows UI Automation or macOS Accessibility). It reports broken clicks, dead ends, console errors, and broken links inline.

**MCP Servers**

*   **comber-mcp**: An MCP server for Comber that runs every-click QA checks from any MCP client (Cursor, Claude, Windsurf, Zed).
*   **@bun-win32/uia (bun-uia)**: An MCP server that is "Playwright for the Windows desktop." It exposes the entire Windows desktop through the accessibility tree as 61 policy-gated tools.
*   **windows-desktop-mcp**: An MCP server with 21 tools and 319 actions for UI Automation and Playwright.
*   **windows-computer-use-mcp**: An MCP server for Windows computer use.
*   **windows-mcp**: An MCP server for Windows automation.
*   **mcp-windows-desktop-automation**: An AutoIt-based MCP server for Windows desktop automation.

### 🖥️ TUI Applications: Terminal & tmux

For Terminal User Interfaces, the approach involves deterministic scripting against a pseudo-terminal.

**CLI Tools & Skills**

*   **tuitest**: A black-box end-to-end harness for TUI applications. It drives the real top-level Bubble Tea model through a real program, testing the full event path. It waits for **visible outcomes** rather than using arbitrary sleep delays.
*   **microsoft/tui-test**: A terminal automation, inspection, assertion, and recording engine written in Rust with Python and JavaScript bindings.
*   **tmux TUI testing (Agent Skill)**: A skill for automating isolated TUI testing workflows using `tmux`-based scripts, providing a deterministic way to script interactions with any TUI app in a controlled terminal environment.

**MCP Servers**

*   **@dragoscirjan/mcp-tuikit**: An MCP server that uses tmux and native terminal backends for end-to-end TUI testing. It launches each app in its own session, making it perfect for CI/CD pipelines.
*   **imprint**: Lets AI agents control a terminal and see what's on screen via MCP, allowing precise TUI testing that is framework-agnostic.
*   **terminal-use-mcp**: A local and remote terminal interaction control MCP server. Lets AI agents control interactive TUI programs the way a human would.
*   **tuiwright**: A Playwright-style MCP for TUI apps.
*   **tui-mcp**: Launch any TUI app, take screenshots, and send keystrokes via MCP.
*   **textual-mcp-server**: Headless Textual TUI inspection via the Pilot API.

### 🔍 General Visual Regression MCP Servers

These are cross-platform MCP servers focused specifically on visual diffing.

*   **@tanguito/visual-regression-mcp**: An MCP server for visual regression testing with pixel comparison, diff generation, and markdown reporting.
*   **@lastest/mcp-server**: An MCP server exposing 24 tools for AI agent integration: run/verify tests, review and decide diffs, approve baselines, create/heal tests, and check coverage.
*   **vrt-mcp**: An Odiff-based visual regression test tool for agentic coding with Figma API integration.
*   **@visualq/mcp**: A multi-pillar audit MCP server with 43 tools.
*   **mcp-webgl-visual-regression**: An MCP server for WebGL visual regression testing with automated screenshot comparison.

### 💡 The Practical Takeaway

The pattern is consistent: **tools that need an MCP server have one; tools designed as CLI-first ship a `SKILL.md` instead.** For a zero-bluff stack, install the skill or MCP for each platform layer and let your agent call them as deterministic gates. The evidence each one produces—exit codes, structured JSON, typed failure codes, accessibility-tree snapshots, and replayable traces—is what replaces the agent's narrative.

## Now exdtend everything with the following capabilities (opensource projects / repo): video playback, multimedia, audio playback, multi display validation and verification, content in all these, quality in all thse

Here is the extended, consolidated list. It adds deterministic, evidence-producing open-source solutions for **video/audio playback, multimedia content, multi-display validation, and content quality** to the UI/UX stack from the previous list.

---

### 🎬 Video Playback & Multimedia Validation

These tools validate that a browser, device, or app can actually play the media it claims to support, returning pass/fail evidence rather than a narrative.

*   **MVT (Media Validation Tool)** — A browser-based tool that verifies media playback capabilities across four streaming formats (Progressive, DASH, HLS, HSS) and four players (native, Shaka Player, dash.js, hls.js). It tests different audio/video/subtitle codecs and containers, building on YouTube's `js_mse_eme` framework. Deployable via Docker with a CLI-driven asset preparation step. Open source under `rdkcentral/MVT`.
*   **Fluster** — A Python CLI testing framework for **decoder conformance**. It runs test suites against H.265/HEVC, H.264/AVC, and other decoders, checking whether the decoder output matches the expected reference. Ideal for deterministic, bit-exact media verification in CI. Open source (`Debian fluster package`, `salsa.debian.org/multimedia-team/fluster`).
*   **WAVE Device Observation Framework (DPCTF)** — A CTA WAVE project that determines **pass/fail based on screen recordings** of tests run on a device. It analyzes recorded video (typically at ~120 fps) to verify device playback compatibility per the CTA WAVE specification. Works alongside the DPCTF Test Runner. Open source (`cta-wave/device-observation-framework`).
*   **Bitmovin Stream Lab MCP Server** — An MCP server that lets AI agents create, run, and analyze **video playback tests on 30+ physical targets** (Samsung/LG/Vizio TVs, browsers, consoles) via natural language. Can be combined with Bitmovin's Observability MCP for real QoE data. Commercial product but exposes an MCP interface; useful as an integration pattern.

### 🔊 Audio Playback & Quality Verification

These tools provide objective audio measurements (loudness, true-peak, spectral analysis) as MCP-callable tools.

*   **@audiolabtools/mcp-server** — An MCP server giving any MCP-capable AI **nine audio-analysis tools** backed by the AudioLab API. Covers loudness (EBU R128 / BS.1770-4), true-peak, voice-quality, and signal analysis. No local audio engine required.
*   **mcp-audio-tweaker** — An MCP server for batch audio processing and optimization using FFmpeg. Supports sample rate conversion, bitrate adjustment, volume control, channel configuration, and audio effects. Open source (`DeveloperZo/mcp-audio-tweaker`).
*   **MCP Audio Server** — A Python-based MCP server for professional audio processing and analysis, including parametric EQ, loudness normalization for platform standards (Spotify/YouTube/TikTok), and format conversion. Open source.
*   **audio-analyzer MCP** — Gives LLMs "ears" with spectral, harmonic, rhythm, stereo, and structural audio analysis. Open source (`io.github.JuzzyDee/audio-analyzer`).
*   **AudioQC** — Batch QC analysis of digitized audio collections. Scans for peak/average levels and other archival quality metrics. Open source (`amiaopensource/audioqc`).
*   **Spectre** — Client-side audio quality analyzer that runs entirely in the browser. Renders a spectrogram and estimates real encoding quality, detecting transcodes and fake lossless by finding frequency cutoffs. Open source (`grillofran/spectre`).
*   **WhatsMyBitrate** — A CLI for bulk audio analysis: bit rate, frequency, codec type, and spectrogram generation. Open source (`oren-cohen/whatsmybitrate`).

### 🖥️ Multi-Display Validation & Verification

These tools verify behavior across multiple monitors, screens, or logical/physical displays on Android, macOS, and desktop.

*   **PolyScreen MCP** — An Android-first MCP server built for **multi-display handhelds, gamepads, emulators, and test labs**. It keeps logical display IDs (WindowManager) and physical SurfaceFlinger IDs explicit, returns structured evidence for every operation, and supports dual-display cookbooks (internal + presentation). Open source (`Zyzto/polyscreen-mcp`).
*   **macos-computer-use-skill** — A standalone MCP server giving AI agents full GUI control over macOS with **multi-display support**: capture any display, enumerate monitors, and zoom into regions. Zero private dependencies. Open source (`wimi321/macos-computer-use-skill`).
*   **screenshot-mcp** — A cross-platform MCP server for capturing screenshots, designed for agent-based native app testing. Its skill explicitly guides **multi-display testing** workflows and comparison strategies. Open source (`chunlea/screenshot-mcp`).
*   **GetScreen MCP** — A lightweight MCP server for rapid screenshot capture from **all available monitors** with automatic compression. Supports multi-platform and WSL environments. Available on MCP marketplaces.
*   **Chromium Multi-Screen Testing** — Chromium’s `interactive_ui_tests` support multi-screen environments on desktop platforms via the `VirtualDisplayUtil` interface (`ui/display/test/virtual_display_util.h`). This is the canonical open-source approach for testing multi-display behavior in a browser engine. Source: Chromium UI Platform docs.
*   **Psychtoolbox-3 MultiWindowVulkanTest** — A test for multi-window / multi-display operation in fullscreen exclusive direct display mode under Linux/X11 with Vulkan. Mostly for regression testing. Open source (`Psychtoolbox/PsychTests/MultiWindowVulkanTest.m`).
*   **IGT GPU Tools** — A collection of tools for DRM driver development and testing, including extended-mode tests that require ≥2 displays. Open source (Chromium external / gitlab).

### 📝 Content Quality & Validation

These MCP servers validate the **content** produced by AI agents against scope contracts, factuality, and quality criteria.

*   **qc-validator-mcp** — Runtime quality validation for AI agent outputs. Detects hallucinations, enforces scope compliance, and scores output quality. Tools: score output against configurable criteria (length, keywords, forbidden patterns, factual claim density), estimate hallucination likelihood with source grounding, validate against a scope contract (allowed/forbidden topics, word limits, required sections), and store results for per-agent trending. Pure Node.js, zero config, MIT license.
*   **@soulfield/lens-mcp** — "Outside-in" validation for AI-generated text as an MCP tool. Provides multi-dimensional quality checks for LLM output, including PII detection and cleaning. The explicit design goal is to avoid asking the same model that wrote the answer whether it is any good. Open source (Soulfield Lens).
*   **mcp-factcheck** — An MCP server for validating code or content against official specifications (e.g., the MCP spec itself) to ensure technical accuracy and prevent misinformation. Open source (`mcp-factcheck`).
*   **@contentrain/mcp** — A local-first MCP server for AI-generated content governance with **24 deterministic tools** (19 core + 5 media), stdio and HTTP transports, and Local/GitHub/GitLab providers. Includes validation and auto-fix. Open source (`Contentrain/ai`).
*   **PureRank MCP Server** — A pre-publish QA gate and site-level AI-content-spam scoring scanner for agent publishing pipelines. Available as an MCP server.

### 🎥 Video Quality & Analysis MCP Servers

These are cross-cutting MCP servers specifically for objective video quality metrics.

*   **video-quality-mcp** — An MCP server for video quality analysis providing objective metrics such as **PSNR, SSIM, and VMAF**, plus artifact detection via OpenCV and FFmpeg. Designed to integrate with Claude Desktop for automated video quality inspection, diagnostics, and decision-making workflows. Open source (`hlpsxc/video-quality-mcp`).
*   **kino-mcp** — An MCP server giving AI agents full access to video stream analysis, audio fingerprinting, quality monitoring, and encoding presets, powered by the `kino-cli` Rust binary. Supports automated QC checks on video assets and stream comparison to detect quality regressions.
*   **@avclabs/media-mcp** — A video enhancement, image enhancement/colorization/denoising, and image segmentation service based on the MCP protocol. Open source (`avclabs/media-mcp`).

### 🛠️ Agent Skills for Watching & Listening to Media

These skills let coding agents actually **watch video and listen to audio** rather than guessing from filenames.

*   **claude-video / watch skill** — An Agent Skill that gives an agent a video input. It downloads, extracts scene-aware deduplicated frames, OCRs on-screen text, transcribes (captions first, then local Whisper offline), indexes everything, and hands the result to the agent. Installable across Claude Code, Codex, Cursor, GitHub Copilot, and 50+ other Agent Skills hosts. Open source (MIT, `bradautomates/claude-video`).
*   **watch-skill** — "One video layer, three agent capabilities." Scene-aware frames, on-screen text, and local-first transcription from 1,800+ sites, live HLS/DASH streams, local media, meetings, browsers, windows, and desktops. Open source (`oxbshw/watch-skill`).
*   **ai-agent-video-viewer** — A harness-neutral skill that lets an agent watch video, listen to audio, and extract frames. A single, self-contained pipeline that any shell-capable agent can drive. Open source (`AnshRajput/ai-agent-video-viewer`).
*   **audio-features-expert** — An Agent Skill for working with audio systems: TTS, recording, guided-mode audio, ambient sounds, voice profiles, and audio orchestration. Published on SkillMD.ai.
*   **BridgeSpeak** — A cross-agent skill that wraps OpenAI `gpt-realtime-2` to give Claude Code, Hermes, and OpenClaw agents the ability to speak. The agent does not need to know about WebSockets, base64, PCM16, or audio playback. Open source (`bridge-mind/BridgeSpeak`).

### 💡 How to Compose This Into the Zero-Bluff Stack

The pattern is the same as the core UI/UX stack: **install the MCP or skill, point the agent at it, and let the tool return structured evidence.**

1.  **For media playback**: Use **MVT** or **WAVE DPCTF** for browser/device playback verification. Add **Fluster** for decoder conformance in CI.
2.  **For audio quality**: Use **@audiolabtools/mcp-server** or **MCP Audio Server** for loudness/true-peak checks. Use **Spectre** or **WhatsMyBitrate** for transcode detection.
3.  **For multi-display**: Use **PolyScreen MCP** for Android multi-display, **macos-computer-use-skill** for macOS multi-monitor, and **Chromium’s VirtualDisplayUtil** for browser multi-screen testing.
4.  **For content quality**: Use **qc-validator-mcp** or **@soulfield/lens-mcp** as a pre-publish gate for agent outputs.
5.  **For video quality metrics**: Use **video-quality-mcp** for PSNR/SSIM/VMAF and artifact detection.
6.  **For agent media understanding**: Install **claude-video/watch-skill** so the agent can actually see and hear the media it is supposed to be validating.

Every one of these tools replaces a narrative (“the video plays fine”) with executable evidence: exit codes, PSNR/SSIM scores, spectrograms, display-ID correlation dumps, scope-compliance JSON, or replayable recordings.

