## Overview

`docs/integrations/install_crush.sh` installs and verifies [crush](https://github.com/charmbracelet/crush)
(Charm's terminal coding agent) for use against a running llmctl profile. It
exists to satisfy FR-011 of `specs/001-llmctl-completion/spec.md`: crush
must be installable via its own documented setup mechanisms and testable
against a running llmctl server. The script performs the *automated* half of
that requirement (install-if-absent, then capture real verification
evidence); `docs/integrations.md` documents the manual half and the
`crush.json` provider config llmctl needs. Unlike most of the sibling
`install_<agent>.sh` scripts, crush has no official `curl | bash`
one-liner installer, so this script picks between three real package-manager
install paths (`npm`, `brew`, `go`) depending on what is already present on
the host.

## Prerequisites

* `bash` (the script is written and tested as a bash script, `set -euo pipefail`).
* At least one of `npm`, `brew`, or `go` on `PATH` if `crush` is not already
  installed — the script has no other automated install path and will FAIL
  with manual instructions if none of the three is found.
* `tput` is optional (only used to detect an interactive terminal for color
  output); its absence just means plain, uncolored PASS/FAIL/WARN lines.
* No llmctl `lib/` sourcing and no environment variables are read — the
  script is standalone and fetchable/runnable on its own, exactly like the
  other `install_<agent>.sh` scripts.
* Network access to whichever package registry the chosen installer talks to
  (npm registry, Homebrew's tap, or the Go module proxy for
  `github.com/charmbracelet/crush`).

## Usage examples

Run it directly, with no arguments:

```bash
bash docs/integrations/install_crush.sh
```

Safe to re-run — if `crush` is already on `PATH` the script skips
installation entirely and only re-verifies:

```bash
bash docs/integrations/install_crush.sh
# ... WARN crush already present on PATH (/usr/local/bin/crush); skipping install, verifying only.
# ... PASS crush installed and verified. `crush --version` -> crush version v0.4.2
```

Forcing a specific installer is not exposed as a flag; the script always
tries `npm` first, then `brew`, then `go`, in that fixed order (see
"Internal behaviour"). To force a particular method, temporarily hide the
others from `PATH` or pre-install crush yourself with your preferred method
before running this script (it will then just verify).

## Edge cases

* **crush already on `PATH`**: the script emits a `WARN` line naming the
  existing binary path and skips straight to verification — no
  package-manager command is invoked at all.
* **No `npm`, `brew`, or `go` present**: the script `FAIL`s with
  `"No supported installer (npm, brew, go) found on PATH."` and prints
  `_icr_manual_install_help`, a full block of every other documented install
  method (Arch/yay, Nix, FreeBSD pkg, winget, Scoop, and the signed
  apt/yum repository commands) so the operator can pick one by hand —
  the script never invents an install command that isn't real
  (Constitution §11.4.6).
* **Chosen installer command exits non-zero** (any of the three): the
  script `FAIL`s naming exactly which command failed, then still prints the
  same manual-install help block before returning `1`.
* **`go install` succeeds but `crush` still isn't resolvable**: `go install`
  places the binary under `$(go env GOBIN)` if set, else
  `$(go env GOPATH)/bin`, else `~/go/bin` — none of which are guaranteed to
  already be on `PATH`. The script resolves this location itself and
  prepends it to `PATH` in-process (`export PATH="${go_bin}:${PATH}"`) only
  if the binary is actually found there (`[[ -x "${go_bin}/crush" ]]`) —
  it does not blindly assume the Go install layout.
* **Install command succeeded but `crush` is still not found on `PATH`**
  (e.g. a shell-rc-only PATH update that this already-running shell process
  never picked up): the script `FAIL`s with an explicit instruction to open
  a new shell or add the install location to `PATH` manually, rather than
  silently reporting success.
* **`crush --version` itself exits non-zero** after a successful-looking
  install: the script `FAIL`s and includes the command's actual captured
  output (stdout+stderr combined via `crush --version 2>&1`) in the failure
  message — never a bare "failed" with no evidence.
* **Non-interactive / non-TTY output** (e.g. piped to a file or CI log):
  color codes are only emitted when `[[ -t 1 ]]` is true AND `tput` reports
  ≥8 colors; otherwise every `_icr_c_*` variable stays an empty string, so
  PASS/FAIL/WARN prefixes degrade gracefully to plain text.

## Internal behaviour

1. **Color setup** (top of file): probes `[[ -t 1 ]]` (stdout is a terminal)
   and `tput colors` to decide whether to set ANSI green/red/yellow/reset
   escape sequences into `_icr_c_*` variables, or leave them empty.
2. **Helper functions**: `_icr_pass`, `_icr_fail`, `_icr_warn` each print a
   colorized `PASS`/`FAIL`/`WARN` prefix followed by a message —
   `_icr_fail`/`_icr_warn` go to stderr, `_icr_pass` to stdout.
   `_icr_manual_install_help` prints the full multi-method manual-install
   reference block to stderr (heredoc, not interpolated — the block is
   static documentation text).
3. **`main()`**:
   * If `crush` is **not** on `PATH`: tries, in order, `npm install -g
     @charmland/crush` (if `npm` exists), else `brew install
     charmbracelet/tap/crush` (if `brew` exists), else `go install
     github.com/charmbracelet/crush@latest` (if `go` exists); any command
     failure calls `_icr_manual_install_help` and returns `1` immediately.
     After a successful `go install`, it additionally resolves and
     PATH-prepends the Go bin directory if `crush` still isn't resolvable
     (see "Edge cases"). If none of the three tools exists, fails with the
     manual-install block.
   * If `crush` **is** already on `PATH`: emits a `WARN` and skips straight
     to the verification step below.
   * **Post-install/skip check**: re-checks `command -v crush`; if still
     absent, fails with an explicit "open a new shell" instruction.
   * **Verification**: captures `crush --version 2>&1` into
     `version_output`; on non-zero exit, fails with that captured output; on
     success, emits two `PASS` lines — the version string, and the resolved
     binary path (`command -v crush`).
4. `main "$@"` is invoked unconditionally at the bottom of the file (no
   argument parsing — the script takes none).

## Related scripts

* Sibling `install_<agent>.sh` scripts documented by another agent in this
  same batch: `install_aider.sh`, `install_claude_code.sh`,
  `install_cline.sh`, `install_continue.sh` — all follow the identical
  install-if-absent-then-verify-with-captured-output shape, differing only
  in which agent and which install mechanism(s) they use.
* `docs/integrations.md` — documents crush's llmctl provider config
  (`~/.config/crush/crush.json`) and links to this script under "Installing
  crush".
* Not exercised by any `tests/test_*.sh` in `make test` — per
  `docs/integrations.md`, none of the `install_<agent>.sh` scripts are
  invoked automatically by `llmctl setup` or `make test`; installing
  developer tooling onto a host is a deliberate, manual/release-gating
  step.
* Unrelated to `docs/integrations/normalize_crush.sh` — that script filters
  crush's *run output* for determinism testing, whereas this script
  installs the `crush` binary itself.

## Last verified date

2026-09-17
