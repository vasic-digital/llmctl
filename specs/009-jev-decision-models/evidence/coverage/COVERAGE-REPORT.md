# llmctl code-coverage report

| Field | Value |
|---|---|
| Generated (UTC) | 2026-10-08T10:54:29Z |
| Producer | `scripts/coverage/report.sh` (+ `make_report.py`), run took 1591s |
| Policy | Constitution 11.4.224; operator decision OD-15: **measure and report only, no gate** |
| Floor | 85% is a MINIMUM ON A PROXY (11.4.224(B)/(C)); a number here never proves the code correct |

## Headline numbers

| language | measured coverage |
|---|---|
| go | 84.3% (11208/13294 statements, root + llmctld unit packages) |
| bash | 71.5% (2311/3230 lines, 22 measured files; 1 files NOT measured) |
| python | 65.8% (1371/2083 statements) |

## Go (statement coverage, `go test -coverprofile`)

### llmctld module (unit packages; `test/integration` NOT run) - total 65.4% (1973/3019 statements)

| package | coverage | covered/stmts |
|---|---|---|
| llmctld/cmd/llmctld | 7.3% | 32/440 |
| llmctld/internal/api | 55.8% | 546/979 |
| llmctld/internal/audit | 97.6% | 41/42 |
| llmctld/internal/auth | 86.9% | 106/122 |
| llmctld/internal/authz | 100.0% | 31/31 |
| llmctld/internal/cluster | 92.9% | 210/226 |
| llmctld/internal/executor | 93.7% | 74/79 |
| llmctld/internal/isolation | 84.4% | 27/32 |
| llmctld/internal/mtls | 84.9% | 163/192 |
| llmctld/internal/raft | 76.3% | 274/359 |
| llmctld/internal/replication | 88.4% | 344/389 |
| llmctld/internal/tenancy | 97.7% | 125/128 |

Files below 85% (llmctld):

| file | coverage | covered/stmts |
|---|---|---|
| llmctld/cmd/llmctld/cli_certs.go | 30.3% | 23/76 |
| llmctld/cmd/llmctld/hardware_probe.go | 0.0% | 0/11 |
| llmctld/cmd/llmctld/main.go | 2.5% | 9/353 |
| llmctld/internal/api/client.go | 39.6% | 53/134 |
| llmctld/internal/api/middleware_auth.go | 60.0% | 3/5 |
| llmctld/internal/api/routes_auth.go | 77.4% | 41/53 |
| llmctld/internal/api/routes_cluster.go | 40.8% | 20/49 |
| llmctld/internal/api/routes_models.go | 36.4% | 79/217 |
| llmctld/internal/api/routes_mtls.go | 52.2% | 129/247 |
| llmctld/internal/api/routes_replication.go | 77.2% | 88/114 |
| llmctld/internal/api/routes_tenants.go | 79.8% | 79/99 |
| llmctld/internal/api/server.go | 82.6% | 19/23 |
| llmctld/internal/auth/jwt.go | 84.6% | 11/13 |
| llmctld/internal/auth/oidc.go | 80.0% | 32/40 |
| llmctld/internal/isolation/cgroup.go | 84.4% | 27/32 |
| llmctld/internal/mtls/certs.go | 73.1% | 49/67 |
| llmctld/internal/mtls/truststore.go | 79.6% | 39/49 |
| llmctld/internal/raft/lock.go | 69.7% | 23/33 |
| llmctld/internal/raft/node.go | 62.7% | 74/118 |
| llmctld/internal/raft/replication_commands.go | 71.4% | 10/14 |
| llmctld/internal/raft/running_profile.go | 80.0% | 12/15 |
| llmctld/internal/replication/checkpoint.go | 84.2% | 64/76 |
| llmctld/internal/replication/crypto.go | 75.0% | 18/24 |

Largest uncovered functions (llmctld) - follow-up candidates, no tests written now:

