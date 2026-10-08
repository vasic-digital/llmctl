# `test_scheduler_reboot_reconciliation.sh`

## Overview

Source: `tests/test_scheduler_reboot_reconciliation.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_scheduler_reboot_reconciliation.sh - RED-then-GREEN regression test for
the post-reboot state-desync defect (root-caused 2026-09-22, real repro on
a rebooted host, not guessed):

  sched_running() (lib/scheduler.sh) enumerated ONLY the ephemeral
  ${LLMCTL_RUNTIME_DIR}/*.run reservation-marker files. LLMCTL_RUNTIME_DIR
  defaults to ${XDG_RUNTIME_DIR}/llmctl - a tmpfs deliberately WIPED by
  systemd/PAM on every reboot - and *.run files are ONLY ever (re)written
  by this project's own code (_enable_impl / _sched_start_impl, via
  _sched_write_reservation), never by systemd itself. After a reboot,
  systemd correctly auto-restarts an already-`enabled` persistent service
  (WantedBy=default.target + user lingering) with NO llmctl invocation
  involved at all, so llmctl's own bookkeeping had ZERO record of it until
  `bin/llmctl` ran again for that exact profile: `llmctl status` reported
  "no llmctl services running" for services that were genuinely serving
  real traffic (independently confirmed on the diagnosing host via
  `systemctl --user list-units`, `ss -tlnp`, and `nvidia-smi`).

  This is not merely cosmetic. sched_reserved_field() - which
  _enable_impl's own 2026-09-17 overcommit-safety check reads to compute
  currently-reserved RAM/VRAM before allowing a NEW profile to enable -
  iterates the SAME *.run glob, so immediately after a reboot it silently
  reported ZERO reserved for a profile that was in fact consuming real
  host RAM/VRAM. A subsequent `llmctl enable <new-profile>` could pass
  that check and genuinely overcommit the host - the EXACT failure mode
  the 2026-09-17 fix exists to prevent, reintroduced via a different
  trigger (post-reboot state desync instead of the original
  unconditional-write bug that fix addressed).

Hermetic simulation (no real systemd is ever touched by this test): a fake
`systemctl` stands in on PATH for the real service backend so
svc_is_active()'s real (non-dry-run) systemctl branch can be exercised.
LLMCTL_DRY_RUN=1's own svc_is_active branch checks for the EXISTENCE of
the exact *.run file this scenario is missing (see service_linux.sh), so
it can NEVER exercise this code path - LLMCTL_DRY_RUN is therefore left
unset/0 here on purpose, and every other service-backend call this test's
code path could reach (svc_write_env) is pure filesystem I/O with no
systemctl invocation at all, so nothing here risks a real service action.
```

Run: `bash tests/test_scheduler_reboot_reconciliation.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh scheduler_reboot_reconciliation` (see [doc_counts](doc_counts.md)).
