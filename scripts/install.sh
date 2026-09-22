#!/usr/bin/env bash
# install.sh - one-command bootstrap for llmctl: fresh clone -> desired
# model profile(s) downloaded, enabled, running, and surviving reboot/logout
# via a persistent OS-native service (systemd --user on Linux, launchd on
# macOS).
#
# Purpose:
#   Closes a real gap: llmctl already has full systemd --user integration
#   (`bin/llmctl setup`, `models download`, `install`, `enable` - the last
#   of which already calls `loginctl enable-linger` internally, per
#   lib/service_linux.sh) and it has already been proven working
#   end-to-end on a real host (two profiles survived a real reboot this
#   session, confirmed via `systemctl --user list-units`, real listening
#   sockets, real GPU memory usage, and unchanged service start
#   timestamps). But there was no SINGLE command a brand-new user (or a
#   fresh redeploy) could run to go from "bare git clone" to "the desired
#   profile(s) are downloaded, enabled, running, and will survive the next
#   reboot" - that previously required manually chaining
#   `llmctl setup` -> `llmctl models download <profile>` ->
#   `llmctl install` -> `llmctl enable <profile>` and implicitly trusting
#   that lingering got set (with no explicit confirmation). This script is
#   that single command.
#
# A real, root-caused, load-bearing discovery from writing this script
# (verified live on a real host, 2026-09-22 - not guessed, per this
# project's own root-cause-first governance): `bin/llmctl enable <profile>`
# calls `systemctl --user enable <unit>` (lib/service_linux.sh's
# svc_enable), which requires the systemd unit TEMPLATE file
# (llmctl-llama@.service / llmctl-colibri@.service) to already exist on
# disk. That template is written ONLY by `bin/llmctl install`
# (lib/service_linux.sh's svc_install) - it is NOT implied by
# `bin/llmctl setup` and NOT implied by `bin/llmctl enable` itself. On a
# genuinely fresh clone (or a host whose ~/.config/systemd/user tree was
# ever cleaned/reset while units stayed loaded in systemd's own runtime
# memory - independently reproduced on the diagnosing host: two profiles
# were `active running` per `llmctl status` while `systemctl --user
# list-units` reported LOAD=not-found for both, and a live
# `systemctl --user enable llmctl-llama@doesnotexist.service` failed
# immediately with "Unit ... does not exist"), skipping `llmctl install`
# means every `llmctl enable <profile>` call in this script would fail.
# This script therefore ALWAYS runs `llmctl install` once, before enabling
# any profile - this was not explicit in the original task description and
# was discovered by reading lib/service_linux.sh + reproducing the failure
# live, not assumed.
#
# Usage:
#   bash scripts/install.sh [--profile <name>]... [--dry-run] [--skip-setup]
#   source scripts/install.sh   # for unit-testing the individual functions
#                                # (mirrors scripts/release/create_release.sh's
#                                # own source-or-run convention)
#
#   --profile <name>   a catalog profile (see `llmctl models list`) to
#                       download+enable+start. Repeatable. Default when
#                       omitted entirely: 'small' (the smallest
#                       baseline-tier profile in models/catalog.json) - a
#                       documented, sensible, low-resource default so a
#                       first-time run never has to guess.
#   --dry-run           forwards LLMCTL_DRY_RUN=1 to every `llmctl`
#                       invocation this script makes. Every real check this
#                       script performs itself (argument parsing, the
#                       systemd-unit-template gap explained above, its own
#                       step sequencing) still runs for real; only the
#                       underlying `llmctl` calls print what they would do.
#                       The lingering VERIFICATION step (Step 5) is also
#                       skipped in dry-run mode - dry-run never touches
#                       real systemd, so there is nothing real to verify.
#   --skip-setup        skip the `llmctl setup` step (doctor + engine build
#                       + hardware plan). Use when engines are already
#                       built (`llmctl setup` is itself safe/idempotent to
#                       re-run - cmake/make are incrementally idempotent -
#                       so this flag is a convenience, not a correctness
#                       requirement) and only profile install/enable is
#                       wanted.
#   -h, --help          print usage and exit 0.
#
# Inputs:
#   Positional/flag arguments above. No required environment variables;
#   every `LLMCTL_*` override `bin/llmctl` itself understands (see
#   `bin/llmctl help`) is honored transparently since this script always
#   invokes the real `bin/llmctl` entrypoint as a subprocess.
#
# Outputs:
#   Real per-step evidence on stdout/stderr, one clearly labeled step at a
#   time (mirroring scripts/release/create_release.sh's own step-header
#   convention). Exit 0 iff every step succeeded, including the linger
#   verification (Step 5) unless --dry-run was given. Exit 1 on any real
#   step failure, including an unconfirmed linger state (with an explicit,
#   actionable `sudo loginctl enable-linger <user>` instruction printed -
#   this script NEVER attempts privilege escalation itself). Exit 2 on a
#   usage error (unknown flag, --profile with no argument).
#
# Side-effects (non-dry-run mode only):
#   Runs `bin/llmctl setup` (builds engines - can take minutes on a
#   genuinely fresh clone), `bin/llmctl models download <profile>`
#   (downloads model weights - can be gigabytes), `bin/llmctl install`
#   (writes systemd user unit templates / prepares the macOS LaunchAgents
#   dir, and enables `loginctl enable-linger` for the invoking user on
#   Linux - see lib/service_linux.sh), and `bin/llmctl enable <profile>`
#   per requested profile (writes an env file, `systemctl --user enable`
#   + `start`s the corresponding service - or the launchd equivalent on
#   macOS). NEVER runs `sudo` or any other privilege-escalating command.
#
# Dependencies: bash, plus whatever `bin/llmctl setup`'s own `doctor`
# step requires (curl, git, python3, and optionally cmake/make/a C
# compiler for engine builds). `loginctl` (Linux only) for the lingering
# verification step in Step 5 - its absence (e.g. running on macOS, or a
# Linux host without systemd) degrades to an honest SKIP, never a FAIL.
#
# Cross-references:
#   bin/llmctl                          - the real entrypoint this script
#                                          orchestrates, never reimplements
#   lib/service_linux.sh                - svc_install (writes unit
#                                          templates + calls
#                                          `loginctl enable-linger`) and
#                                          svc_enable (enable + start)
#   lib/scheduler.sh                    - _enable_impl (dispatched by
#                                          `bin/llmctl enable`), NOT edited
#                                          by this change
#   tests/test_install_script_e2e.sh    - RED/GREEN proof, hermetic
#                                          PATH-stubbed llmctl + loginctl
#   docs/scripts/install.md             - full companion documentation
#   scripts/release/create_release.sh   - the sibling top-level
#                                          orchestration script this file's
#                                          shape (source-or-run, --dry-run,
#                                          labeled steps) is modeled on
set -euo pipefail

