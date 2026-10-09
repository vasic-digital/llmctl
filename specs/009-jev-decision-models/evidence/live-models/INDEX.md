# Live-model evidence index

Generated 2026-10-09 by reading each run's `golden-stats.txt` / `RESULT.txt` / `README` in this directory. Headline numbers are the golden set (132 original items; accuracy per type = noul / choice / score); `well-formed` counts originals only. "Tree provenance": **pinned** = the nezha-pinned snapshot (`nezha-pinned-provenance-2026-10-09`: HEAD c5301de + a recorded diff; it is a MID-DEVELOPMENT tree equal to no single commit, see the provenance caveats in those READMEs); **mid-dev** = a recorded base commit plus an uncommitted change; **unpinned** = no recorded tree identity. Validity: *valid* = completed and usable as evidence; *pre-fix* = ran before the thinking-mode/letter-logit fix; *incomplete*; *INVALID*.

Reading cautions: anton-vs-nezha comparisons are confounded (different host, engine/gateway builds, timeouts). The nezha-pinned letter-logit runs used `LLMCTL_DECIDE_TIMEOUT=300`, not the product default of 8 s; the only default-8 s run is `nezha-pinned-decide-pro-default8s-control-2026-10-09`. Runs predating G-160 count a gateway limit refusal (422 validation_failed over `max_options`) as a malformed answer, i.e. as wrong in every accuracy denominator.

