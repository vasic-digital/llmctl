// Package probecore is the logic of the static vantage-probe binary that runs
// INSIDE the second-network-location container (FR-064, FR-073). It lives in a
// library so it is unit-testable in-process; the binary is a thin wrapper.
// Everything here uses only the standard library so the probe compiles to a
// fully static (CGO_ENABLED=0) binary that needs no libc in the image.
package probecore

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// maxBody bounds the response body echoed back in a result.
const maxBody = 64 * 1024

// HTTPRequest describes one probe call.
type HTTPRequest struct {
	URL        string
	CAPEM      []byte // PEM bundle to trust; empty means "no roots" (every TLS verify fails)
	Method     string
	Headers    map[string]string
	Body       string
	Timeout    time.Duration
	ServerName string // optional SNI/verification name override
}

// HTTPResult is the structured outcome (JSON-encoded by the binary).
type HTTPResult struct {
	URL           string `json:"url"`
	TLS           bool   `json:"tls"`
	Status        int    `json:"status"`
	TLSVerified   bool   `json:"tls_verified"`
	TLSVersion    string `json:"tls_version,omitempty"`
	TLSError      string `json:"tls_error,omitempty"`
	PeerAddr      string `json:"peer_addr,omitempty"`
	LocalAddr     string `json:"local_addr,omitempty"`
	Body          string `json:"body,omitempty"`
	BodyTruncated bool   `json:"body_truncated,omitempty"`
	Error         string `json:"error,omitempty"`
	// ErrorClass is one of "", "tls_verify", "tls", "connect", "timeout", "http".
	ErrorClass string `json:"error_class,omitempty"`
}

// HTTP performs the request, verifying TLS against req.CAPEM (never insecure).
func HTTP(ctx context.Context, req HTTPRequest) HTTPResult {
	res := HTTPResult{URL: req.URL}
	u, err := url.Parse(req.URL)
	if err != nil || u.Host == "" {
		res.Error, res.ErrorClass = fmt.Sprintf("bad url %q", req.URL), "http"
		return res
	}
	res.TLS = u.Scheme == "https"
	if req.Method == "" {
		req.Method = http.MethodGet
	}
	if req.Timeout <= 0 {
		req.Timeout = 10 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, req.Timeout)
	defer cancel()

	pool := x509.NewCertPool()
	if len(req.CAPEM) > 0 {
		pool.AppendCertsFromPEM(req.CAPEM)
	}
	name := req.ServerName
	if name == "" {
		name = u.Hostname()
	}
	tr := &http.Transport{
		DisableKeepAlives: true,
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			c, err := (&net.Dialer{}).DialContext(ctx, network, addr)
			if err == nil {
				res.PeerAddr, res.LocalAddr = c.RemoteAddr().String(), c.LocalAddr().String()
			}
			return c, err
		},
		DialTLSContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			c, err := (&net.Dialer{}).DialContext(ctx, network, addr)
			if err != nil {
				return nil, err
			}
			res.PeerAddr, res.LocalAddr = c.RemoteAddr().String(), c.LocalAddr().String()
			tc := tls.Client(c, &tls.Config{RootCAs: pool, ServerName: name, MinVersion: tls.VersionTLS12})
			if err := tc.HandshakeContext(ctx); err != nil {
				_ = c.Close()
				res.TLSVerified = false
				res.TLSError = err.Error()
				return nil, err
			}
			res.TLSVerified = true
			res.TLSVersion = tlsVersion(tc.ConnectionState().Version)
			return tc, nil
		},
	}
	defer tr.CloseIdleConnections()
	var body io.Reader
	if req.Body != "" {
		body = strings.NewReader(req.Body)
	}
	hr, err := http.NewRequestWithContext(ctx, req.Method, req.URL, body)
	if err != nil {
		res.Error, res.ErrorClass = err.Error(), "http"
		return res
	}
	for k, v := range req.Headers {
		hr.Header.Set(k, v)
	}
	resp, err := (&http.Client{Transport: tr, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}).Do(hr)
	if err != nil {
		res.Error, res.ErrorClass = err.Error(), classify(err, res)
		return res
	}
	defer resp.Body.Close()
	res.Status = resp.StatusCode
	b, _ := io.ReadAll(io.LimitReader(resp.Body, maxBody+1))
	if len(b) > maxBody {
		b, res.BodyTruncated = b[:maxBody], true
	}
	res.Body = string(b)
	return res
}

func classify(err error, res HTTPResult) string {
	var ua x509.UnknownAuthorityError
	var ci x509.CertificateInvalidError
	var he x509.HostnameError
	switch {
	case errors.As(err, &ua), errors.As(err, &ci), errors.As(err, &he):
		return "tls_verify"
	case res.TLSError != "":
		return "tls"
	case errors.Is(err, context.DeadlineExceeded):
		return "timeout"
	}
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return "timeout"
	}
	return "connect"
}

