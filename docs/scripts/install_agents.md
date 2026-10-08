## Overview

`scripts/install_agents.sh` installs, user-locally and idempotently, the three coding agents llmctl's
integration kit exercises but a stock host lacks - **aider**, **Continue CLI (`cn`)** and **Cline CLI
(`cline`)** - and reports installed / version / headless form for all seven supported agents. It implements
operator decision OD-5 (T100): official installers only, never as root, every download recorded.

## Prerequisites

`bash`, `python3`, `curl`, `openssl`, `base64`; `npm` (cn, cline) and `uv` (aider; uv fetches a managed
Python 3.12 itself when the host Python is newer than aider supports - that download is noted in the record).

## Usage examples

```sh
scripts/install_agents.sh --dry-run          # print the plan; no network, no writes
scripts/install_agents.sh                    # install what is missing
scripts/install_agents.sh --only cn,cline
scripts/install_agents.sh --check            # all seven agents: installed=yes|no version=... headless=...
scripts/install_agents.sh --prefix DIR --bin DIR --log FILE   # relocate everything (tests do)
```

Defaults: install roots `~/.local/share/llmctl/agents/<name>/`, shims in `~/.local/bin`, record
`~/.local/state/llmctl/agents-install.jsonl` (a user run no longer appends to the tracked evidence file;
pass `--log specs/009-jev-decision-models/evidence/agents-install.jsonl` to refresh that evidence on
purpose), pins `scripts/agents.lock` (`--lock FILE`). `LLMCTL_AGENTS_NPM` / `LLMCTL_AGENTS_UV` override the
executables, `LLMCTL_AGENTS_PYPI_BASE` the PyPI JSON base (the test uses fakes and `file://`),
`LLMCTL_AGENTS_ALLOW_SCRIPTS=1` lets npm run lifecycle scripts (default `--ignore-scripts`).
`--write-lock` appends the pin line of a verified install to the lock file.

## Edge cases

* Exit 0 ok, 1 an agent missing under `--check` or an install/verification failed, 2 usage (unknown agent or
  flag); refuses to run as root.
* **Checksums (C-08).** The artifact that is verified is the artifact that is installed. npm packages:
  `npm pack pkg@version` downloads the tarball once, its sha512 is compared with the registry's
  `dist.integrity` (or the pin in `scripts/agents.lock`), and `npm install --ignore-scripts <that tarball>`
  installs that same file; a mismatch (or a missing integrity) aborts the agent and writes no shim, and the
  installed binary must answer `--version`. aider: the py3-none-any wheel PyPI publishes for the resolved
  version is downloaded, its sha256 compared with PyPI's digest (or the pin), and `uv tool install` is given
  that wheel file; when PyPI metadata is unreachable aider is installed from `aider-chat@latest` and the record
  says `integrity_verified:false` (and the console says UNVERIFIED). The record states honestly what is NOT
  covered: `dependency_tree_pinned:false` (npm / uv resolve the transitive dependencies themselves),
  `pinned` (a lock entry was used) and `integrity_source` (`lock` | `registry` | `pypi`). The digest is
  computed with `openssl base64 -A` / `openssl dgst`, portable to macOS.
* Already installed (shim present) is a no-op with no new record. `--check` runs only `--version` and
  `--help` of each agent, with a 20 s timeout, and never a prompt.
* Headless detection greps `--help` for the documented flag (`--message`, `-p/--print`, `-y/--yolo`, ...);
  `unknown` means the flag was not found, not that the agent cannot run headless.

## Internal behaviour

`install_npm` resolves the version (lock pin, else `npm view`), packs and verifies the tarball, runs
`npm install --prefix <root>/<name> --ignore-scripts <tarball>`, writes `~/.local/bin/<bin>` as a one-line `exec` shim, and appends one
JSON object (`agent, method, package, version, source_url, sha512_integrity|sha256, integrity_verified,
prefix`, `integrity_source`, `pinned`, `dependency_tree_pinned`). `install_aider` uses `uv tool install --force --python 3.12 --with pip <verified wheel>` with
`UV_TOOL_DIR`/`UV_TOOL_BIN_DIR` pointing into its own root. Tested by
[`test_install_agents.md`](test_install_agents.md).

## Round-3 hardening (C2-02, C2-18)

- **A pinned aider never falls back to latest (C2-02).** When `scripts/agents.lock` pins `aider-chat` and the
  verified wheel cannot be had (PyPI metadata unreachable, unparseable, wrong version) the install exits 1, writes no
  shim and no record, and never runs `uv ... aider-chat@latest`. An **unpinned** aider with no verifiable wheel is
  refused too unless `LLMCTL_AGENTS_ALLOW_UNVERIFIED=1`; then the record states what happened:
  `method` "uv tool install aider-chat@latest (UNVERIFIED: ...)", `integrity_verified:false`,
  `integrity_source:"none"`, `pinned:false`.
- **Limits of the post-install smoke (C2-18).** npm installs run with `--ignore-scripts`
  (`LLMCTL_AGENTS_ALLOW_SCRIPTS=1` lifts it). That skips `cline`'s postinstall, which only builds a startup-speed
  hard-link cache (`bin/.cline`); the platform binary comes from an optional dependency that npm installs regardless.
  This was read from the installed tree, not re-verified by a fresh install (no network). The smoke is
  `<bin> --version` and `<bin> --help` (must print something); records carry `"runtime_smoke":"version+help (exit 0, non-empty stdout)"` (C3-09: both probes must EXIT 0 and print on stdout; stderr text or a crash is not a pass); aider runs `aider --version` on every path (verified or not) with the same rule and records `"version (aider --version, exit 0, non-empty stdout)"`. The probes use `timeout`, else `gtimeout`, else a perl alarm; with none of them they run unbounded and a warning says so (C3-10, stock macOS has no `timeout`; `LLMCTL_AGENTS_CHECK_TIMEOUT` sets the `--check` limit, default 20 s).
  It proves the binary starts and parses arguments, **not** that a native module loaded lazily at first real use
  (sqlite, pty, keytar) works. A headless run (`cn -p` / `cline -y` against the local gateway) is the stronger check;
  it needs a live model, so it is not part of the offline install.
