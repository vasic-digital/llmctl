# `test_vantage.sh`

## Overview

Source: `tests/test_vantage.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_vantage.sh - REAL integration test of the second network location
(FR-064, FR-069, FR-073, FR-091, SC-013). Boots a REAL rootless container
through the Containers submodule (llmctl-decide vantage up; the tests never
run `podman run` by hand) and proves, from inside it:
  * its source address differs from the host loopback (selfcheck, echo server)
  * an HTTPS server on the host's non-loopback address is reachable and its
    certificate verifies with the right CA and FAILS with a wrong CA
  * a 127.0.0.1-only listener is NOT reachable while 0.0.0.0 is (FR-073)
  * `down` leaves no containers, networks or state (podman ps -a / network ls)
SKIPs, loudly and with the reason, ONLY when rootless podman cannot run
containers here. Never fakes a pass.
```

Run: `bash tests/test_vantage.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh vantage` (see [doc_counts](doc_counts.md)).
