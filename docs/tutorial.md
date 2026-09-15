# Tutorial

**Revision:** 1
**Last modified:** 2026-09-15T00:00:00Z

This is a narrative, first-run walkthrough of llmctl: clone the repo, set
up your machine, download and serve a real model, and drive it from a real
coding agent (`aider`) to make one small edit to a real file. It is meant
to be read top-to-bottom the first time you touch this project — for the
terser command reference, see `docs/quickstart.md`; for the full command
table and safety model, see `README.md`.

## What you'll build

By the end of this tutorial you will have a local coding model served on
`127.0.0.1:8081` by llmctl, and you will have used `aider` — one of the
seven CLI coding agents llmctl supports — to make a real, verifiable edit
to a small Python file, entirely offline, with no API keys and no data
leaving your machine.

## 1. Clone and set up

```bash
git clone --recursive <this-repository-url> llmctl
cd llmctl
./bin/llmctl setup
```

`--recursive` matters: llmctl vendors its two inference engines —
`llama.cpp` and `colibri` — as pinned git submodules under `vendor/`
(see `README.md`'s introduction). If you forget it, `git submodule update
--init` (or just running `llmctl build`, which initializes them itself)
fixes it after the fact.

`llmctl setup` runs three phases, each independently inspectable
(`bin/llmctl`'s `cmd_setup` function):

1. **`llmctl doctor`** — an environment self-diagnosis. Every line is
   `PASS`/`WARN`/`FAIL` with real evidence attached (e.g. the actual
   submodule commit hash), never a bare claim.
2. **Engine build** — compiles `llama.cpp` (CUDA/ROCm/Metal/CPU backend,
   auto-detected) and `colibri`.
3. **Hardware plan** — probes your CPU/SIMD, RAM, GPU/VRAM, and storage,
   classifies your machine into a tier, and prints which catalog profiles
   fit *this host, right now*.

If `doctor` reports a `FAIL`, `setup` stops there — fix what it names and
re-run. This whole sequence is worth watching the first time; it's the
fastest way to understand what llmctl thinks your hardware can do before
you commit to a multi-gigabyte download.

For the deeper mechanics of this step (what each doctor check verifies,
how the automated test for this exact sequence works), see
`docs/quickstart.md` section 1 — this tutorial won't repeat it.

## 2. Check what your hardware can run

Two commands give you the same information setup already printed, on
demand, any time later:

```bash
./bin/llmctl hw            # human-readable hardware probe
./bin/llmctl hw --json     # same data, machine-readable
./bin/llmctl plan          # which profiles fit, and why
```

`hw` is a live probe — no cached or assumed values (per `bin/llmctl`'s
`hw|probe` case, it either prints `hw_probe_json` or `hw_probe_human`
depending on the `--json` flag). `plan` feeds that probe into the model
catalog and tells you which profiles from `models/catalog.json` your
machine can actually run, at what context length, and whether they can
run *together* (co-residency groups).

llmctl classifies every host into one of four tiers — `below-minimum`,
`baseline`, `workstation`, `datacenter` — from the live probe, never from
hardcoded assumptions about "what a laptop looks like." The full
breakdown of what each tier unlocks lives in `docs/hardware-tiers.md`; the
short version from `README.md`: a baseline machine (something like a
Ryzen 7 2700X, 32 GB RAM, RTX 3060 12 GB) already runs `fast`, `coder`,
`vision`, `moe-fast`, and `small`, including several of them at once.
Workstation-tier hosts unlock the `ws-*` profiles; `colibri-glm` (a
744B-parameter MoE model that streams weights from ~380 GB of NVMe) needs
`datacenter` tier.

For this tutorial we want a coding model, so we're aiming at the `coder`
profile — check `llmctl models list` (or the table in
`docs/integrations.md`) and confirm your `plan` output includes it before
moving on. If it doesn't, `fast` (Llama 3.1 8B, the lightest chat-capable
profile) is a safe fallback for following the rest of these steps.

## 3. Download a real model

```bash
./bin/llmctl models download coder
```

`coder` maps, per `models/catalog.json`, to `Qwen3-Coder-30B-A3B-Instruct-
Q4_K_M.gguf` — Qwen3-Coder 30B-A3B (an MoE model), served by `llama.cpp`
on port 8081, catalog size ~18.6 GB. If that's more than you want to pull
down right now, `fast` (Llama 3.1 8B Instruct Q4_K_M, ~4.9 GB) works
identically for everything below except the "coding" flavor of the task —
just substitute `fast` for `coder` and port `8080` for `8081` everywhere
below.

This download is not a bare `curl`. Per `README.md`'s "Safety guarantees"
section:

* The download is **resumable** — an interrupted download picks back up
  rather than restarting.
* Every file is **checksummed against a sha256** captured from the
  Hugging Face API at catalog-generation time. Mismatched content never
  lands at the final path — verification happens before the atomic
  rename, and the evidence (command, exit code, output) is appended to
  `~/.local/state/llmctl/verify/<profile>.log`.
* The model is then **smoke-tested**: llmctl boots it in a real
  `llama-server` (CPU-only, small context) and requires it to correctly
  answer the deterministic prompt `"Reply with exactly: OK"` before the
  download is accepted as successful. A file that downloads cleanly but
  fails to actually run is not accepted.

So by the time `models download` exits, you don't just have bytes on
disk — you have cryptographic proof they're the right bytes, and a live
runtime proof the model actually loads and answers.

## 4. Start it

```bash
./bin/llmctl start coder
```

Expected output (per `docs/quickstart.md`'s documented shape):

```
started coder (mode=<cpu|gpu>, port=8081, reserved <N> MiB RAM + <N> MiB VRAM)
```

`mode` depends on what `llmctl hw` detected on your machine — `gpu` if a
supported GPU with enough free VRAM was found, `cpu` otherwise. The
scheduler computes a footprint for the profile before starting it and
refuses (with exact numbers and a suggested alternative) if it wouldn't
fit — see `README.md`'s "Co-residency and switching" section for how this
plays out when you have several profiles running at once.

Confirm it's actually alive:

```bash
curl -fsS http://127.0.0.1:8081/health
```

An HTTP 200 here (llama.cpp's built-in health endpoint) means the server
is up and ready for requests — this is the same live check
`docs/quickstart.md` walks through in more depth for the `fast` profile,
including a raw `/v1/chat/completions` call you can try directly with
`curl` if you want to see the model answer before wiring in an agent.

## 5. Configure aider against it

We'll use [`aider`](https://aider.chat) for this tutorial — one of the
seven CLI agents llmctl documents integration for in
`docs/integrations.md` (the others are opencode, pi, crush, Claude Code,
continue.dev, and Cline; see that file if you'd rather use one of those
instead — the same pattern applies to all of them).

**Install aider** (per `docs/integrations.md`'s "aider" section, verified
there against `https://aider.chat/docs/install.html`):

```bash
curl -LsSf https://aider.chat/install.sh | sh
```

(`docs/integrations/install_aider.sh` automates this exact check-then-
install-then-verify sequence if you'd rather run a script than the
one-liner by hand — it checks for an existing `aider` on `PATH` first and
only installs if absent, then verifies with real `aider --version`
output.)

**Point aider at your running `coder` server.** `llama-server` speaks the
OpenAI-compatible API, so aider's OpenAI provider settings work directly
— no proxy needed. Set two environment variables and pass the model name
straight from `docs/integrations.md`'s aider section:

```bash
export OPENAI_API_BASE="http://127.0.0.1:8081/v1"
export OPENAI_API_KEY="local"
```

(`OPENAI_API_KEY` is required by aider's client library even though
llmctl's servers don't check it — `"local"` or any non-empty string
works, since everything binds to `127.0.0.1` and never leaves your
machine per `README.md`'s "Local-only" safety guarantee.)

The model id aider needs is whatever `GET /v1/models` reports for your
running server (per `docs/integrations.md`'s top section) — for `coder`
this is the GGUF filename, `Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf`. You
can confirm it directly:

```bash
curl -fsS http://127.0.0.1:8081/v1/models
```

## 6. Use it: make a real edit

Create a tiny scratch file to edit — anywhere outside the llmctl repo is
fine:

```bash
mkdir -p ~/scratch/aider-demo && cd ~/scratch/aider-demo
cat > bar.py <<'EOF'
def foo(x):
    return x + 1
EOF
```

Now drive aider against your local `coder` server with a small, concrete
task:

```bash
aider --model openai/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf \
  --message "add a one-line docstring to function foo in bar.py" \
  bar.py
```

(This is the same shape of prompt `docs/quickstart.md`'s release-gating
live-challenge procedure uses for exactly this purpose — see its section
4.2 if you want to understand how llmctl's own test suite exercises this
same path deterministically with a fixed seed.)

aider will read `bar.py`, send the edit request to your local `coder`
server over the OpenAI-compatible API you configured in step 5, and
(assuming the model complies) write back a version of `bar.py` with a
docstring added — entirely served by the model running on your own
machine, no network calls beyond `127.0.0.1`. Open `bar.py` afterward and
confirm the docstring landed:

```bash
cat bar.py
```

If you'd rather see the raw model response before trusting an agent to
apply it, `docs/quickstart.md` section 2.3 shows the equivalent direct
`curl` call against `/v1/chat/completions` — useful for sanity-checking
that the *model* is answering correctly before blaming the *agent* if
something looks off.

## 7. Clean up

```bash
./bin/llmctl stop coder
```

(Or `./bin/llmctl stop all` if you started more than one profile while
exploring.) `stop` releases the port and the RAM/VRAM reservation so
another profile can use that budget.

## A note on what llmctl doesn't do yet

`bin/llmctl` also has `cluster`, `tenant`, and `apikey` subcommands (e.g.
`llmctl cluster status`, `llmctl tenant create <name>`, `llmctl apikey
create <scope>`). These are real, present-in-the-CLI commands, but every
one of them currently hard-fails with an explicit "not yet implemented"
message citing the phase and user story that will land it (e.g. `llmctld
reachable but 'cluster join' is not yet implemented (Phase 9, US7)`) —
they're future multi-node/multi-tenant features, not something you can
use today. Single-host usage (everything this tutorial covers) never
depends on them.

## Where to go next

* **Multiple models at once** — `README.md`'s "Co-residency and
  switching" section covers `llmctl start <p1> <p2> ...`, the
  budget-refusal behavior, and `llmctl auto <capability>...`'s
  LRU-eviction logic for automatically picking the best set of models
  that fit right now.
* **The full release-gating verification procedure** (real model, real
  API, all 7 CLI agents, determinism proof) — `docs/quickstart.md`
  sections 2 and 4, if you want to see the rigor llmctl holds itself to
  before a release ships.
* **The other six CLI agents** (opencode, pi, crush, Claude Code,
  continue.dev, Cline) — `docs/integrations.md` has a config snippet and
  install instructions for each, plus the full port table if you want to
  run several agents against several profiles simultaneously.
* **Persistent, autostart-at-login services** (systemd `--user` on Linux,
  launchd on macOS, crash-loop bounding) — `README.md`'s "Safety
  guarantees" section, and `llmctl enable`/`llmctl disable` in the
  command reference.
