package registry

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"time"

	"digital.vasic.containers/pkg/health"
)

// The Containers health.CheckHTTP builds its client with the default TLS configuration - no CA
// pool - so a service behind llmctl's own CA (the gateway) cannot be certified by it, and until
// now https entries were certified by a bare TCP dial (evidence/containers-gaps.md G10). This file
// is the thin adapter that closes the gap: a health.CheckFunc, over the package's own
// HealthTarget / HealthResult types, that does what CheckHTTP does (GET, no redirects, 2xx-3xx is
// healthy) but over a TLS handshake verified against a given pool. The upstream change that makes
// it deletable is in specs/009-jev-decision-models/evidence/containers-upstream/.

// loadCAPool reads a PEM bundle of CA certificates.
func loadCAPool(path string) (*x509.CertPool, error) {
	if path == "" {
		return nil, errors.New("no CA certificate is configured (set LLMCTL_CACERT or LLMCTL_HOME) so an https service cannot be verified")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("cannot read the CA certificate %s (LLMCTL_CACERT): %v", path, err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(b) {
		return nil, fmt.Errorf("%s (LLMCTL_CACERT) holds no PEM certificate", path)
	}
	return pool, nil
}

// TLSCheck returns a health.CheckFunc that certifies an https target: the TLS handshake must
// verify against pool (chain, validity period, host name or IP), and when the target has a Path,
// a GET of it must answer 2xx or 3xx. A nil pool never verifies - it is unhealthy, not "trust
// everything".
func TLSCheck(pool *x509.CertPool) health.CheckFunc {
	return func(ctx context.Context, t health.HealthTarget) *health.HealthResult {
		start := time.Now()
		res := func(ok bool, err string, d map[string]string) *health.HealthResult {
			return &health.HealthResult{Target: t.Name, Healthy: ok, Duration: time.Since(start), Error: err, Timestamp: start, Details: d}
		}
		if pool == nil {
			return res(false, "no CA pool: an https target cannot be verified", nil)
		}
		timeout := t.Timeout
		if timeout <= 0 {
			timeout = 5 * time.Second
		}
		ctx, cancel := context.WithTimeout(ctx, timeout)
		defer cancel()
		cfg := &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12, ServerName: t.Host}
		addr := net.JoinHostPort(t.Host, t.Port)

		if t.Path == "" { // handshake only
			d := tls.Dialer{NetDialer: &net.Dialer{}, Config: cfg}
			c, err := d.DialContext(ctx, "tcp", addr)
			if err != nil {
				return res(false, "TLS handshake failed: "+err.Error(), nil)
			}
			_ = c.Close()
			return res(true, "", map[string]string{"url": "https://" + addr})
		}

		tr := &http.Transport{TLSClientConfig: cfg, DisableKeepAlives: true, TLSHandshakeTimeout: timeout}
		defer tr.CloseIdleConnections()
		client := &http.Client{Transport: tr, Timeout: timeout,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
		url := "https://" + addr + t.Path
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return res(false, "failed to create request: "+err.Error(), nil)
		}
		resp, err := client.Do(req)
		if err != nil {
			return res(false, "https request failed: "+err.Error(), map[string]string{"url": url})
		}
		defer resp.Body.Close()
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
		d := map[string]string{"url": url, "status_code": strconv.Itoa(resp.StatusCode)}
		if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusBadRequest {
			return res(false, fmt.Sprintf("unhealthy status code: %d", resp.StatusCode), d)
		}
		return res(true, "", d)
	}
}