func tlsVersion(v uint16) string {
	switch v {
	case tls.VersionTLS12:
		return "TLS1.2"
	case tls.VersionTLS13:
		return "TLS1.3"
	}
	return fmt.Sprintf("0x%04x", v)
}

// PortResult is one TCP reachability observation.
type PortResult struct {
	Port      int    `json:"port"`
	Reachable bool   `json:"reachable"`
	LocalAddr string `json:"local_addr,omitempty"`
	Error     string `json:"error,omitempty"`
}

// DialResult is the outcome of DialPorts.
type DialResult struct {
	Host      string       `json:"host"`
	Results   []PortResult `json:"results"`
	Reachable []int        `json:"reachable"`
}

// DialPorts TCP-connects to host:port for each port (sequentially, bounded).
func DialPorts(ctx context.Context, host string, ports []int, timeout time.Duration) DialResult {
	if timeout <= 0 {
		timeout = 2 * time.Second
	}
	out := DialResult{Host: host, Results: []PortResult{}, Reachable: []int{}}
	for _, p := range ports {
		pr := PortResult{Port: p}
		d := net.Dialer{Timeout: timeout}
		c, err := d.DialContext(ctx, "tcp", net.JoinHostPort(host, strconv.Itoa(p)))
		if err != nil {
			pr.Error = err.Error()
		} else {
			pr.Reachable, pr.LocalAddr = true, c.LocalAddr().String()
			_ = c.Close()
			out.Reachable = append(out.Reachable, p)
		}
		out.Results = append(out.Results, pr)
	}
	return out
}

// ParsePorts parses "a,b,c" into ints (1..65535).
func ParsePorts(s string) ([]int, error) {
	var out []int
	for _, f := range strings.Split(s, ",") {
		f = strings.TrimSpace(f)
		if f == "" {
			continue
		}
		n, err := strconv.Atoi(f)
		if err != nil || n < 1 || n > 65535 {
			return nil, fmt.Errorf("bad port %q", f)
		}
		out = append(out, n)
	}
	if len(out) == 0 {
		return nil, errors.New("no ports given")
	}
	return out, nil
}

// Route is one /proc/net/route row.
type Route struct {
	Iface   string `json:"iface"`
	Dest    string `json:"dest"`
	Gateway string `json:"gateway"`
	Mask    string `json:"mask"`
}

// Info is what the container knows about its own network position.
type Info struct {
	Addrs          []string `json:"addrs"` // IPv4, loopback excluded
	Routes         []Route  `json:"routes"`
	DefaultGateway string   `json:"default_gateway,omitempty"`
}

// ParseRoutes parses the text of /proc/net/route.
func ParseRoutes(text string) []Route {
	var out []Route
	for i, ln := range strings.Split(text, "\n") {
		f := strings.Fields(ln)
		if i == 0 || len(f) < 8 {
			continue
		}
		out = append(out, Route{Iface: f[0], Dest: hexIP(f[1]), Gateway: hexIP(f[2]), Mask: hexIP(f[7])})
	}
	return out
}

// hexIP decodes /proc/net/route's little-endian hex IPv4 ("0202000A" = 10.0.2.2).
func hexIP(h string) string {
	b, err := hex.DecodeString(h)
	if err != nil || len(b) != 4 {
		return ""
	}
	return net.IPv4(b[3], b[2], b[1], b[0]).String()
}

// Gather collects Info from the live container.
func Gather() Info {
	in := Info{Addrs: []string{}, Routes: []Route{}}
	if as, err := net.InterfaceAddrs(); err == nil {
		for _, a := range as {
			if ipn, ok := a.(*net.IPNet); ok && !ipn.IP.IsLoopback() && ipn.IP.To4() != nil {
				in.Addrs = append(in.Addrs, ipn.IP.String())
			}
		}
	}
	sort.Strings(in.Addrs)
	if b, err := os.ReadFile("/proc/net/route"); err == nil {
		in.Routes = ParseRoutes(string(b))
	}
	for _, r := range in.Routes {
		if r.Dest == "0.0.0.0" && r.Gateway != "" {
			in.DefaultGateway = r.Gateway
			break
		}
	}
	return in
}

// Hold blocks until SIGTERM/SIGINT or max elapses (a leaked container ends by itself).
func Hold(max time.Duration, out io.Writer) {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGTERM, syscall.SIGINT)
	fmt.Fprintln(out, "vantage-probe: holding")
	select {
	case <-ch:
	case <-time.After(max):
	}
}

