# CURL-H3 report - real curl over QUIC vs the llmctld cluster CLI (OD-30 / T140)

Date: 2026-10-08. Nothing staged/committed; no repo files edited (only this directory).

## Recipe chosen and why
curl.se/docs/http3.html: OpenSSL 3.5.0+ needs ngtcp2 >= 1.12; curl is built with `--with-ngtcp2 --with-nghttp3`
(ngtcp2 picks its `libngtcp2_crypto_ossl` helper for OpenSSL 3.5; confirmed in build-ngtcp2-configure.log:
"libngtcp2_crypto_ossl: yes"). The alternative `--with-openssl-quic` was not needed. System OpenSSL 3.5.5 is used
dynamically (no OpenSSL build). Tarballs (release .tar.xz; no autoreconf/libtool needed):

| component | version | sha256 |
|---|---|---|
| nghttp3 | 1.18.0 | aad782c23d3f01bd4bb52c8bac7a553b631ef8115fd1612703df6183449fef19 |
| ngtcp2 | 1.25.0 | 2a34d2484ba17847a5d11965704e9dd0fac4c6d8efc75ffe1ec7de66d8c6b6fb |
| curl | 8.22.0 | f7ef3ae8a22e521f289803fe93543eb64c329b58aa73a9e224dfd915a2a5f4f7 |

Verification actually done: nghttp3 and ngtcp2 sha256 equal the `checksums.txt` published in the same GitHub release
(same origin, so only integrity, not authenticity). curl 8.22.0: GPG signature `Good signature` from
Daniel Stenberg, primary fingerprint 27ED EAF2 2F3A BCEB 50DB 9A12 5CC9 08FD B71E 12C2 (key from daniel.haxx.se;
not web-of-trust certified). The nghttp3/ngtcp2 .asc (key 516B6229...DEC) could NOT be checked: key not obtainable
(keys.openpgp.org returns it without user IDs). curl.se serves no .sha256 file (404).
Missing tools: libtool (not needed for release tarballs); nothing essential missing.

## Build (private prefix ~/.local/share/llmctl/tools/curl-h3/{src,prefix}, nice 10, ionice -c3, -j2, LD_LIBRARY_PATH unset)
1. nghttp3: `./configure --prefix=P --enable-lib-only --enable-static --disable-shared`
2. ngtcp2: same flags plus `--with-openssl`, `PKG_CONFIG_PATH=P/lib/pkgconfig`
3. curl: `--disable-shared --enable-static --with-openssl --with-ngtcp2=P --with-nghttp3=P --without-nghttp2
   --without-{libpsl,brotli,zstd,libidn2,libssh2,libssh,librtmp} --disable-ldap --disable-ldaps --disable-docs --disable-manual`
Finding: first curl attempt with shared libcurl FAILED at link ("libnghttp3.a(nghttp3_map.o): relocation R_X86_64_PC32
against stderr ... recompile with -fPIC", see commit-less log note below); fix = static curl (`--disable-shared`), not
rebuilding the libs with -fPIC. (That failed make log was overwritten by the successful rebuild.)
Result (`curl-version.txt`): `curl 8.22.0 ... OpenSSL/3.5.5 zlib/1.3.1 ngtcp2/1.25.0 nghttp3/1.18.0`,
Features include `HTTP3`; only libssl/libcrypto are dynamic (system), so LD_LIBRARY_PATH cannot shadow ngtcp2/nghttp3.
No HTTP/2 (nghttp2 not linked) - irrelevant to the H3-only CLI; this curl is a test tool, not a general replacement.

## Direct request (`direct-h3-request.txt`)
Throwaway quic-go server (module cache offline, built in scratchpad, killed by pid, dir removed): curl 8.22.0
`--http3-only --cacert ca.pem https://127.0.0.1:18443/` => `* using HTTP/3`, `< HTTP/3 200`, body `proto=HTTP/3.0`
(TLS1.3 X25519MLKEM768). Controls: system curl 8.18.0 rejects `--http3-only` ("does not support this"); new curl
without the CA => exit 60 certificate verification failure.

## The four suites with the new curl FIRST in PATH (`env -u LD_LIBRARY_PATH`)
| suite | result | success path taken |
|---|---|---|
| tests/test_cluster_cli_args.sh | PASS rc=0 | n/a (argv checks) |
| tests/test_cluster_join_leave.sh | PASS rc=0 | YES: "cluster status over the real HTTP/3 transport: exit 0", leader=true, join/leave surface daemon JSON; only SKIP = second-peer scenario (needs a second llmctld, unrelated to curl) |
| tests/test_apikey_lifecycle.sh | PASS rc=0, 15 ok, 0 SKIP | YES |
| tests/test_tenant_list_quota.sh | PASS rc=0, 18 ok, 0 SKIP | YES |
Control (`suite-control-system-curl-join-leave.log`): same suite with the system curl (no HTTP3) => "SKIP: cluster
join/leave success path". So the SKIP->PASS difference is attributable to the curl. No suite failed with the real
curl: lib/cluster.sh `--cacert/--cert/--key`, `-H @file`, SAN matching (127.0.0.1, localhost), ALPN h3 and the
client-cert flow all work against real llmctld with real curl QUIC. No root cause to report, no fix proposed.

## Reproduce
```
B=~/.local/share/llmctl/tools/curl-h3; mkdir -p $B/src $B/prefix; cd $B/src   # download the 3 tarballs, check sha256 above
unset LD_LIBRARY_PATH; export PKG_CONFIG_PATH=$B/prefix/lib/pkgconfig
# build nghttp3, ngtcp2, curl with the flags in "Build"; then:
PATH=$B/prefix/bin:$PATH env -u LD_LIBRARY_PATH bash tests/test_cluster_join_leave.sh   # etc.
```
## Honest limits
Private prefix only (99 MB under ~/.local/share/llmctl/tools/curl-h3, not packaged, not in PATH by default),
host-specific (glibc, system OpenSSL 3.5.5 dynamic); suites exercised one node, loopback only; the second-peer
join scenario remains unexercised; nghttp3/ngtcp2 signatures unverified (checksums only); curl is statically
linked to ngtcp2/nghttp3 so security updates require a rebuild. Logs: build-*.log, suite-*.log.