| Directory | Host | Date | Tree provenance | Validity | Profile | Headline |
|---|---|---|---|---|---|---|
| `anton-decide-2b-thinkingfix-2026-10-08` | anton | 2026-10-08 | mid-dev (HEAD c5301de + uncommitted letter.go; unpinned) | INCOMPLETE (host hang) | decide-2b | golden 58/132 well-formed; not a result |
| `anton-decide-2b-thinkingfix-run2-2026-10-09` | anton | 2026-10-09 | mid-dev (HEAD c5301de + uncommitted letter.go/resolver.go; binary 0c16f65a...; unpinned) | valid (complete; letter-logit, thinking fix) | decide-2b | golden well-formed 128/132; noul 0.883, choice 0.732, score 0.290 |
| `anton-decide-pro-thinkingfix-2026-10-09` | anton | 2026-10-09 | mid-dev (same tree/binary as run2; unpinned) | valid (complete; malformed counted as wrong) | decide-pro | golden well-formed 112/132; noul 0.867, choice 0.659, score 0.645 |
| `anton-decide-thinkingfix-2026-10-09` | anton | 2026-10-09 | mid-dev (same; unpinned) | INCOMPLETE (smoke 1/3, full matrix not run) | decide | smoke 1/3 well-formed (422 readout_failed); no accuracy figure |
| `anton-decide-max-not-exercised-2026-10-09.md` | anton | 2026-10-09 | n/a | NOT EXERCISED (note only) | decide-max | none (expected peak > 10G cap) |
| `anton-runner` | anton | 2026-10-09 | n/a | script only (run_letter.sh) | - | none |
| `decide-julia` | anton | 2026-10-08 | unpinned (engine 1537a0a; llmctl tree commit not recorded) | valid (systemone-native) | decide-julia | golden well-formed 132/132; noul 0.550, choice 0.341, score 0.258 (none beats baseline) |
| `decide-kev-08b` | anton | 2026-10-08 | unpinned | valid (systemone-native) | decide-kev-08b | golden 132/132; noul 0.817, choice 0.878, score 0.290 |
| `decide-kev-4b` | anton | 2026-10-08 | unpinned | valid (systemone-native) | decide-kev-4b | golden 132/132; noul 0.950, choice 1.000, score 0.613 |
| `decide-kev-9b` | anton | 2026-10-08 | n/a | INCOMPLETE (RESULT.txt NOT-STARTED; no golden) | decide-kev-9b | none |
| `decide-laya` | anton | 2026-10-08 | unpinned | valid (systemone-native) | decide-laya | golden 132/132; noul 0.717, choice 0.805, score 0.323 |
| `decide-lev` | anton | 2026-10-08 | unpinned | valid (systemone-native) | decide-lev | golden 132/132; noul 0.967, choice 0.976, score 0.516 |
| `decide-nli` | anton | 2026-10-08 | unpinned | INVALID (golden 0/132: the gateway refused the pinned binary-head NLI model, see decide-nli-d06-rootcause) | decide-nli | golden 0/132 well-formed |
| `decide-nli-d06-rootcause` | anton | 2026-10-08 | n/a | analysis note (ROOT-CAUSE.md) | decide-nli | none |
| `decide-nli-main-79268f5-INVALID-gateway-miswired` | anton | 2026-10-08 | HEAD 79268f5 | INVALID (gateway never told engine address; 173 x 503) | decide-nli | golden 0/132 well-formed |
| `decide-nli-main-wiredfix` | anton | 2026-10-08 | HEAD c5301de + uncommitted harness wiring fix (binary ce3e39c0...) | valid (wired gateway) | decide-nli | golden 132/132; noul 0.533, choice 0.829, score 0.226 |
| `decide-tiny` | anton | 2026-10-08 | n/a | analysis note (ROOTCAUSE.md; profile mis-catalogued as letter-logit) | decide-tiny | none |
| `nezha-decide-2026-10-08` | nezha | 2026-10-08 | unpinned (uncommitted snapshot; commit UNCONFIRMED) | pre-fix (before thinking-mode fix) | decide | golden well-formed 0/132 |
| `nezha-decide-2b-2026-10-08` | nezha | 2026-10-08 | unpinned | pre-fix | decide-2b | golden 0/132 |
| `nezha-decide-kev-4b-2026-10-08` | nezha | 2026-10-08 | unpinned | valid (systemone-native) | decide-kev-4b | golden 132/132; noul 0.950, choice 1.000, score 0.613 |
| `nezha-decide-kev-9b-2026-10-08` | nezha | 2026-10-08 | unpinned | valid (systemone-native) | decide-kev-9b | golden 132/132; noul 0.967, choice 1.000, score 0.710 |
| `nezha-decide-lev-2026-10-08` | nezha | 2026-10-08 | unpinned | valid (systemone-native) | decide-lev | golden 132/132; noul 0.967, choice 0.976, score 0.516 |
| `nezha-decide-max-2026-10-08` | nezha | 2026-10-08 | unpinned | INCOMPLETE (copied mid-run; smoke failed pre-fix; no stats) | decide-max | none |
| `nezha-decide-pro-2026-10-08` | nezha | 2026-10-08 | unpinned | pre-fix (letter-logit before thinking fix) | decide-pro | golden 68/132; noul 0.567, choice 0.488, score 0.290 |
| `nezha-pinned-decide-2026-10-09` | nezha | 2026-10-09 | pinned snapshot (mid-dev; equals no commit; timeout 300 s) | valid run, bad model result (151 x 422 readout_failed) | decide | golden 13/132; noul 0.000, choice 0.220, score 0.129 |
| `nezha-pinned-decide-2b-2026-10-09` | nezha | 2026-10-09 | pinned snapshot (mid-dev; timeout 300 s) | valid (live PSI watchdog) | decide-2b | golden 128/132; noul 0.883, choice 0.732, score 0.290 |
| `nezha-pinned-decide-2b-run0-watchdog-died-2026-10-09` | nezha | 2026-10-09 | pinned snapshot (mid-dev; timeout 300 s) | superseded: PSI watchdog died after 40 s (no abort protection for most of run) | decide-2b | golden 128/132; same numbers as the valid 2b run |
| `nezha-pinned-decide-max-2026-10-09` | nezha | 2026-10-09 | pinned snapshot (mid-dev; timeout 300 s) | valid | decide-max | golden 128/132; noul 0.967, choice 0.878, score 0.806 |
| `nezha-pinned-decide-nli-2026-10-09` | nezha | 2026-10-09 | pinned snapshot (mid-dev; gateway default deadline) | valid | decide-nli | golden 132/132; noul 0.533, choice 0.829, score 0.226 |
| `nezha-pinned-decide-pro-2026-10-09` | nezha | 2026-10-09 | pinned snapshot (mid-dev; timeout 300 s) | valid (not representative of the 8 s default) | decide-pro | golden 131/132; noul 0.883, choice 0.951, score 0.645 |
| `nezha-pinned-decide-pro-default8s-control-2026-10-09` | nezha | 2026-10-09 | pinned snapshot (mid-dev; gateway default 8 s) | valid control (representative of the product default) | decide-pro | golden 98/132 (45 x 502 deadline_exceeded); noul 0.833, choice 0.634, score 0.387 |
| `nezha-pinned-provenance-2026-10-09` | nezha | 2026-10-09 | pinned snapshot data | provenance bundle (no result) | - | none |
| `nezha-pinned-smoke-decide-2b-2026-10-09` | nezha | 2026-10-09 | pinned snapshot (mid-dev) | smoke only (3/3) | decide-2b | smoke 3/3 well-formed, 3/3 correct |
| `sc001-run.txt` | - | - | - | loose capture file (not a run directory; not re-read for this index) | - | - |
| `t062-https-handshake.txt` | - | - | - | loose capture file (not a run directory; not re-read for this index) | - | - |