| file | function | uncovered stmts | func coverage |
|---|---|---|---|
| llmctld/cmd/llmctld/main.go | runClusterJoinReal | 109 | 0% |
| llmctld/cmd/llmctld/main.go | runClusterBootstrap | 95 | 0% |
| llmctld/internal/api/routes_mtls.go | RegisterMTLSRoutes | 77 | 57% |
| llmctld/cmd/llmctld/main.go | wireHealthMonitor | 58 | 0% |
| llmctld/internal/api/routes_models.go | dispatchNameOnlyStop | 32 | 0% |
| llmctld/cmd/llmctld/cli_certs.go | runClusterIssueCLICert | 28 | 0% |
| llmctld/internal/api/routes_models.go | dispatchAutoPlacedStart | 27 | 46% |
| llmctld/internal/api/client.go | ForwardModelStatus | 25 | 0% |
| llmctld/internal/api/routes_tenants.go | RegisterTenantRoutes | 20 | 79% |
| llmctld/internal/api/client.go | ForwardNameOnlyStop | 20 | 0% |
| llmctld/internal/api/client.go | ForwardAutoPlaceStart | 20 | 0% |
| llmctld/internal/api/routes_models.go | dispatchNameOnlyStatus | 19 | 0% |
| llmctld/internal/api/routes_models.go | RegisterModelRoutes | 18 | 63% |
| llmctld/cmd/llmctld/main.go | parseClusterFlags | 18 | 0% |
| llmctld/internal/api/routes_mtls.go | ForwardCARotationTransition | 17 | 0% |

### root module (`github.com/vasic-digital/llmctl`) - total 89.9% (9235/10275 statements)

| package | coverage | covered/stmts |
|---|---|---|
| cmd/llmctl-decide | 86.7% | 1495/1724 |
| internal/audit | 90.5% | 201/222 |
| internal/calibrate | 91.6% | 492/537 |
| internal/certs | 88.2% | 837/949 |
| internal/client | 85.3% | 651/763 |
| internal/contract | 96.3% | 727/755 |
| internal/gateway | 90.1% | 1252/1390 |
| internal/keyring | 88.5% | 592/669 |
| internal/mcpserver | 93.1% | 176/189 |
| internal/metrics | 99.2% | 117/118 |
| internal/placement | 93.2% | 69/74 |
| internal/readout | 93.0% | 227/244 |
| internal/registry | 91.7% | 1022/1115 |
| internal/schema | 92.9% | 26/28 |
| internal/server | 94.2% | 736/781 |
| internal/vantage | 82.6% | 400/484 |
| internal/vantage/cmd/vantage-probe | 0.0% | 0/2 |
| internal/vantage/probecore | 93.1% | 215/231 |

Files below 85% (root):

| file | coverage | covered/stmts |
|---|---|---|
| cmd/llmctl-decide/cmd_key.go | 83.3% | 10/12 |
| cmd/llmctl-decide/cmd_serve.go | 67.8% | 244/360 |
| internal/audit/logkey.go | 80.7% | 46/57 |
| internal/calibrate/fromprofile.go | 83.9% | 47/56 |
| internal/calibrate/profile.go | 76.1% | 35/46 |
| internal/certs/ca.go | 84.4% | 130/154 |
| internal/certs/leaf.go | 71.7% | 71/99 |
| internal/certs/secfile.go | 81.7% | 76/93 |
| internal/client/errors.go | 76.5% | 39/51 |
| internal/client/permute.go | 81.0% | 188/232 |
| internal/client/probe.go | 80.6% | 112/139 |
| internal/gateway/proc.go | 82.5% | 141/171 |
| internal/gateway/tick.go | 0.0% | 0/1 |
| internal/keyring/export.go | 79.8% | 67/84 |
| internal/registry/inode_unix.go | 66.7% | 2/3 |
| internal/registry/lock.go | 83.3% | 15/18 |
| internal/registry/process.go | 75.4% | 43/57 |
| internal/vantage/cli.go | 80.0% | 96/120 |
| internal/vantage/cmd/vantage-probe/main.go | 0.0% | 0/2 |
| internal/vantage/probebin.go | 83.1% | 54/65 |
| internal/vantage/vantage.go | 82.9% | 214/258 |

Largest uncovered functions (root) - follow-up candidates, no tests written now:

