# Containers upstream change G10 - `health.HealthTarget.TLSConfig`

Target repository: `vasic-digital/Containers`, package `pkg/health`.
Pinned base: `4a8f04e05f3535d77c48f69b89687f9fcc896fbf` (the submodule was NOT edited - FR-091).
Register rows: llmctl G-006 (gap-fix pass B/W3), Containers gap G10 in `../containers-gaps.md`.

## Problem (measured)

`CheckHTTP` builds its client with the default TLS configuration and hard-codes the `http` scheme when
`URL` is empty, so a service behind a private CA (llmctl's gateway) cannot be certified: the caller can only
dial TCP, which also passes a listener that never speaks TLS.

## Change

`HealthTarget` gains `TLSConfig *tls.Config`. When set, `CheckHTTP` uses `https` (if `URL` is empty) and a
dedicated transport carrying a clone of that configuration (RootCAs for a private CA, ServerName, client
certificates) - never the shared default transport. Nil keeps today's behaviour exactly.

Verified against a throw-away copy of the submodule: new test (private CA verifies; an empty pool makes the
same server unhealthy; no TLSConfig against a TLS port stays unhealthy) and the package's existing tests
pass with `-race`.

llmctl's `internal/registry/tlsprobe.go` (`TLSCheck`, a `health.CheckFunc` over the package's own
`HealthTarget`/`HealthResult`) is the workaround; once this lands it reduces to
`HealthTarget{..., Type: HealthHTTP, TLSConfig: &tls.Config{RootCAs: pool}}` through the default checker.
The handshake-only mode (no health path) would additionally want `HealthTLS`/a `TLSHandshake` check type -
optional follow-up, not needed by llmctl's gateway entry, which publishes `/healthz`.

## Patch (unified diff, apply with `patch -p1` at the repository root)

```diff
diff -ruN a/pkg/health/http.go b/pkg/health/http.go
--- a/pkg/health/http.go	2026-10-07 18:52:37.132038591 +0200
+++ b/pkg/health/http.go	2026-10-07 18:52:37.154668344 +0200
@@ -33,6 +33,9 @@
 	// When no full URL is provided, construct one from host:port + path.
 	if target.URL == "" {
 		scheme := "http"
+		if target.TLSConfig != nil {
+			scheme = "https"
+		}
 		path := target.Path
 		if path == "" {
 			path = "/"
@@ -54,8 +57,17 @@
 		timeout = defaultHTTPTimeout
 	}
 
+	var transport http.RoundTripper
+	if target.TLSConfig != nil {
+		// a dedicated transport: the shared default transport must never carry a caller's trust
+		// configuration, and connection reuse across differently-trusted targets would be wrong
+		tr := &http.Transport{TLSClientConfig: target.TLSConfig.Clone(), DisableKeepAlives: true}
+		defer tr.CloseIdleConnections()
+		transport = tr
+	}
 	client := &http.Client{
-		Timeout: timeout,
+		Timeout:   timeout,
+		Transport: transport,
 		// Do not transparently follow redirects (HE-3): a health check
 		// must certify exactly the NAMED target. Without this, the
 		// default client follows up to 10 cross-host redirects while
diff -ruN a/pkg/health/http_tls_config_test.go b/pkg/health/http_tls_config_test.go
--- a/pkg/health/http_tls_config_test.go	1970-01-01 01:00:00.000000000 +0100
+++ b/pkg/health/http_tls_config_test.go	2026-10-07 18:53:02.972290468 +0200
@@ -0,0 +1,37 @@
+package health
+
+import (
+	"context"
+	"crypto/tls"
+	"crypto/x509"
+	"net"
+	"net/http"
+	"net/http/httptest"
+	"testing"
+)
+
+func TestCheckHTTPUsesTLSConfig(t *testing.T) {
+	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) }))
+	defer srv.Close()
+	host, port, _ := net.SplitHostPort(srv.Listener.Addr().String())
+	pool := x509.NewCertPool()
+	pool.AddCert(srv.Certificate())
+
+	// the private CA in TLSConfig: healthy, with no URL (scheme becomes https)
+	ok := CheckHTTP(context.Background(), HealthTarget{Name: "t", Host: host, Port: port, Path: "/", Type: HealthHTTP,
+		TLSConfig: &tls.Config{RootCAs: pool}})
+	if !ok.Healthy {
+		t.Fatalf("private CA must verify: %s", ok.Error)
+	}
+	// an empty pool: the certificate is untrusted - unhealthy, never silently accepted
+	bad := CheckHTTP(context.Background(), HealthTarget{Name: "t", Host: host, Port: port, Path: "/", Type: HealthHTTP,
+		TLSConfig: &tls.Config{RootCAs: x509.NewCertPool()}})
+	if bad.Healthy {
+		t.Fatal("an untrusted certificate must be unhealthy")
+	}
+	// without TLSConfig behaviour is unchanged: plain http against a TLS port fails
+	plain := CheckHTTP(context.Background(), HealthTarget{Name: "t", Host: host, Port: port, Path: "/", Type: HealthHTTP})
+	if plain.Healthy {
+		t.Fatal("plain http against a TLS listener must be unhealthy")
+	}
+}
diff -ruN a/pkg/health/types.go b/pkg/health/types.go
--- a/pkg/health/types.go	2026-10-07 18:52:37.131979361 +0200
+++ b/pkg/health/types.go	2026-10-07 18:52:37.154580984 +0200
@@ -1,6 +1,7 @@
 package health
 
 import (
+	"crypto/tls"
 	"time"
 
 	"digital.vasic.containers/internal/netaddr"
@@ -37,6 +38,11 @@
 	Path string
 	// Timeout is the maximum duration for a single check attempt.
 	Timeout time.Duration
+	// TLSConfig, when non-nil, makes an HTTP check use https with this client TLS
+	// configuration (RootCAs for a private CA, ServerName, client certificates). The
+	// scheme is https whenever it is set and URL is empty; a nil TLSConfig keeps today's
+	// behaviour (plain http, or the scheme of URL with the default TLS configuration).
+	TLSConfig *tls.Config
 	// Required indicates whether a failure for this target should be
 	// treated as fatal.
 	Required bool
```
