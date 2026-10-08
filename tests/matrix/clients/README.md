# Matrix client adapters

Every adapter is an independent process with the same command line:

    CLIENT METHOD URL CACERT TIMEOUT_S BODYFILE|- HEADERSFILE|-

* `CACERT` is a PEM file (or `-` for the platform default trust store).
* `BODYFILE` holds the raw request body bytes (`-` = none). `HEADERSFILE` holds
  `Name: value` lines (it may contain the access key, so the runner creates it
  mode 0600 and deletes it afterwards; adapters never echo it).

Output (stdout, line protocol, one record per line):

    STATUS <int>              response status (absent when no HTTP answer)
    HEADER <name>: <value>    response header, name lower-cased
    BODY_B64 <base64>         response body bytes
    ERROR <text>              transport-level failure (no HTTP answer)
    TRUST <mechanism> <ok|fail: reason>   (SDK adapters only)

Exit code 0 means "the adapter ran" (a transport failure is reported with ERROR,
not by exit code); 2 means "adapter could not run" (missing runtime).
