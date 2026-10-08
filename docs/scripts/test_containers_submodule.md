# `test_containers_submodule.sh`

## Overview

Source: `tests/test_containers_submodule.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_containers_submodule.sh - T069 / FR-091 / Helix §11.4.76: the Containers submodule is the
one implementation of port allocation, service registry and health probing. Asserts:
  1. submodules/containers is checked out at the commit recorded in helix-deps.yaml (and in the index)
  2. go.mod requires digital.vasic.containers and replaces it with ./submodules/containers
  3. internal/registry really depends on the submodule packages it claims to use
  4. a grep gate finds no own port-allocator / registry reimplementation markers in internal/ and cmd/
     (the gate is itself validated against a golden-bad and a golden-good fixture tree)
```

Run: `bash tests/test_containers_submodule.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh containers_submodule` (see [doc_counts](doc_counts.md)).