// Main is the dispatch of the binary: hold | info | http | dial. It returns the
// process exit code; results are single-line JSON on stdout.
func Main(args []string, stdout, stderr io.Writer, enc func(io.Writer, any) error) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "usage: vantage-probe hold|info|http|dial [flags]")
		return 2
	}
	switch args[0] {
	case "hold":
		max := time.Hour
		if len(args) >= 3 && args[1] == "--max" {
			if d, err := time.ParseDuration(args[2]); err == nil {
				max = d
			}
		}
		Hold(max, stdout)
		return 0
	case "info":
		_ = enc(stdout, Gather())
		return 0
	case "http":
		req, code := parseHTTPArgs(args[1:], stderr)
		if code != 0 {
			return code
		}
		_ = enc(stdout, HTTP(context.Background(), req))
		return 0
	case "dial":
		host, ports, to, code := parseDialArgs(args[1:], stderr)
		if code != 0 {
			return code
		}
		_ = enc(stdout, DialPorts(context.Background(), host, ports, to))
		return 0
	}
	fmt.Fprintf(stderr, "vantage-probe: unknown command %q\n", args[0])
	return 2
}

// RequestFile is the JSON a caller leaves in the bind-mounted probe directory so that headers (an
// Authorization bearer) and the body never appear on the process argv.
type RequestFile struct {
	Headers map[string]string `json:"headers,omitempty"`
	Body    string            `json:"body,omitempty"`
}

func parseHTTPArgs(a []string, stderr io.Writer) (HTTPRequest, int) {
	var req HTTPRequest
	req.Headers = map[string]string{}
	for i := 0; i < len(a); i++ {
		next := func() (string, bool) {
			if i+1 >= len(a) {
				fmt.Fprintf(stderr, "vantage-probe: %s needs a value\n", a[i])
				return "", false
			}
			i++
			return a[i], true
		}
		var v string
		var ok bool
		switch a[i] {
		case "--url":
			if v, ok = next(); !ok {
				return req, 2
			}
			req.URL = v
		case "--ca-pem-hex":
			if v, ok = next(); !ok {
				return req, 2
			}
			b, err := hex.DecodeString(v)
			if err != nil {
				fmt.Fprintln(stderr, "vantage-probe: bad --ca-pem-hex")
				return req, 2
			}
			req.CAPEM = b
		case "--method":
			if v, ok = next(); !ok {
				return req, 2
			}
			req.Method = v
		case "--header":
			if v, ok = next(); !ok {
				return req, 2
			}
			k, val, found := strings.Cut(v, ":")
			if !found {
				fmt.Fprintln(stderr, "vantage-probe: --header wants Name:Value")
				return req, 2
			}
			req.Headers[strings.TrimSpace(k)] = strings.TrimSpace(val)
		case "--body":
			if v, ok = next(); !ok {
				return req, 2
			}
			req.Body = v
		case "--request-file":
			if v, ok = next(); !ok {
				return req, 2
			}
			b, err := os.ReadFile(v)
			if err != nil {
				fmt.Fprintf(stderr, "vantage-probe: --request-file: %v\n", err)
				return req, 2
			}
			var rf RequestFile
			if err := json.Unmarshal(b, &rf); err != nil {
				fmt.Fprintf(stderr, "vantage-probe: --request-file is not valid JSON: %v\n", err)
				return req, 2
			}
			for k, val := range rf.Headers {
				req.Headers[k] = val
			}
			if rf.Body != "" {
				req.Body = rf.Body
			}
		case "--server-name":
			if v, ok = next(); !ok {
				return req, 2
			}
			req.ServerName = v
		case "--timeout":
			if v, ok = next(); !ok {
				return req, 2
			}
			d, err := time.ParseDuration(v)
			if err != nil {
				fmt.Fprintln(stderr, "vantage-probe: bad --timeout")
				return req, 2
			}
			req.Timeout = d
		default:
			fmt.Fprintf(stderr, "vantage-probe http: unknown flag %q\n", a[i])
			return req, 2
		}
	}
	if req.URL == "" {
		fmt.Fprintln(stderr, "vantage-probe http: --url is required")
		return req, 2
	}
	return req, 0
}

func parseDialArgs(a []string, stderr io.Writer) (string, []int, time.Duration, int) {
	var host, ports string
	to := 2 * time.Second
	for i := 0; i+1 < len(a); i += 2 {
		switch a[i] {
		case "--host":
			host = a[i+1]
		case "--ports":
			ports = a[i+1]
		case "--timeout":
			if d, err := time.ParseDuration(a[i+1]); err == nil {
				to = d
			}
		default:
			fmt.Fprintf(stderr, "vantage-probe dial: unknown flag %q\n", a[i])
			return "", nil, 0, 2
		}
	}
	ps, err := ParsePorts(ports)
	if host == "" || err != nil {
		fmt.Fprintln(stderr, "vantage-probe dial: --host and valid --ports are required")
		return "", nil, 0, 2
	}
	return host, ps, to, 0
}
