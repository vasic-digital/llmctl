package registry

import (
	"context"
	"crypto/tls"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"
)

// tlsServer serves /health (status given) over TLS with pki's certificate.
func tlsServer(t *testing.T, pki *testPKI, status int) (host string, port int) {
	t.Helper()
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/health" {
			http.NotFound(w, r)
			return
		}
		w.WriteHeader(status)
	}))
	srv.TLS = &tls.Config{Certificates: []tls.Certificate{pki.Cert}}
	srv.Config.ErrorLog = log.New(io.Discard, "", 0) // failed handshakes are the point of these tests
	srv.StartTLS()
	t.Cleanup(srv.Close)
	h, p, _ := net.SplitHostPort(srv.Listener.Addr().String())
	n, _ := strconv.Atoi(p)
	return h, n
}

func httpsEntry(host string, port int, path string) Entry {
	return Entry{Name: "gw", Host: host, Port: port, Protocol: "https", HealthPath: path, PID: 4242, CmdToken: "x"}
}

func probeWith(t *testing.T, caPath string, e Entry) (bool, string) {
	t.Helper()
	cfg := testCfg(t)
	cfg.CACert = caPath
	return New(cfg).probe(context.Background(), e)
}

// G-006: a good CA and a serving health path are healthy ...
func TestHTTPSProbeGoodCAHealthy(t *testing.T) {
	pki := newTestPKI(t, time.Time{}, time.Time{})
	h, p := tlsServer(t, pki, 200)
	if ok, why := probeWith(t, pki.writeCA(t), httpsEntry(h, p, "/health")); !ok {
		t.Fatalf("good CA + 200 must be healthy: %s", why)
	}
}

// ... a CA that did not sign the server certificate is not ...
func TestHTTPSProbeWrongCAUnhealthy(t *testing.T) {
	pki := newTestPKI(t, time.Time{}, time.Time{})
	other := newTestPKI(t, time.Time{}, time.Time{})
	h, p := tlsServer(t, pki, 200)
	ok, why := probeWith(t, other.writeCA(t), httpsEntry(h, p, "/health"))
	if ok || !strings.Contains(why, "certificate") {
		t.Fatalf("wrong CA must be unhealthy with a certificate reason, got ok=%v why=%q", ok, why)
	}
}

// ... nor is an expired certificate.
func TestHTTPSProbeExpiredCertUnhealthy(t *testing.T) {
	pki := newTestPKI(t, time.Now().Add(-48*time.Hour), time.Now().Add(-time.Hour))
	h, p := tlsServer(t, pki, 200)
	ok, why := probeWith(t, pki.writeCA(t), httpsEntry(h, p, "/health"))
	if ok || !strings.Contains(why, "expired") {
		t.Fatalf("expired certificate must be unhealthy (reason mentions expired), got ok=%v why=%q", ok, why)
	}
}

// a listener that accepts TCP but never speaks TLS used to pass the TCP dial
func TestHTTPSProbeTCPOnlyListenerUnhealthy(t *testing.T) {
	pki := newTestPKI(t, time.Time{}, time.Time{})
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() { time.Sleep(3 * time.Second); c.Close() }() // accept, say nothing
		}
	}()
	port := ln.Addr().(*net.TCPAddr).Port
	start := time.Now()
	ok, _ := probeWith(t, pki.writeCA(t), httpsEntry("127.0.0.1", port, "/health"))
	if ok {
		t.Fatal("a TCP-only listener must not be healthy for an https entry")
	}
	if time.Since(start) > 6*time.Second {
		t.Fatalf("probe is not bounded: %s", time.Since(start))
	}
}

// a plain-HTTP server registered as https answers the handshake with garbage
func TestHTTPSProbePlainHTTPServerUnhealthy(t *testing.T) {
	pki := newTestPKI(t, time.Time{}, time.Time{})
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) }))
	defer s.Close()
	_, p, _ := net.SplitHostPort(s.Listener.Addr().String())
	port, _ := strconv.Atoi(p)
	if ok, _ := probeWith(t, pki.writeCA(t), httpsEntry("127.0.0.1", port, "/health")); ok {
		t.Fatal("plain HTTP on an https entry must be unhealthy")
	}
}

