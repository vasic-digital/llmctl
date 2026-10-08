## Overview

`tests/test_install_agents.sh` exercises `scripts/install_agents.sh` with a fake npm
(`tests/fixtures/agents/fake_npm.sh`) and a fake uv (`fake_uv.sh`) - no network: `--dry-run` writes nothing,
a real install creates the shims and one JSON record per agent, a second run is a no-op, `--check` reports
presence and the headless form, and a tampered registry integrity is refused (no shim written). An opt-in
real install runs with `LLMCTL_TEST_NETWORK=1`.

**101 passing** assertions (1 honest SKIP: the opt-in network install).

`--check` is exercised twice (G-081): scoped with `--only cn,cline,aider` to the three agents the test itself installed
(never "all seven installed" - opencode/pi/crush/claude are not installed by this script and are host facts), and for
the full seven-agent check on a controlled `PATH` of stub binaries: one agent absent -> rc 1 naming it (`crush
installed=no`), all seven present -> rc 0, so the full check still reports missing agents correctly on any host.

## Prerequisites

`bash`, `python3`, `openssl`, `base64`, `gzip`.

## Usage examples

```sh
bash tests/test_install_agents.sh
LLMCTL_TEST_NETWORK=1 bash tests/test_install_agents.sh    # also installs @continuedev/cli for real into a temp prefix
```

## Edge cases

* The empty-prefix `--check` case runs with `PATH=/usr/bin:/bin` so an agent installed on the host cannot
  mask the absence.
* Mutation check (run 2026-10-07): replacing the integrity comparison with `if false` makes three
  assertions fail (mismatch rc, message, shim absent).

## Internal behaviour

`HOME` is a temp directory; the fake npm derives the bin name from the package and publishes a file://
tarball whose sha512 it computes (or a wrong one with `FAKE_NPM_BAD_INTEGRITY=1`).

Round 3 adds (C2-02, C2-18): an unverifiable UNPINNED aider is refused unless `LLMCTL_AGENTS_ALLOW_UNVERIFIED=1` (then the
record says `integrity_source:"none"` / `(UNVERIFIED...)`); a PINNED aider with unreachable or unparseable PyPI exits 1 with no
shim, no record and no `uv` call, even with the opt-in; npm records carry `runtime_smoke:"version+help"`.
