# llmctld cluster API: certificates, trust and the shell CLI

| Field | Value |
|---|---|
| Revision | 1 |
| Scope | the opt-in `llmctld` cluster daemon and `lib/cluster.sh` (not the decision gateway; its TLS is `docs/tls-and-keys.md`) |
| Gap closed | G-106 (operator decision OD-21, task T131) |

## What was wrong

`llmctl cluster|tenant|apikey` reach the daemon with `curl` over HTTP/3 and full
certificate verification. Even a curl built with HTTP/3 could not complete a
round trip, for three reasons that all had to be fixed together:

1. the daemon certificate had a CN but **no Subject Alternative Names** (curl
   reported `cannot validate certificate for 127.0.0.1 because it doesn't
   contain any IP SANs`);
2. the server **demands a client certificate** (mutual TLS: `tls: certificate
   required`);
3. `lib/cluster.sh` passed neither a client certificate/key nor a trust option.

## What happens now

| Piece | Behaviour |
|---|---|
| Server certificates | every leaf issued by `llmctld/internal/mtls` carries SANs: IP `127.0.0.1`, IP `::1`, DNS `localhost`, the machine hostname, the host of `-api-bind` (unless it is a wildcard such as `0.0.0.0`) and every name or address given in `-advertise a.example,10.0.0.5`. The policy sits inside `IssueNodeCert`, so renewals and CA rotation (`/v1/cluster/mtls/renew`, `rotate`) cannot lose the SANs. |
| CLI material | `llmctld cluster bootstrap` and `join` write `ca.crt`, `client.crt`, `client.key` into a directory (default: `cli/` next to `-ca-cert`; override with `-cli-cert-dir`) and print `CLI_CERT_DIR=<dir>`. The directory is `0700` (an existing looser directory is tightened), every file `0600`, written atomically. Only the CA **certificate** goes there; the CA private key stays at `-ca-key`. The client certificate is `clientAuth`-only, has no SANs and is issued by the same CA the daemon trusts. |
| Re-issue | `llmctld cluster issue-cli-cert -ca-cert ca.crt -ca-key ca.key [-out-dir DIR]` writes a fresh set (client certificates are valid 365 days; after a coordinated CA rotation is finalised, re-issue from the new CA). |
| CLI side | `lib/cluster.sh` passes `--cacert`, `--cert`, `--key` for `https://` endpoints and never any verification-disabling switch. `tests/test_cluster_cli_args.sh` greps `lib/` and `bin/` for `-k`, `--insecure`, `--proxy-insecure`, `--doh-insecure`, `--ssl-no-revoke` and the like and fails if one appears. |
| Secrets | only file **paths** reach curl's argv. A group/other-readable `client.key` is refused (exit 78, `chmod 600` hint). The bearer token (`LLMCTL_CLUSTER_TOKEN`) is handed to curl as `-H @file` with a `0600` temporary file that is removed after the call, so it is not visible in `ps`. |

## Configuring the CLI

```bash
# what `llmctld cluster bootstrap|join` printed as CLI_CERT_DIR=...
export LLMCTL_CLUSTER_CERT_DIR=/path/to/cli
export LLMCTL_CLUSTER_ENDPOINT=https://127.0.0.1:9443
llmctl cluster status
```

Per-item overrides, first match wins: `LLMCTL_CLUSTER_CACERT`,
`LLMCTL_CLUSTER_CERT`, `LLMCTL_CLUSTER_KEY`; `CURL_CA_BUNDLE` is still honoured
as the trust anchor and turned into an explicit `--cacert`. Use a name or
address in `LLMCTL_CLUSTER_ENDPOINT` that is in the certificate's SAN set;
for a non-loopback address start the daemon with `-advertise`.

## Design decision: one policy, two implementations