| file | function | uncovered stmts | func coverage |
|---|---|---|---|
| cmd/llmctl-decide/cmd_serve.go | runDetached | 44 | 0% |
| internal/client/permute.go | mergePermuted | 30 | 78% |
| internal/vantage/cli.go | Run | 23 | 79% |
| internal/registry/cli.go | RunRegistry | 17 | 90% |
| internal/keyring/export.go | InstallExportBlock | 16 | 75% |
| internal/keyring/env.go | WriteEnvValues | 15 | 69% |
| internal/vantage/vantage.go | Up | 14 | 76% |
| internal/client/probe.go | ProbeOrder | 14 | 86% |
| cmd/llmctl-decide/cmd_serve.go | runForeground | 14 | 68% |
| internal/registry/registry.go | Reconcile | 13 | 85% |
| internal/registry/ports.go | save | 12 | 45% |
| cmd/llmctl-decide/cmd_serve.go | prepare | 12 | 85% |
| internal/certs/ca.go | makeCA | 11 | 77% |
| internal/certs/leaf.go | issueLeaf | 10 | 71% |
| internal/calibrate/profile.go | WriteProfile | 10 | 71% |

## Bash (LINE coverage via PS4 xtrace, zero tooling)

Total over measured files: **71.5% (2311/3230 executable lines)**.

| file | line coverage | covered/executable |
|---|---|---|
| bin/llmctl | 54.9% | 67/122 |
| lib/admit.sh | 95.6% | 65/68 |
| lib/catalog.sh | 78.9% | 60/76 |
| lib/cluster.sh | 96.1% | 73/76 |
| lib/common.sh | 75.4% | 43/57 |
| lib/decide.sh | 78.0% | 191/245 |
| lib/doctor.sh | 75.0% | 72/96 |
| lib/download.sh | 50.4% | 201/399 |
| lib/engine.sh | 38.1% | 67/176 |
| lib/hardware.sh | 37.8% | 87/230 |
| lib/os_detect.sh | 44.0% | 11/25 |
| lib/portreg.sh | 88.3% | 83/94 |
| lib/scheduler.sh | 89.2% | 452/507 |
| lib/service_linux.sh | 75.0% | 147/196 |
| lib/service_macos.sh | 64.7% | 88/136 |
| lib/svc_hook.sh | 39.6% | 38/96 |
| scripts/check_doc_reachability.sh | 91.1% | 51/56 |
| scripts/doc_counts.sh | 84.8% | 39/46 |
| scripts/install_agents.sh | 96.0% | 166/173 |
| scripts/release/build_archive.sh | 90.9% | 180/198 |
| scripts/release/create_release.sh | 87.1% | 88/101 |
| scripts/release/preflight_submodules.sh | 73.7% | 42/57 |

Classifier self-check: 22 of 2406 distinct traced (file,line) records fell on lines the heuristic calls non-executable and were not credited to a statement start (0.91%; 0 = the executable-line heuristic never disagreed with what bash actually traced).

### Files NOT measured (no included suite executed a single line of them)

| file | executable lines |
|---|---|
| scripts/install.sh | 73 |

These are exercised only by the suites listed as EXCLUDED/NOT-RUN below (podman, systemd service, GPU, engine-build and Go-mutation suites). Reporting them as 0% would be as false as reporting 100%: they are unmeasured.

### Largest uncovered bash functions (follow-up candidates)

| file | function | uncovered lines | covered/executable |
|---|---|---|---|
| lib/hardware.sh | hw_probe_json | 61 | 24/85 |
| lib/download.sh | _dl_smoke_test_onnx | 54 | 0/54 |
| bin/llmctl | main | 48 | 38/86 |
| lib/download.sh | _dl_smoke_test_gguf | 47 | 5/52 |
| lib/engine.sh | engine_build_onnx | 28 | 0/28 |
| lib/hardware.sh | _probe_storage | 25 | 14/39 |
| lib/engine.sh | engine_venv_prepare | 23 | 0/23 |
| lib/hardware.sh | _probe_gpus | 22 | 17/39 |
| lib/doctor.sh | doctor_run | 21 | 59/80 |
| lib/decide.sh | decide_interactive | 18 | 80/98 |
| lib/download.sh | _dl_validate_colibri | 17 | 0/17 |
| lib/decide.sh | decide_status | 14 | 20/34 |
| lib/svc_hook.sh | _hk_wait_register | 13 | 0/13 |
| lib/service_linux.sh | svc_stale_units | 13 | 4/17 |
| lib/hardware.sh | _probe_mem | 13 | 9/22 |

