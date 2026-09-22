## Overview

`scripts/install.sh` is llmctl's one-command bootstrap: it takes a bare
git clone (or a host that already has llmctl installed but wants another
profile added) all the way to "the desired model profile(s) are
downloaded, enabled, running, and will survive the next reboot/logout" —
in a single invocation, non-interactively.

Before this script existed, llmctl already had full systemd --user
integration (`bin/llmctl setup` → `bin/llmctl models download <profile>`
→ `bin/llmctl install` → `bin/llmctl enable <profile>`, the last of which
already calls `loginctl enable-linger` internally — see
`lib/service_linux.sh`), and that mechanism was already proven working
end-to-end on a real host (two profiles genuinely survived a real reboot,
confirmed via `systemctl --user list-units`, real listening sockets, real
GPU memory usage, and unchanged service start timestamps). What was
missing was a *single* command chaining that sequence together, with an
explicit, non-assumed confirmation that lingering actually took effect.
This script is that command.

**A real, root-caused discovery made while writing this script** (verified
live on a real host, not guessed): `bin/llmctl enable <profile>` calls
`systemctl --user enable <unit>`, which requires the systemd unit
*template* file (`llmctl-llama@.service` / `llmctl-colibri@.service`) to
already exist on disk. That template file is written **only** by
`bin/llmctl install` — it is *not* implied by `bin/llmctl setup`, and *not*
implied by `bin/llmctl enable` itself. On the diagnosing host, two
profiles were genuinely `active running` per `llmctl status` while
`systemctl --user list-units` reported `LOAD=not-found` for both (the
on-disk `~/.config/systemd/user/llmctl-llama@.service` file had gone
missing while systemd kept the already-loaded units running from a prior
install), and a live `systemctl --user enable
llmctl-llama@doesnotexist.service` failed immediately with `Unit ... does
not exist`. `scripts/install.sh` therefore **always** runs `bin/llmctl
install` once, unconditionally, before enabling any profile — this step
was not explicit in the original task description; it was found by
reading `lib/service_linux.sh` and reproducing the failure live.

## Prerequisites

