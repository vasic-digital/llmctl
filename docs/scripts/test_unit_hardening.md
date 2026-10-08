## Overview

`tests/test_unit_hardening.sh` proves against the **live** `systemd --user`
manager that every hardening directive llmctl writes (`_svc_hardening` in
`lib/service_linux.sh`) takes effect, by starting a transient service with
exactly that property and observing the effect from inside it
(`NoNewPrivs: 1`, a refused write under `/usr`, the process umask,
`EAFNOSUPPORT` for `AF_NETLINK`, a seccomp filter where a control service has
none). It also probes the directives llmctl deliberately does **not** write
(`PrivateTmp`, `ProtectHome`, `ProtectControlGroups`, `ProtectProc`,
`PrivateDevices`, `ProtectClock`, `CapabilityBoundingSet`) and prints a table of which of
them THIS systemd honours (G-083). That table is an informational **host fact** (it depends on the
systemd version: the nezha.local run on systemd 258 saw 5 of them honoured, the development host's systemd 259 user manager honours none of the seven) and is never
pass/fail; set `LLMCTL_HOST_FACTS_FILE=<path>` to also save it (`directive|honoured|not-honoured|refused|detail`).
Only "every directive llmctl WRITES takes effect" is a hard assertion. Transient units get exact names
`llmctl-hardening-probe-<pid>-<n>`, are started with `--collect`, and the EXIT trap stops + reset-fails exactly
those names (G-088), so refused probes leave no failed unit behind. Prints
SKIP (never PASS) when no user manager is reachable. Two marker files are
created by exact name and removed on exit.