### Suites run under the tracer

| suite | result / status | wall time | note / reason |
|---|---|---|---|
| test_admit.sh | rc=0 | 34s |  |
| test_agent_kit.sh | rc=0 | 31s |  |
| test_apikey_lifecycle.sh | rc=0 | 8s |  |
| test_archive_completeness.sh | rc=0 | 8s |  |
| test_bin_llmctl_symlink_invocation.sh | rc=1 | 1s |  |
| test_catalog_json.sh | rc=0 | 18s |  |
| test_certs_go_cli.sh | rc=0 | 5s |  |
| test_certs_go_mutation.sh | EXCLUDED | 0s | Go mutation suite (copies the tree, runs go test) |
| test_cli.sh | rc=0 | 66s |  |
| test_cluster_cli_args.sh | rc=0 | 0s |  |
| test_cluster_join_leave.sh | rc=0 | 9s |  |
| test_cluster_request_checked.sh | rc=0 | 0s |  |
| test_constitution_inheritance.sh | rc=0 | 1s |  |
| test_containers_submodule.sh | rc=0 | 1s |  |
| test_create_release.sh | rc=0 | 0s |  |
| test_ctx_kvtype_override.sh | rc=0 | 14s |  |
| test_decide_cli.sh | rc=0 | 47s |  |
| test_decide_download.sh | rc=0 | 47s |  |
| test_decide_security_mutation.sh | EXCLUDED | 0s | Go mutation suite (copies the tree, runs many go test builds) |
| test_decide_service.sh | rc=0 | 4s |  |
| test_decide.sh | rc=0 | 56s |  |
| test_decision_capacity.sh | rc=0 | 300s |  |
| test_determinism.sh | rc=0 | 2s |  |
| test_doc_reachability.sh | rc=0 | 20s |  |
| test_docs_no_literal_keys.sh | rc=0 | 1s |  |
| test_download_resume.sh | rc=0 | 9s |  |
| test_download.sh | rc=0 | 21s |  |
| test_dynamic_ports.sh | rc=0 | 141s |  |
| test_engine_build_decide.sh | EXCLUDED | 0s | builds engines / Go binaries (heavy) |
| test_engine_build_onnx.sh | EXCLUDED | 0s | builds/installs the ONNX engine (heavy) |
| test_engine_build_safety.sh | EXCLUDED | 0s | engine build safety (heavy build tooling) |
| test_engine_cpu_regression.sh | rc=0 | 36s |  |
| test_engine.sh | rc=0 | 0s |  |
| test_gate_hook_tmp.sh | rc=0 | 1s |  |
| test_gateway_endpoints.sh | rc=0 | 29s |  |
| test_gateway_mutation.sh | EXCLUDED | 0s | Go mutation suite (copies the tree, runs many go test builds) |
| test_go_unit.sh | EXCLUDED | 0s | Go suite, measured separately by the Go stage |
| test_gpu_throughput_ratio.sh | EXCLUDED | 0s | GPU suite (needs an NVIDIA GPU + llama-server) |
| test_gpu_vram_delta.sh | EXCLUDED | 0s | GPU suite (needs an NVIDIA GPU + llama-server) |
| test_hardware_probe.sh | rc=0 | 2s |  |
| test_install_agents.sh | rc=0 | 17s |  |
| test_install_script_e2e.sh | EXCLUDED | 0s | installs/enables real services + linger (systemd) |
| test_keyring_go_cli.sh | rc=0 | 3s |  |
| test_macos_plist.sh | rc=0 | 2s |  |
| test_matrix_harness.sh | rc=0 | 73s |  |
| test_mcp_stdio.sh | rc=0 | 13s |  |
| test_no_retired_vars.sh | rc=0 | 1s |  |
| test_normalize_agents.sh | rc=0 | 0s |  |
| test_normalize_common.sh | rc=0 | 1s |  |
| test_no_stray_binaries.sh | rc=0 | 15s |  |
| test_onnx_download.sh | rc=0 | 0s |  |
| test_onnx_runtime.sh | rc=0 | 1s |  |
| test_onnx_server.sh | rc=1 | 3s |  |
| test_planner.sh | rc=0 | 36s |  |
| test_port_override.sh | rc=0 | 58s |  |
| test_preflight_submodules.sh | rc=0 | 2s |  |
| test_py_unit.sh | EXCLUDED | 0s | Python suite, measured separately by the Python stage |
| test_registry_cli.sh | rc=0 | 10s |  |
| test_registry_discovery.sh | rc=0 | 83s |  |
| test_regression_defects.sh | rc=0 | 102s |  |
| test_release_no_secrets.sh | rc=0 | 17s |  |
| test_run_tests_format.sh | EXCLUDED | 0s | drives the whole run_tests.sh harness (recursion; would run the full suite) |
| test_scheduler_bind_host.sh | rc=0 | 21s |  |
| test_scheduler_lock.sh | rc=0 | 2s |  |
| test_scheduler_reboot_reconciliation.sh | EXCLUDED | 0s | systemd service suite (service reconciliation) |
| test_scheduler.sh | rc=0 | 187s |  |
| test_scheduler_switch_safety.sh | EXCLUDED | 0s | systemd service suite (service switch) |
| test_scheduler_wait_ready.sh | rc=0 | 5s |  |
| test_service_ops_hardening.sh | EXCLUDED | 0s | systemd service suite (real units) |
| test_services_crashloop.sh | EXCLUDED | 0s | systemd service suite |
| test_services.sh | EXCLUDED | 0s | systemd service suite |
| test_setup_e2e.sh | EXCLUDED | 0s | builds engines from source (multi-minute compile) |
| test_small_profile_full_context.sh | rc=0 | 0s |  |
| test_syntax.sh | rc=0 | 1s |  |
| test_systemd_cleanliness.sh | EXCLUDED | 0s | systemd service suite |
| test_tenant_list_quota.sh | rc=0 | 6s |  |
| test_tenant_service_isolation.sh | rc=0 | 1s |  |
| test_tls_server.sh | rc=0 | 4s |  |
| test_unit_hardening.sh | EXCLUDED | 0s | systemd service suite (real systemctl stop/reset-failed) |
| test_vantage_classifier.sh | rc=0 | 0s |  |
| test_vantage.sh | EXCLUDED | 0s | podman suite (rootless containers) |