The decision gateway's TLS (spec 009, root-module `internal/certs`) and the
cluster daemon are **separate Go modules**; `llmctld` cannot import another
module's `internal/` packages. Options considered: (a) shell out to
`llmctl cert ensure` from the daemon, (b) share a third module, (c) keep a
small implementation in `llmctld/internal/mtls`. (a) would make the daemon
depend on the root binary being installed and on its output format; (b) adds a
module and a release dependency for ~60 lines. We chose (c): the policy is the
same two rules in both places (SANs for loopback + hostname + operator-supplied
names; CA-issued leaves; `0700` directories and `0600` keys), and the daemon's
rotation machinery already owns issuance in `llmctld`. The two are kept
aligned by tests on each side that assert the same SAN set and permissions
(`internal/mtls/sans_test.go`, `cmd/llmctld/cli_roundtrip_test.go`,
`internal/certs/certs_test.go`).

## Verification status and limits

* Verified with a **real HTTP/3 transport and full verification** using a Go
  QUIC/HTTP-3 client configured exactly as curl is (trust only `ca.crt`,
  client certificate from files, server name from the URL):
  `llmctld/cmd/llmctld/cli_roundtrip_test.go`.
* `lib/cluster.sh`'s argument construction is verified with a fake curl on
  `PATH` (`tests/test_cluster_cli_args.sh`).
* The three suites that exercise the CLI against a real daemon
  (`test_cluster_join_leave.sh`, `test_apikey_lifecycle.sh`,
  `test_tenant_list_quota.sh`) run their success path only when the host
  `curl` lists the `HTTP3` feature; otherwise they print a SKIP quoting the
  measured `Features:` line. The system curl of the development host has no
  HTTP3, so the real-curl-over-QUIC combination was verified (2026-10-08) with
  a **real curl 8.22.0 built with ngtcp2 1.25.0 / nghttp3 1.18.0 against the
  system OpenSSL 3.5.5** in a private prefix (see "Getting a curl that lists
  HTTP3" below): a direct `--http3-only` request returned `HTTP/3 200` with
  the local CA as the only trust anchor, and `test_cluster_cli_args.sh`,
  `test_cluster_join_leave.sh`, `test_apikey_lifecycle.sh` (15 checks) and
  `test_tenant_list_quota.sh` (18 checks) all passed with that curl first in
  `PATH`, taking the success path. A control run of the same join/leave suite
  with the system curl skipped the success path, so the SKIP-to-PASS change is
  attributable to the curl. Evidence:
  `specs/009-jev-decision-models/evidence/curl-h3/CURL-H3-REPORT.md` and the
  `suite-*.log` files next to it. Not exercised: the second-peer join scenario
  (needs a second `llmctld`) and any non-loopback network.
* A client certificate issued before a coordinated CA rotation stops being
  trusted once the old CA is dropped at finalisation; re-issue it with
  `issue-cli-cert`. The CLI certificate is not revocable per-user beyond the
  existing serial revocation (`/v1/cluster/mtls/revoke`).

## Getting a curl that lists HTTP3

The CLI needs a host `curl` whose `curl --version` prints `HTTP3` in its `Features:` line (it probes this itself and
adds `--http3` only then). Many distribution curls do not have it. Options, in order of preference:

1. Install a distribution package that was built with HTTP/3 (check `curl --version` afterwards; llmctl does not
   install curl for you).
2. Build one yourself against ngtcp2 and nghttp3 (curl's own guide: <https://curl.se/docs/http3.html>; OpenSSL 3.5 or newer
   works with ngtcp2 1.12 or newer). The recipe used for the verification above, including versions, checksums,
   `configure` flags and the exact commands to re-run the four cluster suites with that curl first in `PATH`, is
   in `specs/009-jev-decision-models/evidence/curl-h3/CURL-H3-REPORT.md` ("Reproduce"). Verification steps taken there:
   the nghttp3/ngtcp2 tarball checksums were compared with the checksums published in the same release (integrity only)
   and the curl signature was checked against Daniel Stenberg's key; the nghttp3/ngtcp2 `.asc` signatures could not be
   checked.

That build lives in a **private test prefix** (`~/.local/share/llmctl/tools/curl-h3`, not on `PATH`, about 99 MB). It is
**not packaged, not installed by llmctl and not a general-purpose curl** (it was built without HTTP/2 and several other
features, and it is statically linked to ngtcp2/nghttp3, so security updates need a rebuild). Treat it as a way to
reproduce the verification, not as a supported installation.
