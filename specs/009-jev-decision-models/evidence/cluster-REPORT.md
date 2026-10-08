# G-106 / OD-21 / T131 - llmctld cluster CLI TLS (agent CLUSTER report)

Date: 2026-10-08. Tree: uncommitted on main (nothing staged or committed).

## Design decision and why

The three defects (no SANs, server demands a client certificate, CLI passes no
trust/cert) are fixed together, inside `llmctld` and `lib/cluster.sh`:

* **SANs inside `mtls.IssueNodeCert`** (not at call sites). Every leaf gets IP
  127.0.0.1, IP ::1, DNS localhost, the machine hostname, the `-api-bind` host
  (wildcards dropped) and `-advertise` names (IP vs DNS auto-classified,
  invalid DNS names dropped, de-duplicated). Because the policy is in the
  issuing function, the renew and CA-rotation handlers in `api/routes_mtls.go`
  (which call `IssueNodeCert` for the API cert) cannot silently lose SANs.
  Extras are process-wide (`mtls.SetExtraSANs`) because the daemon is one node
  identity per process.
* **CLI client material written by the daemon.** `llmctld cluster
  bootstrap|join` write `ca.crt`, `client.crt`, `client.key` into a `0700`
  directory (`-cli-cert-dir`, default `cli/` next to `-ca-cert`; existing
  looser dir is chmod-ed to 0700), files `0600`, atomic temp+rename, and print
  `CLI_CERT_DIR=<dir>`. The client cert is `clientAuth`-only, no SANs. The CA
  private key is never copied there (test asserts it). New subcommand
  `llmctld cluster issue-cli-cert -ca-cert -ca-key [-out-dir]` re-issues.
* **`lib/cluster.sh`**: for `https://` endpoints passes `--cacert`, and
  `--cert/--key` when configured (`LLMCTL_CLUSTER_CERT_DIR`, or per-item
  `LLMCTL_CLUSTER_CACERT/CERT/KEY`; `CURL_CA_BUNDLE` still accepted and turned
  into an explicit `--cacert`). Never `-k`/`--insecure`. A cert without key,
  unreadable files, or a key readable by group/others => rc 78 with a specific
  message and curl is not run; `cluster::require_daemon` reports "TLS material
  is unusable" rather than "unreachable". The bearer token now goes to curl as
  `-H @tmpfile` (0600, removed after) so it is no longer on argv (previously it
  was). `http://` test doubles get no TLS args. Existing behaviour on curls
  without HTTP/3 kept (honest SKIP with the probed Features line).
* **One source of truth?** Root `internal/certs` is in another Go module; an
  `llmctld` cannot import it. Shelling out to `llmctl cert ensure` would make
  the daemon depend on the root binary and its output format; a shared third
  module is disproportionate for ~60 lines. Chosen: a small implementation in
  `llmctld/internal/mtls/sans.go` implementing the same policy (loopback +
  hostname + operator names; CA-issued; 0700 dirs/0600 keys), aligned by tests
  on both sides. Documented in `docs/llmctld-cluster-tls.md`.

## Items: RED / GREEN / mutation proof

All Go commands from `/home/milosvasic/Projects/llmctl/llmctld`.

