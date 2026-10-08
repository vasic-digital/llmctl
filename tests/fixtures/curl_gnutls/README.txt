Recorded-shape curl lines for a GnuTLS-built curl (e.g. ALT Linux curl 8.19, host nezha.local).
These are the exact `tool_curl` output lines negative_tls.py sees ("curl rc=<n> <stderr>").
The two causes quoted in specs/009-jev-decision-models/evidence/portability-nezha/REPORT.md
("certificate signer not trusted", "certificate error, no details available") come from that run;
the remaining lines use the other fixed `cause` strings of libcurl's gtls backend
("certificate has expired") and its host-name check wording. They are an input corpus for the
regex check in tests/test_matrix_harness.sh, not a claim about every GnuTLS release.
