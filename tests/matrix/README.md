# Client-by-call matrix harness (T055/T056, runner side)

* `run.py` - orchestrator: inventory x client x vantage, one evidence record per cell, `matrix.json`, completeness check, `--check RUNDIR` independent verification.
* `cases.py` - case table (one handler per `endpoint-inventory.tsv` row) and body/header validators.
* `clients/` - independent client processes (see `clients/README.md`): curl, python-urllib, python-requests, node (`node:https`), go (`net/http`), headless chromium (DevTools protocol), typesafe SDK python/js.
* `refserver/main.go` - stdlib-only HTTPS reference server (class `stand-in`), certificate generator (`gencerts`) and TLS probe (`probe`). Validates the HARNESS only.
* `negative_tls.py` - FR-070 negative transport suite, each case paired with a positive control.
* `transport.py` - slow client, per-source connection cap, engine-port refusal, plain-HTTP reset probes.

Run against the reference server: `python3 -B tests/matrix/run.py --run-dir RUNDIR` (add `--with-sdk` for the SDK adapters).
Run against the real gateway:

    LLMCTL_API_KEY=... python3 -B tests/matrix/run.py --base-url https://HOST:PORT --cacert CA.pem \
      --server-cert SERVER-CERT.pem --engine-port ENGINE_PORT --scenario-hook ./scenario-hook.sh \
      --class-override real-component --run-dir docs/qa/009-jev-decision-models/RUN-ID [--with-sdk] [--require-second]

Cases that need a backend condition (EP-008b, 016b, 020-023, 034, 046) are set up through `--scenario-hook CMD setup|teardown SCENARIO`
(scenarios: truncate_on, no_ready_instance, overloaded, draining, readout_failed, backend_failed, not_ready); without a hook they FAIL, never skip.
Tune `--body-cap --budget-chars --profile-max-options --conn-cap --slow-client-max-s` to the served profile.
The second network vantage is pending (`second-machine`: pending-vantage in `matrix.json`); `--require-second` turns that into a failure.
Verify a finished run: `python3 -B tests/matrix/run.py --check RUNDIR`.  Test: `bash tests/test_matrix_harness.sh`.