* `bash` (`set -euo pipefail`).
* The rest of the llmctl repository at the expected relative layout
  (`../bin/llmctl` from this script's own directory) — it invokes the real
  `bin/llmctl` entrypoint as a subprocess, never reimplementing any of its
  logic.
* Whatever `bin/llmctl setup`'s own `doctor` step requires: `curl`, `git`,
  `python3` (required), and optionally `cmake`/`make`/a C compiler for
  engine builds (see `docs/scripts/doctor.md`).
* `loginctl` (Linux only) for the lingering-verification step (Step 5).
  Its absence — e.g. running on macOS, or a Linux host without systemd —
  degrades to an honest `SKIP`, never a `FAIL`.
* Network access for `bin/llmctl models download <profile>` unless every
  requested profile is already downloaded and verified.

## Usage examples

Install the default profile (`small`, the smallest baseline-tier profile)
end-to-end:

```bash
bash scripts/install.sh
```

Install one or more specific profiles (repeatable `--profile`):

```bash
bash scripts/install.sh --profile fast --profile vision
```

Skip the `llmctl setup` step (engines already built) and only
install/enable profiles:

```bash
bash scripts/install.sh --skip-setup --profile coder
```

Dry-run the entire sequence (no real build/download/systemd/loginctl
side-effects — forwards `LLMCTL_DRY_RUN=1` to every underlying `llmctl`
call):

```bash
bash scripts/install.sh --dry-run --profile fast
```

Help:

```bash
bash scripts/install.sh --help
```

## What it does, step by step

1. **`llmctl setup`** — doctor checks, engine build, hardware plan.
   Skippable with `--skip-setup`. (Itself safe/idempotent to re-run —
   `cmake --build` and `make` are both incrementally idempotent on an
   already-built tree, and `engine_ensure_submodules` only initializes
   submodules that are missing — so `--skip-setup` is a convenience, not a
   correctness requirement.)
2. **`llmctl models download <profile>`**, once per requested profile —
   resumable, checksum-verified, and idempotent: a profile already present
   with a matching sha256 is skipped (`lib/download.sh` logs "already
   present and verified ... (skipped)").
3. **`llmctl install`** — writes the systemd `--user` unit templates on
   Linux (or prepares the `LaunchAgents` directory on macOS), and, on
   Linux, attempts `loginctl enable-linger` for the invoking user
   internally. Always runs, unconditionally, exactly once per invocation
   of this script, regardless of `--skip-setup` — see "Overview" above for
   why this step cannot be skipped or assumed.
4. **`llmctl enable <profile>`**, once per requested profile — writes the
   profile's environment file, then `systemctl --user enable` **and**
   `start`s the unit in the same call (confirmed by reading
   `lib/scheduler.sh`'s `_enable_impl` → `lib/service_linux.sh`'s
   `svc_enable`). This script therefore does **not** make a separate
   `llmctl start <profile>` call afterward — it would be redundant.
5. **Verify lingering** — runs the real (non-dry-run)
   `loginctl show-user <user> -p Linger` and requires the exact literal
   output `Linger=yes`. `llmctl install`'s own internal
   `loginctl enable-linger` attempt only *warns* on failure rather than
   aborting (see `lib/service_linux.sh`), so it can silently fail to take
   effect (e.g. a missing polkit/D-Bus permission) while every prior step
   still reports success. This script never assumes success here — it
   checks. On a host with no `loginctl` at all (macOS, or a non-systemd
   Linux host), this step is an honest `SKIP`, not a `FAIL`. On
   `--dry-run`, this step is also skipped (nothing real to verify).
6. **`llmctl status`** — prints the final state of every profile so the
   operator can see exactly what's running and enabled.

## Idempotency / already-partially-installed hosts

Every step above is safe to re-run:

* `llmctl setup` — incrementally idempotent build tooling (see above).
* `llmctl models download` — skips re-download when the file is already
  present with a matching checksum.
* `llmctl install` — (re)writes the same static unit template content;
  writing it again is a no-op in effect. (Its `daemon-reload`/
  `loginctl enable-linger` calls are also side-effect-free to repeat.)
* `llmctl enable` — enabling/starting an already-enabled, already-running
  profile is a no-op at the systemd layer; `_enable_impl`'s own
  overcommit-safety check specifically special-cases an
  already-`sched_is_running` profile so re-enabling it never double-counts
  its RAM/VRAM reservation.

Running `scripts/install.sh` a second time with the same `--profile`
arguments (or a superset — new profiles added, previously-installed ones
simply left out of the new invocation) is therefore safe and produces the
same end state.

## Edge cases

* **No `--profile` given at all**: defaults to `small` — the smallest
  baseline-tier profile in `models/catalog.json`, chosen so a first-time
  run never has to guess a host-appropriate profile.
* **`--profile` given with no following argument**, or an **unrecognized
  flag**: usage is printed to stderr and the script exits `2` (a usage
  error, distinct from a runtime failure).
* **Insufficient host RAM/VRAM budget for a requested profile**: `llmctl
  enable <profile>` itself refuses (naming the exact shortfall, per
  `_enable_impl`'s 2026-09-17 overcommit-safety check) — this script does
  not swallow that failure; under `set -euo pipefail` it propagates as the
  script's own non-zero exit code, and no later step (including the
  lingering check and final status) runs. Reproduced live on the
  diagnosing host: with `small`/`vision`/`vision-pro` already reserving
  the host's GPU/RAM, `bash scripts/install.sh --dry-run --profile fast`
  correctly failed at the `enable` step with `cannot enable 'fast': needs
  2048 MiB RAM + 5716 MiB VRAM, but only ... remain within the host
  budget`.
* **Lingering not genuinely confirmed active** (e.g. `llmctl install`'s
  internal `loginctl enable-linger` attempt silently failed): the script
  reports an explicit `FAIL` and the exact remediation command
  (`sudo loginctl enable-linger <user>`) — **never** attempts privilege
  escalation itself — and exits `1`. Step 6 (`llmctl status`) does not run
  in this case.
* **`loginctl` absent** (macOS, or a Linux host without systemd): Step 5
  is an honest `SKIP`, never a `FAIL` — the tool being unavailable is not
  itself evidence that lingering is misconfigured.
* **`--dry-run`**: every underlying `llmctl` call runs with
  `LLMCTL_DRY_RUN=1` forwarded (so no real build/download/systemd/plist
  side-effect occurs), and Step 5's lingering check is itself skipped
  (there is nothing real to verify against). Every other step's *own*
  sequencing logic (argument parsing, which profiles are targeted, step
  ordering) still runs for real.

## Internal behaviour

1. `set -euo pipefail`; resolves its own repository root via
   `_install_root` (identical `cd "$(dirname ...)/.."` pattern to
   `scripts/release/create_release.sh`'s `_release_root`).
2. Parses `--profile <name>` (repeatable, appended to an array),
   `--dry-run`, `--skip-setup`, `-h`/`--help`. Unknown arguments or a
   trailing `--profile` with no value exit `2` with usage printed to
   stderr.
3. Defaults `profiles=(small)` when the array is empty after parsing.
4. `--dry-run` exports `LLMCTL_DRY_RUN=1` into this process's own
   environment (inherited by every subsequent `llmctl` subprocess call).
5. Step 1: `llmctl setup` (or an honest `SKIP` line under `--skip-setup`).
6. Step 2: `llmctl models download <profile>` per requested profile, in
   the order given (or catalog/default order for the implicit `small`).
7. Step 3: `llmctl install`, unconditionally, once.
8. Step 4: `llmctl enable <profile>` per requested profile.
9. Step 5: on `--dry-run`, prints the would-run `loginctl` command and
   moves on; otherwise, if `loginctl` is absent, prints an honest `SKIP`;
   otherwise runs `install_linger_ok` (a real, non-dry-run
   `loginctl show-user <user> -p Linger` parsed for the exact literal
   `Linger=yes`) and either prints `PASS` or prints a `FAIL` plus the
   `sudo loginctl enable-linger <user>` remediation instruction and
   returns `1` (skipping Step 6 entirely, via early `return`).
10. Step 6: `llmctl status`.
11. Prints a final `install complete: <profiles>` summary line.
12. Follows `scripts/release/create_release.sh`'s own
    "source-or-run" convention: functions are defined unconditionally,
    and `install_main "$@"` only runs when the file is executed directly
    (`"${BASH_SOURCE[0]}" == "${0}"`), so `tests/test_install_script_e2e.sh`
    can `source` it for unit-level testing of individual functions if
    ever needed, while normal usage just runs `bash scripts/install.sh`.

## Related scripts

* Invokes the real `bin/llmctl` entrypoint as a subprocess for every
  `setup`/`models download`/`install`/`enable`/`status` call — never
  reimplements any of that logic. See `docs/scripts/llmctl.md`.
* Modeled on `scripts/release/create_release.sh`'s shape: labeled steps,
  a `--dry-run` flag, source-or-run entrypoint pattern.
* `lib/service_linux.sh` — `svc_install` (unit templates +
  `loginctl enable-linger`) and `svc_enable` (enable + start in one call);
  read, not modified, by this change.
* `lib/scheduler.sh` — `_enable_impl` (dispatched by `bin/llmctl enable`);
  read-only in this change — a separate, concurrent change to this file
  (making the bind host configurable) was in flight in the same session
  and was deliberately left untouched.
* `tests/test_install_script_e2e.sh` — RED/GREEN proof: a hermetic fake
  `bin/llmctl` (argv-recording stub) plus a hermetic fake `loginctl`
  (following the `PATH`-stubbing idiom already established by
  `tests/test_scheduler_reboot_reconciliation.sh`) prove the exact
  invocation sequence and order, both the linger-confirmed and
  linger-not-confirmed branches, `--dry-run`'s `LLMCTL_DRY_RUN=1`
  propagation, `--skip-setup`, and both usage-error exit codes — without
  ever touching a real engine build, model download, or systemd unit.
* Discovered and run automatically by `tests/run_tests.sh`. Note:
  `tests/test_syntax.sh`'s own script glob currently enumerates
  `scripts/release/*.sh` explicitly, not the top-level `scripts/`
  directory this file lives in directly, so it does not cover
  `scripts/install.sh`; `tests/test_install_script_e2e.sh` independently
  asserts `bash -n scripts/install.sh` (and every real invocation in its
  suite runs the actual script as a real subprocess, which would itself
  fail loudly on a syntax error).

## Last verified date

2026-09-22