`rc=0` = suite exited 0 (a `SKIP-SUITE:` note means it skipped itself). A non-zero rc under the tracer is reported, not hidden: tracing (and the blocked `systemctl`/`podman`/`docker`/`launchctl`/`loginctl` safety stubs, see `bash-blocked-calls.log`) can change a suite's outcome; its lines still count as executed.

## Python (coverage.py in a scratch venv)

Total: **65.8% (1371/2083 statements)**.

| file | coverage | covered/statements |
|---|---|---|
| lib/onnx_server.py | 26.3% | 113/430 |
| scripts/coverage/bash_line_coverage.py | 88.0% | 198/225 |
| scripts/coverage/make_report.py | 0.0% | 0/204 |
| scripts/golden/build_manifest.py | 67.9% | 19/28 |
| scripts/golden/run_golden.py | 91.4% | 254/278 |
| scripts/golden/similarity.py | 68.6% | 48/70 |
| scripts/golden/stats.py | 92.8% | 154/166 |
| scripts/golden/verify_manifest.py | 86.9% | 86/99 |
| scripts/release/scan_archive.py | 83.7% | 211/252 |
| tests/evidence/__init__.py | 100.0% | 0/0 |
| tests/evidence/leak_scan.py | 87.5% | 112/128 |
| tests/evidence/manifest.py | 82.9% | 68/82 |
| tests/evidence/writer.py | 89.3% | 108/121 |

Measured from the `tests/py` unit tier plus python subprocesses spawned by the included bash suites (`.pth` + `COVERAGE_PROCESS_START`). Files under the listed source dirs that no run imported appear as 0%.

## Files below the 85% floor (all languages)

