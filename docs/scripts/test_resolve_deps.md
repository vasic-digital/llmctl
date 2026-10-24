# `test_resolve_deps.sh`

## Overview

Source: `tests/test_resolve_deps.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_resolve_deps.sh - proves lib/resolve_deps.sh (the ONE source of truth for locating the constitution,
containers and superspec dependencies; llmctl no longer vendors them as submodules) resolves in the
documented order and FAILS LOUDLY when nothing resolves.

Every case runs the REAL library against a throw-away fixture tree built under a mktemp dir (the library is
copied to <fixture>/<llmctl>/lib/ so its "where am I" logic is exercised for real). Nothing in the working
tree or in the real hub is touched.

Cases: 1 env override wins; 2 nested at <hub>/submodules/llmctl finds the hub constitution + flat siblings;
3 standalone root layout (<root>/constitution, <root>/submodules/<name>); 4 sibling directories;
5 ancestor walk (<ancestor>/submodules/<name>; case 15: bounded - a decoy under .cache / above LLMCTL_RESOLVE_STOP_AT / above HOME is ignored); 6 host fallback (constitution only); 7 nothing resolves ->
non-zero + actionable message (negative control, never a silent pass); 8 a candidate that lacks the marker
file is rejected (no false positive on an empty dir); 9 an invalid env override is an error, not a fallthrough.
```

Run: `bash tests/test_resolve_deps.sh`.
