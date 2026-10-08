# `test_install_script_e2e.sh`

## Overview

Source: `tests/test_install_script_e2e.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_install_script_e2e.sh - RED/GREEN proof for scripts/install.sh, the
one-command bootstrap that closes the gap identified in this session:
llmctl already has full systemd --user integration (setup/download/
install/enable, the last of which already calls `loginctl enable-linger`
internally per lib/service_linux.sh) and it is already proven working
end-to-end on a real host, but there was no SINGLE command chaining
setup -> download -> install -> enable -> linger-verification -> status
for a brand-new user or a fresh redeploy.

This test proves scripts/install.sh invokes the real `bin/llmctl`
subcommand chain in the RIGHT ORDER - setup, models download, install,
enable, status - and correctly detects+reports BOTH the linger-confirmed
happy path AND the linger-NOT-confirmed failure path, entirely
hermetically: a fake `llmctl` (a thin argv-recording stub, mirroring
this suite's fake-systemctl idiom in test_scheduler_reboot_
reconciliation.sh) stands in on PATH-equivalent (via LLMCTL_BIN
override... no such override exists, so instead a fake bin/llmctl is
assembled inside a synthetic root and scripts/install.sh's own
`_install_root`-relative invocation is exercised against it) so no real
engine build, model download, or systemd unit is ever touched, and a
fake `loginctl` stands in on PATH so both the Linger=yes and Linger=no
branches are exercised without depending on this host's real linger
state (which the real-host verification report covers separately).
```

Run: `bash tests/test_install_script_e2e.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh install_script_e2e` (see [doc_counts](doc_counts.md)).