The floor of 11.4.224(B) is a NECESSARY condition and a MINIMUM ON A PROXY; it is reported here for visibility only (no gate, OD-15).

| lang | file | coverage | detail |
|---|---|---|---|
| bash | lib/hardware.sh | 37.8% | 87/230 lines |
| bash | lib/engine.sh | 38.1% | 67/176 lines |
| bash | lib/svc_hook.sh | 39.6% | 38/96 lines |
| bash | lib/os_detect.sh | 44.0% | 11/25 lines |
| bash | lib/download.sh | 50.4% | 201/399 lines |
| bash | bin/llmctl | 54.9% | 67/122 lines |
| bash | lib/service_macos.sh | 64.7% | 88/136 lines |
| bash | scripts/release/preflight_submodules.sh | 73.7% | 42/57 lines |
| bash | lib/doctor.sh | 75.0% | 72/96 lines |
| bash | lib/service_linux.sh | 75.0% | 147/196 lines |
| bash | lib/common.sh | 75.4% | 43/57 lines |
| bash | lib/decide.sh | 78.0% | 191/245 lines |
| bash | lib/catalog.sh | 78.9% | 60/76 lines |
| bash | scripts/doc_counts.sh | 84.8% | 39/46 lines |
| go | llmctld/cmd/llmctld/hardware_probe.go | 0.0% | 0/11 stmts |
| go | internal/gateway/tick.go | 0.0% | 0/1 stmts |
| go | internal/vantage/cmd/vantage-probe/main.go | 0.0% | 0/2 stmts |
| go | llmctld/cmd/llmctld/main.go | 2.5% | 9/353 stmts |
| go | llmctld/cmd/llmctld/cli_certs.go | 30.3% | 23/76 stmts |
| go | llmctld/internal/api/routes_models.go | 36.4% | 79/217 stmts |
| go | llmctld/internal/api/client.go | 39.6% | 53/134 stmts |
| go | llmctld/internal/api/routes_cluster.go | 40.8% | 20/49 stmts |
| go | llmctld/internal/api/routes_mtls.go | 52.2% | 129/247 stmts |
| go | llmctld/internal/api/middleware_auth.go | 60.0% | 3/5 stmts |
| go | llmctld/internal/raft/node.go | 62.7% | 74/118 stmts |
| go | internal/registry/inode_unix.go | 66.7% | 2/3 stmts |
| go | cmd/llmctl-decide/cmd_serve.go | 67.8% | 244/360 stmts |
| go | llmctld/internal/raft/lock.go | 69.7% | 23/33 stmts |
| go | llmctld/internal/raft/replication_commands.go | 71.4% | 10/14 stmts |
| go | internal/certs/leaf.go | 71.7% | 71/99 stmts |
| go | llmctld/internal/mtls/certs.go | 73.1% | 49/67 stmts |
| go | llmctld/internal/replication/crypto.go | 75.0% | 18/24 stmts |
| go | internal/registry/process.go | 75.4% | 43/57 stmts |
| go | internal/calibrate/profile.go | 76.1% | 35/46 stmts |
| go | internal/client/errors.go | 76.5% | 39/51 stmts |
| go | llmctld/internal/api/routes_replication.go | 77.2% | 88/114 stmts |
| go | llmctld/internal/api/routes_auth.go | 77.4% | 41/53 stmts |
| go | llmctld/internal/mtls/truststore.go | 79.6% | 39/49 stmts |
| go | internal/keyring/export.go | 79.8% | 67/84 stmts |
| go | llmctld/internal/api/routes_tenants.go | 79.8% | 79/99 stmts |
| go | llmctld/internal/auth/oidc.go | 80.0% | 32/40 stmts |
| go | llmctld/internal/raft/running_profile.go | 80.0% | 12/15 stmts |
| go | internal/vantage/cli.go | 80.0% | 96/120 stmts |
| go | internal/client/probe.go | 80.6% | 112/139 stmts |
| go | internal/audit/logkey.go | 80.7% | 46/57 stmts |
| go | internal/client/permute.go | 81.0% | 188/232 stmts |
| go | internal/certs/secfile.go | 81.7% | 76/93 stmts |
| go | internal/gateway/proc.go | 82.5% | 141/171 stmts |
| go | llmctld/internal/api/server.go | 82.6% | 19/23 stmts |
| go | internal/vantage/vantage.go | 82.9% | 214/258 stmts |
| go | internal/vantage/probebin.go | 83.1% | 54/65 stmts |
| go | cmd/llmctl-decide/cmd_key.go | 83.3% | 10/12 stmts |
| go | internal/registry/lock.go | 83.3% | 15/18 stmts |
| go | internal/calibrate/fromprofile.go | 83.9% | 47/56 stmts |
| go | llmctld/internal/replication/checkpoint.go | 84.2% | 64/76 stmts |
| go | llmctld/internal/isolation/cgroup.go | 84.4% | 27/32 stmts |
| go | internal/certs/ca.go | 84.4% | 130/154 stmts |
| go | llmctld/internal/auth/jwt.go | 84.6% | 11/13 stmts |
| python | scripts/coverage/make_report.py | 0.0% | 0/204 stmts |
| python | lib/onnx_server.py | 26.3% | 113/430 stmts |
| python | scripts/golden/build_manifest.py | 67.9% | 19/28 stmts |
| python | scripts/golden/similarity.py | 68.6% | 48/70 stmts |
| python | tests/evidence/manifest.py | 82.9% | 68/82 stmts |
| python | scripts/release/scan_archive.py | 83.7% | 211/252 stmts |

