# `test_macos_plist.sh`

## Overview

File-level proof of the launchd plists `lib/service_macos.sh` writes (C2-04). No Mac was available, so: the engine and
gateway plists are parsed with python `plistlib` (plutil is absent on Linux), their `EnvironmentVariables` keys are
compared, and the `svc_hook.sh run-engine` wrapper named in `ProgramArguments` is executed under `env -i` with only the
plist's environment - once without it (control: the key is NOT rotated, the reported failure mode) and once with it
(the key file is rotated and the hook log lands in the overridden log dir). Run: `bash tests/test_macos_plist.sh`.

**13 passing** assertions.

## Not proven

That launchd itself loads and runs the plist (needs macOS). Tracked in the fix report.