1. **Round trip with strict verification (the three failures).**
   Tests: `cmd/llmctld/cli_roundtrip_test.go` (Go HTTP/3 client configured like
   curl: RootCAs = only ca.crt, ServerName from URL, client cert from files,
   no InsecureSkipVerify). RED was run against a pre-fix stub (no SANs, node
   cert as client cert), real raft node + real `api.NewServer`:
   `TestCLIRoundTrip_StrictVerification_Succeeds` FAIL: `CRYPTO_ERROR 0x12a
   (local): tls: failed to verify certificate: x509: cannot validate
   certificate for 127.0.0.1 because it doesn't contain any IP SANs`;
   `AllLoopbackNamesAreCovered` FAIL (127.0.0.1, localhost "not valid for any
   names", ::1); `AdvertisedAddressBecomesSAN` FAIL; `WriteCLIMaterial`
   permission test FAIL (0755 dir left). GREEN: all pass after the fix
   (`go test ./cmd/llmctld/ ./internal/mtls/` ok).
   Also green and meaningful both ways: no client cert refused, client cert
   from another CA refused, server from another CA refused by client, name
   outside SAN set refused.
2. **Mutations (each restored afterwards, file contents compared):**
   * drop SANs => `StrictVerification`, `AllLoopbackNames`,
     `AdvertisedAddress`, `TestIssueNodeCert_CarriesLoopbackAndHostnameSANs`,
     `TestSetExtraSANs_*` FAIL;
   * server `ClientAuth` -> `NoClientCert` => `NoClientCertificateIsRefused`,
     `ClientCertFromAnotherCAIsRefused` (+3 more) FAIL;
   * accept any CA (`TrustStore.Verify` returns nil) =>
     `ClientCertFromAnotherCAIsRefused`, two truststore tests FAIL;
   * write CA key into the CLI dir => `TestWriteCLIMaterial_PermissionsAndNoStrayKey` FAIL.
3. **mtls unit tests** `internal/mtls/sans_test.go`: default SAN set verified by
   name against only the CA, extras classification, wildcard/invalid dropped,
   no duplicates, client cert is clientAuth-only/no SANs/trusted by its CA only.
4. **`lib/cluster.sh` argument construction** `tests/test_cluster_cli_args.sh`
   (31 assertions, fake curl on PATH recording argv and the `-H @file`
   content): `--cacert/--cert/--key` present, `--http3` when the curl lists
   HTTP3, none of `-k --insecure --proxy-insecure --doh-insecure
   --ssl-no-revoke --ssl-revoke-best-effort` on argv, key bytes and bearer
   token not on argv, header temp file removed, loose key refused (curl not
   invoked), cert-without-key / missing CA refused, CURL_CA_BUNDLE => --cacert,
   http:// no TLS args, plus a source grep over `lib/` and `bin/llmctl` for
   verification-disabling switches (control needle: planted `curl -k` is
   detected). Mutations: `--insecure` added, `-k` added, `--cert` dropped,
   token back on argv, mode check removed => each makes the suite FAIL
   (the first static-grep version missed `(--insecure)`; the pattern was
   widened and re-proven).
5. **The three cluster suites** now use `cluster_cli_skip_reason` that probes
   through `lib/cluster.sh` itself with `LLMCTL_CLUSTER_CERT_DIR`
   (`llmctld_bootstrap` exports `LLMCTLD_CLI_CERT_DIR` parsed from the daemon's
   `CLI_CERT_DIR=` line); success paths use `LLMCTL_CLUSTER_CERT_DIR` and the
   new `cluster_curl_h3` helper (cacert + client cert, never -k).
   On this host (real curl, no HTTP3): all three PASS with the accurate SKIP
   (quotes the Features line, adds that the certificate side is provided).
   `HOSTDEP-BEGIN/END` markers added around the host-dependent branch.

## What was verified with what

* **Real HTTP/3 transport + real daemon code + strict TLS, Go client**:
  `TestCLIRoundTrip_*` (above).
* **lib/cluster.sh + bin/llmctl + real llmctld process, HTTP/3, strict TLS,
  using a throwaway curl look-alike** (Go quic-go program, supports exactly the
  flags lib/cluster.sh uses, `--cacert/--cert/--key` honoured, no insecure
  mode; built from a temp dir inside llmctld, binary in the scratchpad, source
  dir deleted): the three suites' success paths ran and all PASSED -
  `cluster status` (is_leader, node n1), `cluster join/leave` (daemon's JSON,
  not "unreachable"), `apikey create/rotate` (new key authenticates, old secret
  401 after rotation, rotated one 200), `tenant create/list/quota` (set/view
  round trip). Same run with the pre-fix `lib/cluster.sh` restored from HEAD
  against the new daemon: honest SKIP with the measured TLS error (shows the
  CLI side was necessary).
* **NOT verified**: a real curl speaking HTTP/3 (this host's curl has no HTTP3
  feature; no http3 curl/podman image used). The shim proves script argument
  handling and the daemon handshake, not curl's own QUIC/TLS code. The suites'
  non-skip branches have therefore only run under the shim.

## Gate results (this session)

* `gofmt -l llmctld`: clean. `cd llmctld && go vet ./...`: clean.
* `go test -race -count=1 ./...` (llmctld): ALL packages ok, incl. `test/integration` (398s), `cmd/llmctld`, `internal/api`, `internal/mtls`, `internal/raft`.
* `tests/test_syntax.sh` PASS; `tests/test_cluster_request_checked.sh` PASS;
  the three cluster suites + `test_cluster_cli_args.sh` PASS;
  `PATH=$HOME/.local/bin:$PATH make lint` (shellcheck 0.11.0) clean.

## Honest limits / notes for others

* Client certs expire after 365 days and are issued from the CA in use at
  bootstrap/join; after a finalised CA rotation they stop being trusted - re-run
  `llmctld cluster issue-cli-cert`. No per-user revocation beyond serial
  revocation.
* SAN list is fixed at process start (`SetExtraSANs`); a changed `-advertise`
  needs a restart (renewals reuse the start-time list).
* Changing `lib/cluster.sh` token delivery to `-H @file` needs curl >= 7.55.
* Files touched: `llmctld/internal/mtls/{certs.go,sans.go,sans_test.go}`,
  `llmctld/cmd/llmctld/{main.go,cli_certs.go,cli_roundtrip_test.go}`,
  `lib/cluster.sh`, `tests/{helpers.sh,test_cluster_cli_args.sh,
  test_cluster_join_leave.sh,test_apikey_lifecycle.sh,test_tenant_list_quota.sh}`,
  `docs/llmctld-cluster-tls.md` (new), `docs/cluster-architecture.md` (one
  pointer paragraph), `docs/scripts/{cluster.md,README.md,
  test_cluster_cli_args.md,test_cluster_join_leave.md,test_apikey_lifecycle.md,
  test_tenant_list_quota.md}`.

## What the DOCS agent must say (README/CHANGELOG/general pages)

* CHANGELOG 3.1.0: "Fix G-106: the opt-in llmctld cluster CLI now works over
  HTTP/3 with mutual TLS. Daemon certificates carry SANs (loopback, hostname,
  -api-bind host, -advertise); `llmctld cluster bootstrap|join` write a CLI
  trust bundle (ca.crt, client.crt, client.key; 0700/0600) and print
  CLI_CERT_DIR; lib/cluster.sh passes --cacert/--cert/--key (set
  LLMCTL_CLUSTER_CERT_DIR), never -k; new `llmctld cluster issue-cli-cert`;
  bearer token no longer on the curl command line."
* user-manual / faq / limitations / tutorial: replace any statement that the
  cluster CLI cannot complete a round trip because of certificates; keep the
  one true limit: the host `curl` must list the HTTP3 feature, otherwise
  `llmctl cluster|tenant|apikey` report "llmctld unreachable" and the suites
  SKIP. Mention env vars LLMCTL_CLUSTER_CERT_DIR / _CACERT / _CERT / _KEY.
* Link `docs/llmctld-cluster-tls.md` from the README docs index (it is linked
  from `docs/cluster-architecture.md`; the reachability check should be run by
  DOCS after their README edit).
* Gap register: G-106 -> FIXED (certificate/trust/client-cert side), with the
  note that real-curl-over-QUIC was not run on the development host; G-089's
  "PARTIAL" can be closed with the same caveat.