_install_root() { cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd; }

_install_have_cmd() { command -v "$1" >/dev/null 2>&1; }

install_usage() {
  cat <<'EOF'
usage: scripts/install.sh [--profile <name>]... [--dry-run] [--skip-setup]

Bootstraps llmctl end-to-end: doctor+build (llmctl setup), download the
requested profile(s) (llmctl models download), install persistent service
templates (llmctl install - also enables systemd --user lingering on
Linux), enable+start each profile (llmctl enable, which starts it too),
verify lingering is genuinely confirmed active, and print final status
(llmctl status).

  --profile <name>   a catalog profile to install (see 'llmctl models
                      list'). Repeatable. Default: 'small' when no
                      --profile is given at all.
  --dry-run           forward LLMCTL_DRY_RUN=1 to every llmctl invocation;
                      command sequencing is exercised for real, nothing
                      real is built/downloaded/enabled/verified.
  --skip-setup        skip the 'llmctl setup' step (doctor+build+plan) -
                      use when engines are already built and you only
                      want to (re-)install/enable profiles. 'llmctl setup'
                      is itself safe to re-run (cmake/make are
                      incrementally idempotent), so this is a convenience,
                      not a correctness requirement.
  -h, --help          this help.
EOF
}

# install_linger_ok [user] - real (non-dry-run) confirmation that systemd
# --user lingering is genuinely active for <user> (default: the invoking
# user), by parsing the ACTUAL `loginctl show-user -p Linger` output -
# never assumed from `llmctl install`'s own internal (warn-only-on-failure,
# per lib/service_linux.sh) attempt to enable it. Returns 1 (and prints
# nothing itself - the caller decides how to report) when `loginctl` is
# absent, when the query fails, or when it reports anything other than the
# exact 'Linger=yes' line.
install_linger_ok() {
  local user="${1:-$(id -un)}"
  _install_have_cmd loginctl || return 1
  local out
  out="$(loginctl show-user "${user}" -p Linger 2>/dev/null)" || return 1
  [[ "${out}" == "Linger=yes" ]]
}

# _install_llmctl <root> <args...> - invoke the real bin/llmctl entrypoint
# as a subprocess (never reimplemented / never sourced) so every llmctl
# invocation this script makes is byte-identical to what an operator typing
# the command by hand would get, including LLMCTL_DRY_RUN and every other
# LLMCTL_* override already exported into this process's environment.
_install_llmctl() {
  local root="$1"; shift
  "${root}/bin/llmctl" "$@"
}

install_main() {
  local root; root="$(_install_root)"
  local -a profiles=()
  local dry_run=0 skip_setup=0

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --profile)
        [[ "$#" -ge 2 ]] || { echo "error: --profile requires an argument" >&2; return 2; }
        profiles+=("$2")
        shift 2
        ;;
      --dry-run)    dry_run=1; shift ;;
      --skip-setup) skip_setup=1; shift ;;
      -h|--help)    install_usage; return 0 ;;
      *)
        echo "error: unknown argument: $1" >&2
        install_usage >&2
        return 2
        ;;
    esac
  done

  [[ "${#profiles[@]}" -gt 0 ]] || profiles=(small)

  if [[ "${dry_run}" -eq 1 ]]; then
    export LLMCTL_DRY_RUN=1
  fi

  echo "=== Step 1: llmctl setup (doctor -> build engines -> hardware plan) ==="
  if [[ "${skip_setup}" -eq 1 ]]; then
    echo "SKIP: --skip-setup given"
  else
    _install_llmctl "${root}" setup
  fi

  local p
  for p in "${profiles[@]}"; do
    echo
    echo "=== Step 2: download profile '${p}' (idempotent - skips re-download when already present+verified) ==="
    _install_llmctl "${root}" models download "${p}"
  done

  echo
  echo "=== Step 3: llmctl install (writes systemd --user unit templates / prepares launchd dir; also attempts 'loginctl enable-linger' on Linux) ==="
  # See this file's header comment for the full, real, root-caused
  # discovery: 'llmctl enable' requires this step to have already written
  # the systemd unit TEMPLATE file at least once, on THIS host. It is not
  # implied by 'llmctl setup', so it is always run here, unconditionally,
  # before any 'enable' below - not merely when profiles change.
  _install_llmctl "${root}" install

  for p in "${profiles[@]}"; do
    echo
    echo "=== Step 4: enable + start '${p}' ==="
    # 'llmctl enable' already implies start - confirmed by reading
    # lib/scheduler.sh's _enable_impl (dispatched by sched_enable, called
    # from bin/llmctl's 'enable)' case), which calls svc_enable
    # (lib/service_linux.sh): svc_enable runs
    # `systemctl --user enable <unit>` THEN `systemctl --user start <unit>`
    # in the same call - a separate 'llmctl start <profile>' immediately
    # afterward would be redundant (systemctl start on an already-started
    # unit is itself idempotent, but there is no reason to make the
    # redundant call). lib/scheduler.sh is READ-ONLY in this change - a
    # concurrent change to it is in flight this same session - so this
    # script deliberately relies on it exactly as-is rather than adding a
    # second start call to "be safe".
    _install_llmctl "${root}" enable "${p}"
  done

  echo
  echo "=== Step 5: verify systemd --user lingering (reboot/logout survival) ==="
  if [[ "${dry_run}" -eq 1 ]]; then
    echo "[dry-run] would run: loginctl show-user \$(id -un) -p Linger"
  elif ! _install_have_cmd loginctl; then
    echo "SKIP: 'loginctl' not found on this host (not a systemd/Linux host, e.g. macOS - launchd handles reboot survival natively via 'llmctl install' on that platform; no user-linger concept applies)."
  else
    if install_linger_ok; then
      echo "PASS: linger is enabled for $(id -un) - the profile(s) enabled above will survive both logout and reboot."
    else
      {
        echo "FAIL: linger is NOT confirmed enabled for $(id -un)."
        echo "  'llmctl install' already attempts 'loginctl enable-linger' automatically"
        echo "  (lib/service_linux.sh), but that call only WARNS on failure rather than"
        echo "  aborting - it can silently fail to take effect (e.g. missing polkit/D-Bus"
        echo "  permission) while every step above still reports success."
        echo
        echo "  ACTION REQUIRED (never attempted automatically - privilege escalation is"
        echo "  never performed unattended by this script or by llmctl itself):"
        echo
        echo "      sudo loginctl enable-linger $(id -un)"
        echo
        echo "  Without confirmed lingering, the profile(s) enabled above will stop at the"
        echo "  next logout and will NOT restart automatically after a reboot."
      } >&2
      return 1
    fi
  fi

  echo
  echo "=== Step 6: final status ==="
  _install_llmctl "${root}" status

  echo
  echo "install complete: ${profiles[*]}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  install_main "$@"
fi
