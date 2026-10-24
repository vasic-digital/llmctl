# Class-sweep follow-ups (llmctl, 3.3.0)

Source: the root-cause class sweep of 2026-10-22. Everything the sweep found in llmctl was re-grepped over the WHOLE tracked tree (not the sweep's
file list) with a control-needled instrument, fixed test-first where it was a defect, and pinned by a guard test. What is left is listed here with
its reason; nothing is deferred silently.

| Class | Guard test (control needle inside) | Fixed in 3.3.0 | Genuinely deferred / justified |
|---|---|---|---|
| second `trap ... EXIT` replaces the first | `tests/test_no_trap_replacement.sh` (RED on 2 files) | `tests/test_decide_download.sh` (HTTP_PID), `tests/test_download_resume.sh` (RANGE_PID) | none |
| secret on a command line | `tests/test_no_secret_on_argv.sh` (RED 22 hits, then 0) | 5 tests use `auth_hdr_file` (`-H @file`); 6 evidence scripts use a 0600 header file; both `sys1.py` helpers read the key from a file | literal junk values (`nope`, `wrong`, `test-secret-key`) are not secrets and stay; `python-gateway-retired/` (archived, literals only) and `tests/test_docs_no_literal_keys.sh` (plants violating doc text on purpose) are excluded from the scan; `specs/.../sc004-verify/mutate.py:21` is a source-mutation string, not an executed command |
| bearer temp file survives a signal | `tests/test_cluster_header_signal.sh` (RED: token file left after SIGTERM) | `lib/cluster.sh` passes the header as `-H @/dev/fd/3` (process substitution): nothing on disk | none |
| TLS verification off | `tests/test_tls_off_allowlist.sh` | every site is justified in place: Go `InsecureSkipVerify: true` only with a `VerifyPeerCertificate` callback (8 sites, custom CA-pinned verification); `curl -k` in `evidence/engine-advance/raw/t_more.sh` carries `TLS-OFF-OK:` (loopback, throw-away certificate, recorded evidence) | rewriting that recorded evidence script to verify against its own certificate is not done: it cannot be re-run without the model host, so a change would be unverified |
| Authorization forwarded across redirects (urllib) | `tests/test_no_auth_redirect_forwarding.sh` | `scripts/golden/run_golden.py` never follows a redirect; `evidence/pin_reverify.py` strips the token when a redirect leaves the host (unit-checked: cross-host dropped, same-host kept) | 7 loopback-only recorded evidence/test helpers carry `REDIRECT-OK:` (no redirect target exists in the fixture) |
| `tests/test_decide_service.sh` red on the pristine tree | the test itself | stale assertion: the product changed `KeepAlive` to `{SuccessfulExit: false}` in e0e7423 and the test still said `is True`; the test now pins the intended value | none |

Not claimed: that no other secret-on-argv form exists. The instrument matches curl `-H Authorization/x-api-key` with `$` in the value and the `sys1.py` key argument; a new form needs a new pattern in `tests/test_no_secret_on_argv.sh`.

## Class: children of a test inherit the host-lock fd (2026-10-22)

Incident: the shared host lock (`flock <lockfile> cmd`) stayed held for hours after the suite that took it was gone. Holders were (1) orphaned `flock -x N`
waiters of `scheduler::with_lock` (no timeout, blocked on a `.scheduler.lock` in a deleted state dir) and (2) orphaned python `http.server` fixtures,
all carrying the lock's open file description inherited from the wrapper.

| Fix | Where |
|---|---|
| inherited regular-file fds >= 3 (not 255) are closed when a suite sources the helpers, so no fixture/waiter it starts can inherit the lock | `tests/helpers.sh` `close_inherited_lock_fds`; same loop at the top of `tests/run_tests.sh` |
| `scheduler::with_lock` waits at most `LLMCTL_SCHED_LOCK_WAIT` (default 900 s), then closes its fd and returns 2 | `lib/scheduler.sh` |
| the one unbounded test waiter (`flock 8` in `test_validate_interrupt.sh`) is bounded (`-w 60`) | `tests/test_validate_interrupt.sh` |
| `test_bg_register <pid>`: teardown kills exactly the recorded pids | `tests/helpers.sh` (opt-in; no new `trap`, see `test_no_trap_replacement.sh`) |
| guard: drives the real helpers under a throw-away lock, asserts no `/proc/*/fd` link to it afterwards, the lock is acquirable, the waiter gave up; control needles inside; `LLMCTL_FDLEAK_TREE=<tree>` runs it against another tree (RED proof) | `tests/test_no_lock_fd_leak.sh` |

Not done / not claimed: the spawn sites (about 14 suites start `http.server` fixtures) were NOT edited one by one; they are covered centrally because every one sources `tests/helpers.sh`. `tests/livetest_fake_lib.sh`, `tests/test_livetest_watchdog.sh` and `tests/test_livetest_runner.sh` do not source it (their only waiters are `flock <file> sleep N` holders, bounded by the sleep), so a fixture server they start would still inherit an fd if run under a lock. Children of `scheduler::with_lock`'s own command still inherit the scheduler lock fd by design (unchanged, not verified safe to close).
