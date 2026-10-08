## Overview

`tests/test_doctor_decide.sh` (T082, FR-032, T138) proves that `llmctl doctor` reports the decision-gateway prerequisites: the API key file (presence and mode, never the value), the certificate (expiry, SAN drift, key/cert match, via the real `llmctl-decide cert doctor`), the private venv, engine HTTPS support, the gateway port, the bind/firewall note and, per decision profile, the maturity of each question type. Measured with `scripts/doc_counts.sh --check doctor_decide`: **39 passing assertions** (no failures, no skips).

## Prerequisites

* `go` and `python3` (the suite prints `SKIP-SUITE` and exits 0 otherwise); `tests/helpers.sh`.
* The suite builds the real `llmctl-decide` binary and generates a real certificate; the llama-server is a tiny stub that only answers `--help`. A second wrapper (`stub-decide`) forces `cert doctor` failures and a fake `serve --status` pid; everything else is exec'd to the real binary.

## Usage

* Standalone: `bash tests/test_doctor_decide.sh`; also run by `make test`.
* Check the documented count: `bash scripts/doc_counts.sh --check doctor_decide`.

## What it proves

* Healthy key + cert: PASS lines for key present (mode 600), cert key match, expiry, no SAN drift, engine HTTPS, free port, loopback bind; the secret value never appears in the output.
* Key file modes 644/640/604/660 are FAIL; no key and empty keys (`LLMCTL_API_KEY=`, `''`, `""`) are WARN, never PASS.
* SAN drift, missing certificate, engine without `--ssl-key-file`, occupied port and a `0.0.0.0` bind (with a firewall note) are WARN.
* A failing or silent `cert doctor` is a FAIL (never skipped); a loose `leaf.key` stays a FAIL.
* A `--help` larger than the pipe buffer with an early match still PASSes (no SIGPIPE false-fail).
* A running gateway pid must listen on the configured port: another port is a WARN naming the port, the configured port is a PASS, a foreign listener on the configured port is not reported as the gateway (needs `ss`; otherwise an honest SKIP line).
* Venv absent is WARN, present is PASS. Maturity (T138): a fully measured fixture profile is PASS, experimental/unmeasured types are a WARN naming them.

## Control needle

The final section prints the maturity line for the real `models/catalog.json` and asserts a known profile (`decide-lev`) appears, proving the maturity instrument can see real data. The "never prints the key" and "no PASS for ..." checks are negative assertions backed by positive WARN/FAIL counterparts in the same section.

## What it does NOT prove

* No real inference or real llama-server behaviour; the engine is a stub.
* Firewall state is not inspected, only the note is asserted.
* The correctness of the maturity labels in the catalog (only how doctor renders them).

## Related

[doctor](doctor.md), [test_decide](test_decide.md), [test_apikey_lifecycle](test_apikey_lifecycle.md).
