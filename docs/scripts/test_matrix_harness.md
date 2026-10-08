# `test_matrix_harness.sh`

## Overview

Source: `tests/test_matrix_harness.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_matrix_harness.sh - end-to-end test of the client-by-call matrix HARNESS (T055/T056, runner side).

Drives tests/matrix/run.py against the self-contained reference HTTPS server (class stand-in: this
proves the HARNESS and every CLIENT adapter work; it is NOT evidence about the decision gateway).
Asserts: matrix completeness (every inventory row x every available client), evidence chain +
manifest + leak scan (with control needle), the negative TLS suite, and three mutations:
  M1 a deliberately broken client adapter makes the run FAIL,
  M2 removing a case from an inventory copy is detected,
  M3 tampering with a finished run is detected by `run.py --check`.
Set MATRIX_WITH_SDK=1 to also run the typesafe SDK adapters (needs network + uv + npm).
Bytecode is never written; every temp directory is removed.
```

Run: `bash tests/test_matrix_harness.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh matrix_harness` (see [doc_counts](doc_counts.md)).