// the health path is really requested: 500 and 404 are unhealthy even though TLS is fine
func TestHTTPSProbeChecksTheHealthPathStatus(t *testing.T) {
	pki := newTestPKI(t, time.Time{}, time.Time{})
	h, p := tlsServer(t, pki, 500)
	ca := pki.writeCA(t)
	if ok, _ := probeWith(t, ca, httpsEntry(h, p, "/health")); ok {
		t.Fatal("500 from the health path must be unhealthy")
	}
	h2, p2 := tlsServer(t, pki, 200)
	if ok, _ := probeWith(t, ca, httpsEntry(h2, p2, "/nope")); ok {
		t.Fatal("404 from the health path must be unhealthy")
	}
}

// no health path: the verified handshake alone decides (but it must still be verified)
func TestHTTPSProbeWithoutPathNeedsVerifiedHandshake(t *testing.T) {
	pki := newTestPKI(t, time.Time{}, time.Time{})
	other := newTestPKI(t, time.Time{}, time.Time{})
	h, p := tlsServer(t, pki, 200)
	if ok, why := probeWith(t, pki.writeCA(t), httpsEntry(h, p, "")); !ok {
		t.Fatalf("verified handshake must be healthy: %s", why)
	}
	if ok, _ := probeWith(t, other.writeCA(t), httpsEntry(h, p, "")); ok {
		t.Fatal("unverified handshake must be unhealthy")
	}
}

// fail closed: an https entry cannot be certified without the CA
func TestHTTPSProbeWithoutCAIsUnhealthy(t *testing.T) {
	pki := newTestPKI(t, time.Time{}, time.Time{})
	h, p := tlsServer(t, pki, 200)
	ok, why := probeWith(t, "", httpsEntry(h, p, "/health"))
	if ok || !strings.Contains(why, "LLMCTL_CACERT") {
		t.Fatalf("no CA configured: want unhealthy naming LLMCTL_CACERT, got ok=%v why=%q", ok, why)
	}
	ok, why = probeWith(t, "/nonexistent/ca.crt", httpsEntry(h, p, "/health"))
	if ok || why == "" {
		t.Fatalf("unreadable CA: want unhealthy with a reason, got ok=%v why=%q", ok, why)
	}
	bad := t.TempDir() + "/ca.crt"
	_ = os.WriteFile(bad, []byte("not a certificate"), 0o644)
	if ok, _ := probeWith(t, bad, httpsEntry(h, p, "/health")); ok {
		t.Fatal("a CA file without certificates must be unhealthy")
	}
}

// loopback engine entries keep plain http probing of their health path
func TestHTTPEntriesStillProbedOverHTTP(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health" {
			w.WriteHeader(200)
			return
		}
		w.WriteHeader(404)
	}))
	defer s.Close()
	_, p, _ := net.SplitHostPort(s.Listener.Addr().String())
	port, _ := strconv.Atoi(p)
	e := Entry{Name: "eng", Host: "127.0.0.1", Port: port, Protocol: "http", HealthPath: "/health", PID: 4242, CmdToken: "x"}
	if ok, why := probeWith(t, "", e); !ok {
		t.Fatalf("http entry must not need a CA: %s", why)
	}
	e.HealthPath = "/missing"
	if ok, _ := probeWith(t, "", e); ok {
		t.Fatal("http health path 404 must be unhealthy")
	}
}

// end to end through Reconcile: a live process registered as https is marked by the TLS probe
func TestReconcileUsesTLSProbeForHTTPS(t *testing.T) {
	pki := newTestPKI(t, time.Time{}, time.Time{})
	h, port := tlsServer(t, pki, 200)
	cfg := testCfg(t)
	cfg.CACert = pki.writeCA(t)
	r := New(cfg)
	hold := spawn(t, "hold", "tok-tls")
	if err := r.Register(Entry{Name: "gw", Host: h, Port: port, Protocol: "https", HealthPath: "/health", PID: hold.pid(), CmdToken: "tok-tls"}); err != nil {
		t.Fatal(err)
	}
	rep, err := r.Reconcile(context.Background(), ReconcileOptions{Grace: time.Minute})
	if err != nil || len(rep.Healthy) != 1 {
		t.Fatalf("%+v %v", rep, err)
	}
	// same entry, wrong CA configured: now unhealthy
	other := newTestPKI(t, time.Time{}, time.Time{})
	cfg.CACert = other.writeCA(t)
	r2 := New(cfg)
	rep, err = r2.Reconcile(context.Background(), ReconcileOptions{Grace: time.Minute})
	if err != nil || len(rep.Unhealthy) != 1 {
		t.Fatalf("wrong CA must mark the entry unhealthy: %+v %v", rep, err)
	}
}