## Exclusion list applied (`tests/coverage_exclusions.txt`, checked in)

| class | glob | reason | tracked item | paths dropped |
|---|---|---|---|---|
| non-shipping-fixtures-and-golden-assets | `internal/client/internal/clienttest/*` | test-only TLS gateway helper used by Go/bash tests; never built into a shipped binary | - | 53 |
| non-shipping-fixtures-and-golden-assets | `internal/gateway/internal/fakebackends/*` | fake llama-server/encoder backends for tests; never shipped | - | 65 |
| non-shipping-fixtures-and-golden-assets | `internal/server/internal/servetest/*` | test-only server harness; never shipped | - | 36 |
| non-shipping-fixtures-and-golden-assets | `internal/server/internal/testpki/*` | throw-away test CA/PKI generator; never shipped | - | 21 |
| non-shipping-fixtures-and-golden-assets | `internal/vantage/internal/fixture/*` | test fixture for the vantage suite; never shipped | - | 40 |
| non-shipping-fixtures-and-golden-assets | `llmctld/test/integration/*` | integration-test package (test files only), not shipped code | - | 0 |
| vendored-third-party | `submodules/*` | git submodules (llama.cpp, colibri, containers): third-party/upstream code, measured by their own projects | - | 0 |

Anything not listed above and not in a stage's `NOT MEASURED` section is inside the measured corpus. No first-party shipping code is excluded.

## Instrument limits (honest boundary, 11.4.6 / 11.4.224(C)(E))

- **Go**: statement coverage from the toolchain; only unit packages ran. `llmctld/test/integration` (~400 s) was NOT run, so packages it alone exercises are under-reported. Statement coverage is not branch coverage and says nothing about assertion strength: an assertion-free test raises it identically to a proving one.
- **Bash**: LINE coverage, not branch coverage - a same-line `if/else` counts covered with one arm never taken. `set +x` regions and traps are unaccounted. The executable-line set is a documented heuristic (keyword-only lines, case patterns, function headers, heredoc bodies and continuation/quoted-string lines are not counted; hits on continuation lines are credited to the statement start). Only bash processes that inherit `BASH_ENV` are traced: a suite that runs `env -i`, `sh`/`dash` scripts, or a hook that resets the environment is invisible. Suites run under 3-10x xtrace overhead and a 600 s per-suite timeout.
- **Python**: coverage.py line coverage only (no `--branch`); subprocess data merged via a `.pth` startup hook inside the scratch venv.
- Coverage is **necessary, never sufficient**: nothing in this report proves any code correct; the real bar remains catch-its-own-negation (paired mutations) and captured runtime evidence.
- The per-corpus calibration of the 85% threshold and the brownfield adoption policy are operator decisions and are NOT made here.

