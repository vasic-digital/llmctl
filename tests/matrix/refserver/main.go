//go:build ignore

// refserver: self-contained reference HTTPS test server for the client-by-call
// matrix harness (tests/matrix). It implements just enough of
// specs/009-jev-decision-models/contracts/openapi.yaml to prove that each CLIENT
// works. It is a STAND-IN: results obtained against it validate the HARNESS and
// must never be counted as evidence for the real decision gateway.
//
// Stdlib only (net/http, crypto/tls, crypto/x509). Build:
//
//	go build -o <tmp>/refserver tests/matrix/refserver/main.go
//
// Sub-commands:
//
//	refserver serve  [flags]            run the server
//	refserver gencerts DIR              generate CA + good/wronghost/expired/untrusted/altered leaves
//	refserver probe  [flags]            TLS probe client (negative transport tests)
package main

import (
	"bufio"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: refserver serve|gencerts|probe ...")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "serve":
		serve(os.Args[2:])
	case "gencerts":
		if len(os.Args) != 3 {
			fmt.Fprintln(os.Stderr, "usage: refserver gencerts DIR")
			os.Exit(2)
		}
		if err := genCerts(os.Args[2]); err != nil {
			fmt.Fprintln(os.Stderr, "gencerts:", err)
			os.Exit(1)
		}
	case "probe":
		probe(os.Args[2:])
	default:
		fmt.Fprintln(os.Stderr, "unknown sub-command", os.Args[1])
		os.Exit(2)
	}
}

// ---------------------------------------------------------------- certificates

func writePEM(path, typ string, der []byte, mode os.FileMode) error {
	return os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: typ, Bytes: der}), mode)
}

func newKey() *ecdsa.PrivateKey {
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		panic(err)
	}
	return k
}

func serial() *big.Int {
	n, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 100))
	return n
}

func mkCA(cn string) (*x509.Certificate, *ecdsa.PrivateKey, []byte) {
	k := newKey()
	_, lo, _ := net.ParseCIDR("127.0.0.0/8")
	_, p10, _ := net.ParseCIDR("10.0.0.0/8")
	_, p172, _ := net.ParseCIDR("172.16.0.0/12")
	_, p192, _ := net.ParseCIDR("192.168.0.0/16")
	_, l6, _ := net.ParseCIDR("::1/128")
	t := &x509.Certificate{
		SerialNumber: serial(), Subject: pkix.Name{CommonName: cn},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(24 * time.Hour * 30),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		MaxPathLenZero:              true,
		PermittedDNSDomains:         []string{"localhost", "matrix.test"},
		PermittedIPRanges:           []*net.IPNet{lo, p10, p172, p192, l6},
		PermittedDNSDomainsCritical: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, t, t, &k.PublicKey, k)
	if err != nil {
		panic(err)
	}
	c, _ := x509.ParseCertificate(der)
	return c, k, der
}

func mkLeaf(ca *x509.Certificate, cak *ecdsa.PrivateKey, dns []string, ips []string, notBefore, notAfter time.Time) ([]byte, *ecdsa.PrivateKey) {
	k := newKey()
	t := &x509.Certificate{
		SerialNumber: serial(), Subject: pkix.Name{CommonName: "refserver"},
		NotBefore: notBefore, NotAfter: notAfter,
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames: dns,
	}
	for _, s := range ips {
		t.IPAddresses = append(t.IPAddresses, net.ParseIP(s))
	}
	der, err := x509.CreateCertificate(rand.Reader, t, ca, &k.PublicKey, cak)
	if err != nil {
		panic(err)
	}
	return der, k
}

func writeLeaf(dir string, der []byte, k *ecdsa.PrivateKey) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	kd, _ := x509.MarshalECPrivateKey(k)
	if err := writePEM(filepath.Join(dir, "cert.pem"), "CERTIFICATE", der, 0o644); err != nil {
		return err
	}
	return writePEM(filepath.Join(dir, "key.pem"), "EC PRIVATE KEY", kd, 0o600)
}

func genCerts(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	ca, cak, cader := mkCA("refserver test CA")
	if err := writePEM(filepath.Join(dir, "ca.pem"), "CERTIFICATE", cader, 0o644); err != nil {
		return err
	}
	now := time.Now()
	good := []string{"localhost"}
	goodIPs := []string{"127.0.0.1", "127.0.0.2", "::1"}
	der, k := mkLeaf(ca, cak, good, goodIPs, now.Add(-time.Hour), now.Add(24*time.Hour*7))
	if err := writeLeaf(filepath.Join(dir, "good"), der, k); err != nil {
		return err
	}
	// SPKI pin (base64 sha256) of the good leaf, for browsers that cannot import a CA.
	leaf, _ := x509.ParseCertificate(der)
	sp := sha256.Sum256(leaf.RawSubjectPublicKeyInfo)
	if err := os.WriteFile(filepath.Join(dir, "good", "spki.b64"), []byte(base64.StdEncoding.EncodeToString(sp[:])+"\n"), 0o644); err != nil {
		return err
	}
	// host name not covered
	der, k = mkLeaf(ca, cak, []string{"other.matrix.test"}, []string{"10.9.9.9"}, now.Add(-time.Hour), now.Add(24*time.Hour*7))
	if err := writeLeaf(filepath.Join(dir, "wronghost"), der, k); err != nil {
		return err
	}
	// expired
	der, k = mkLeaf(ca, cak, good, goodIPs, now.Add(-48*time.Hour), now.Add(-24*time.Hour))
	if err := writeLeaf(filepath.Join(dir, "expired"), der, k); err != nil {
		return err
	}
	// untrusted: signed by a different CA the client does not have
	ca2, ca2k, _ := mkCA("rogue CA")
	der, k = mkLeaf(ca2, ca2k, good, goodIPs, now.Add(-time.Hour), now.Add(24*time.Hour*7))
	if err := writeLeaf(filepath.Join(dir, "untrusted"), der, k); err != nil {
		return err
	}
	// altered: valid cert whose signature bytes were flipped (still parses)
	der, k = mkLeaf(ca, cak, good, goodIPs, now.Add(-time.Hour), now.Add(24*time.Hour*7))
	alt := append([]byte(nil), der...)
	alt[len(alt)-5] ^= 0xff
	if _, err := x509.ParseCertificate(alt); err != nil {
		alt = append([]byte(nil), der...)
		alt[len(alt)-9] ^= 0x7f
	}
	if err := writeLeaf(filepath.Join(dir, "altered"), alt, k); err != nil {
		return err
	}
	// mismatched: good cert, someone else's key (server must refuse to start)
	_, k2 := mkLeaf(ca, cak, good, goodIPs, now.Add(-time.Hour), now.Add(24*time.Hour))
	if err := writeLeaf(filepath.Join(dir, "mismatched"), der, k2); err != nil {
		return err
	}
	return nil
}

// ------------------------------------------------------------------- listeners

// sourceLimitListener caps simultaneous connections per remote IP, shedding the
// excess before any TLS bytes are read; a wrapped conn resets non-TLS clients.
type sourceLimitListener struct {
	net.Listener
	cap  int
	mu   sync.Mutex
	open map[string]int
}

type limConn struct {
	net.Conn
	l      *sourceLimitListener
	ip     string
	once   sync.Once
	first  bool
	fmu    sync.Mutex
	closed bool
}

func (l *sourceLimitListener) Accept() (net.Conn, error) {
	for {
		c, err := l.Listener.Accept()
		if err != nil {
			return nil, err
		}
		host, _, _ := net.SplitHostPort(c.RemoteAddr().String())
		l.mu.Lock()
		if l.open[host] >= l.cap {
			l.mu.Unlock()
			reset(c)
			continue
		}
		l.open[host]++
		l.mu.Unlock()
		return &limConn{Conn: c, l: l, ip: host, first: true}, nil
	}
}

func reset(c net.Conn) {
	if tc, ok := c.(*net.TCPConn); ok {
		tc.SetLinger(0)
	}
	c.Close()
}

func (c *limConn) Read(b []byte) (int, error) {
	c.fmu.Lock()
	first := c.first
	c.first = false
	c.fmu.Unlock()
	if first {
		// plain HTTP (or anything that is not a TLS handshake record) is reset, never answered
		c.Conn.SetReadDeadline(time.Now().Add(5 * time.Second))
		n, err := c.Conn.Read(b)
		c.Conn.SetReadDeadline(time.Time{})
		if n > 0 && b[0] != 0x16 {
			reset(c.Conn)
			c.release()
			return 0, io.ErrClosedPipe
		}
		return n, err
	}
	return c.Conn.Read(b)
}

func (c *limConn) release() {
	c.once.Do(func() {
		c.l.mu.Lock()
		c.l.open[c.ip]--
		c.l.mu.Unlock()
	})
}

func (c *limConn) Close() error { c.release(); return c.Conn.Close() }

// ---------------------------------------------------------------------- server

type config struct {
	key        string
	budget     int
	bodyCap    int64
	profileMax int
	failLimit  int
	failWindow time.Duration
	mu         sync.Mutex
	failures   map[string][]time.Time
	counters   map[string]int
}

func (c *config) count(k string) {
	c.mu.Lock()
	c.counters[k]++
	c.mu.Unlock()
}

type errBody struct {
	Message   string `json:"message"`
	ErrorType string `json:"error_type"`
}

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func reqID() string {
	b := make([]byte, 8)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func fail(w http.ResponseWriter, status int, typ, msg string, extra map[string]string) {
	for k, v := range extra {
		w.Header().Set(k, v)
	}
	writeJSON(w, status, errBody{Message: msg, ErrorType: typ})
}

func (c *config) authOK(r *http.Request) bool {
	tok := ""
	if h := r.Header.Get("Authorization"); strings.HasPrefix(h, "Bearer ") {
		tok = strings.TrimPrefix(h, "Bearer ")
	} else if x := r.Header.Get("X-API-Key"); x != "" {
		tok = x
	}
	return tok != "" && subtle.ConstantTimeCompare([]byte(tok), []byte(c.key)) == 1
}

func srcIP(r *http.Request) string {
	h, _, _ := net.SplitHostPort(r.RemoteAddr)
	return h
}

// authenticate returns true when the request may proceed.
func (c *config) authenticate(w http.ResponseWriter, r *http.Request) bool {
	if c.authOK(r) {
		return true
	}
	ip := srcIP(r)
	now := time.Now()
	c.mu.Lock()
	var keep []time.Time
	for _, t := range c.failures[ip] {
		if now.Sub(t) < c.failWindow {
			keep = append(keep, t)
		}
	}
	keep = append(keep, now)
	c.failures[ip] = keep
	n := len(keep)
	c.mu.Unlock()
	if n > c.failLimit {
		fail(w, 429, "rate_limited", "Too many failed attempts.", map[string]string{"Retry-After": "5"})
		return false
	}
	fail(w, 401, "unauthorized", "Unauthorized.", map[string]string{"WWW-Authenticate": `Bearer realm="llmctl"`})
	return false
}

func methodNot(w http.ResponseWriter, allow string) {
	fail(w, 405, "method_not_allowed", "Method not allowed.", map[string]string{"Allow": allow})
}

func (c *config) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		c.count("req")
		w.Header().Set("x-llmctl-request-id", reqID())
		p := r.URL.Path
		sc := r.Header.Get("x-refserver-scenario")
		switch p {
		case "/healthz":
			if r.Method != http.MethodGet {
				methodNot(w, "GET")
				return
			}
			writeJSON(w, 200, map[string]string{"status": "ok"})
		case "/readyz":
			if r.Method != http.MethodGet {
				methodNot(w, "GET")
				return
			}
			if sc == "not_ready" || sc == "draining" {
				w.Header().Set("Retry-After", "1")
				writeJSON(w, 503, map[string]string{"status": "not_ready"})
				return
			}
			writeJSON(w, 200, map[string]string{"status": "ready"})
		case "/metrics":
			if !c.authenticate(w, r) {
				return
			}
			if r.Method != http.MethodGet {
				methodNot(w, "GET")
				return
			}
			c.mu.Lock()
			keys := make([]string, 0, len(c.counters))
			for k := range c.counters {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			var sb strings.Builder
			sb.WriteString("# HELP refserver_events_total Events by outcome.\n# TYPE refserver_events_total counter\n")
			for _, k := range keys {
				fmt.Fprintf(&sb, "refserver_events_total{outcome=%q} %d\n", k, c.counters[k])
			}
			c.mu.Unlock()
			w.Header().Set("Content-Type", "text/plain; version=0.0.4")
			io.WriteString(w, sb.String())
		case "/v1/models":
			if !c.authenticate(w, r) {
				return
			}
			if r.Method != http.MethodGet {
				methodNot(w, "GET")
				return
			}
			if sc == "no_ready_instance" || sc == "not_ready" || sc == "draining" {
				w.Header().Set("Retry-After", "1")
				fail(w, 503, "not_ready", "Not ready.", nil)
				return
			}
			// G-038: BOTH shapes in one body - the hosted SDKs' {models:[{name,description,release_date}]}
			// (one entry per accepted name) and the llmctl object/data listing.
			names := []string{"refprofile", "jev-latest", "jev-preview", "jev-1.13.0", "llmctl-refprofile"}
			models := make([]interface{}, 0, len(names))
			for _, n := range names {
				models = append(models, map[string]interface{}{"name": n, "description": "Reference decision profile.", "release_date": "2026-10-07"})
			}
			writeJSON(w, 200, map[string]interface{}{"object": "list", "models": models, "data": []interface{}{map[string]interface{}{
				"id": "refprofile", "aliases": []string{"jev-latest", "jev-preview", "jev-1.13.0", "llmctl-refprofile"},
				"protocol": "letter-logit", "status": "ready",
				"limits": map[string]interface{}{"max_options": c.profileMax, "score_levels": []int{2, 10}},
			}}})
		case "/v1/systemone":
			if !c.authenticate(w, r) {
				return
			}
			if r.Method != http.MethodPost {
				methodNot(w, "POST")
				return
			}
			c.systemOne(w, r, sc)
		default:
			if !c.authenticate(w, r) {
				return
			}
			fail(w, 404, "invalid_request", "Not found.", nil)
		}
	})
	return mux
}

func isObj(v interface{}) (map[string]interface{}, bool) {
	m, ok := v.(map[string]interface{})
	return m, ok
}

func textLen(v interface{}) int {
	switch t := v.(type) {
	case nil:
		return 0
	case string:
		return len(t)
	default:
		b, _ := json.Marshal(t)
		return len(b)
	}
}

func (c *config) systemOne(w http.ResponseWriter, r *http.Request, sc string) {
	if r.ContentLength > c.bodyCap {
		// Rejected before the body is read: answer first, then drain a bounded amount (lingering
		// close). Without the drain a client that sent "Connection: close" and is still writing gets
		// a TCP reset that destroys the 413 it never read (observed with python urllib and Go).
		fail(w, 413, "payload_too_large", "Payload too large.", nil)
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		io.Copy(io.Discard, io.LimitReader(r.Body, 8<<20))
		return
	}
	if !strings.HasPrefix(strings.ToLower(r.Header.Get("Content-Type")), "application/json") {
		fail(w, 400, "invalid_request", "Content-Type must be application/json.", nil)
		return
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, c.bodyCap+1))
	if err != nil {
		fail(w, 400, "invalid_request", "Unreadable body.", nil)
		return
	}
	if int64(len(raw)) > c.bodyCap {
		fail(w, 413, "payload_too_large", "Payload too large.", nil)
		return
	}
	var body interface{}
	if err := json.Unmarshal(raw, &body); err != nil {
		fail(w, 400, "invalid_request", "Malformed JSON.", nil)
		return
	}
	req, ok := isObj(body)
	if !ok {
		fail(w, 400, "invalid_request", "Body must be a JSON object.", nil)
		return
	}
	for k := range req {
		if k != "model" && k != "state" && k != "questions" {
			fail(w, 422, "validation_failed", "Unknown field.", nil)
			return
		}
	}
	state, hasState := req["state"]
	qs, qok := isObj(req["questions"])
	if !hasState || !qok || len(qs) < 1 || len(qs) > 32 {
		fail(w, 422, "validation_failed", "state and 1..32 questions are required.", nil)
		return
	}
	if m, has := req["model"]; has {
		ms, _ := m.(string)
		switch ms {
		case "jev-latest", "jev-preview", "jev-1.13.0", "llmctl-refprofile", "refprofile":
		default:
			fail(w, 422, "unknown_model", "Unknown model.", nil)
			return
		}
	}
	longest := 0
	type qa struct {
		name, typ string
		crit      interface{}
	}
	var qlist []qa
	names := make([]string, 0, len(qs))
	for n := range qs {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		q, ok := isObj(qs[n])
		if !ok {
			fail(w, 422, "validation_failed", "Question must be an object.", nil)
			return
		}
		typ, _ := q["type"].(string)
		for k := range q {
			if k != "type" && k != "instructions" && k != "criteria" {
				fail(w, 422, "validation_failed", "Unknown field in question.", nil)
				return
			}
		}
		if l := textLen(q["instructions"]); l > longest {
			longest = l
		}
		switch typ {
		case "noul":
		case "choice":
			cr, ok := isObj(q["criteria"])
			if !ok {
				fail(w, 422, "validation_failed", "choice requires criteria.", nil)
				return
			}
			if len(cr) > 255 {
				fail(w, 400, "invalid_request", "Too many options.", nil)
				return
			}
			if len(cr) < 2 || len(cr) > c.profileMax {
				fail(w, 422, "validation_failed", "Option count outside the profile limit.", nil)
				return
			}
		case "score":
			cr, ok := q["criteria"].([]interface{})
			if !ok || len(cr) < 2 || len(cr) > 10 {
				fail(w, 422, "validation_failed", "score requires 2..10 levels.", nil)
				return
			}
		default:
			fail(w, 422, "validation_failed", "Unknown question type.", nil)
			return
		}
		qlist = append(qlist, qa{n, typ, q["criteria"]})
	}
	trunc := false
	if textLen(state)+longest > c.budget {
		if sc == "truncate_on" && longest < c.budget/2 {
			trunc = true
		} else {
			fail(w, 422, "validation_failed", "State exceeds the profile budget.", nil)
			return
		}
	}
	switch sc {
	case "overloaded":
		fail(w, 529, "overloaded", "Temporarily overloaded.", map[string]string{"Retry-After": "1"})
		return
	case "not_ready", "draining", "no_ready_instance":
		fail(w, 503, "not_ready", "Not ready.", map[string]string{"Retry-After": "1"})
		return
	case "readout_failed":
		fail(w, 422, "readout_failed", "Backend readout unusable.", nil)
		return
	case "backend_failed":
		fail(w, 502, "backend_failed", "Backend failed.", nil)
		return
	}
	answers := map[string]interface{}{}
	for _, q := range qlist {
		switch q.typ {
		case "noul":
			answers[q.name] = map[string]interface{}{"type": "noul", "noul": 0.75}
		case "choice":
			cr := q.crit.(map[string]interface{})
			opts := make([]string, 0, len(cr))
			for o := range cr {
				opts = append(opts, o)
			}
			sort.Strings(opts)
			probs := map[string]float64{}
			rest := 0.5 / float64(len(opts)-1)
			for i, o := range opts {
				if i == 0 {
					probs[o] = 0.5
				} else {
					probs[o] = rest
				}
			}
			n := float64(len(opts))
			answers[q.name] = map[string]interface{}{"type": "choice", "choice": opts[0], "probabilities": probs,
				"confidence": (0.5 - 1/n) / (1 - 1/n)}
		case "score":
			cr := q.crit.([]interface{})
			probs := map[string]float64{}
			legend := map[string]interface{}{}
			n := len(cr)
			for i := 0; i < n; i++ {
				probs[strconv.Itoa(i)] = 1 / float64(n)
				legend[strconv.Itoa(i)] = cr[i]
			}
			answers[q.name] = map[string]interface{}{"type": "score", "score": float64(n-1) / 2, "legend": legend,
				"probabilities": probs, "confidence": 0.0}
		}
	}
	if trunc {
		w.Header().Set("x-llmctl-decide-truncated", "true")
	}
	c.count("systemone_ok")
	writeJSON(w, 200, map[string]interface{}{"model": "refserver-local-model", "answers": answers,
		"usage": map[string]int{"input_tokens": (textLen(state) + longest) / 4, "output_tokens": len(qlist)}})
}

func serve(args []string) {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	listen := fs.String("listen", "127.0.0.1:0", "address")
	portFile := fs.String("port-file", "", "write the chosen TLS port here")
	cert := fs.String("cert", "", "certificate PEM")
	keyf := fs.String("key", "", "private key PEM")
	enginePortFile := fs.String("engine-port-file", "", "start a loopback-only plain 'engine' listener, write its port here")
	budget := fs.Int("budget-chars", 4000, "state budget")
	bodyCap := fs.Int64("body-cap", 65536, "request body cap")
	connCap := fs.Int("conn-cap-per-source", 8, "max simultaneous connections per source IP")
	hdrTO := fs.Duration("header-timeout", 2*time.Second, "read header timeout")
	profMax := fs.Int("profile-max-options", 20, "profile option cap")
	failLimit := fs.Int("failed-auth-limit", 20, "failed auths per window per source before 429")
	failWindow := fs.Duration("failed-auth-window", 10*time.Second, "failed-auth counting window")
	fs.Parse(args)
	cfg := &config{key: os.Getenv("REFSERVER_KEY"), budget: *budget, bodyCap: *bodyCap, profileMax: *profMax,
		failLimit: *failLimit, failWindow: *failWindow, failures: map[string][]time.Time{}, counters: map[string]int{}}
	if cfg.key == "" {
		fmt.Fprintln(os.Stderr, "REFSERVER_KEY not set")
		os.Exit(2)
	}
	kp, err := tls.LoadX509KeyPair(*cert, *keyf)
	if err != nil {
		fmt.Fprintln(os.Stderr, "refusing to start: invalid certificate/key pair:", err)
		os.Exit(1)
	}
	tc := &tls.Config{
		Certificates: []tls.Certificate{kp}, MinVersion: tls.VersionTLS12,
		CipherSuites: []uint16{
			tls.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256, tls.TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
			tls.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256, tls.TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
			tls.TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256, tls.TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
		},
	}
	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		fmt.Fprintln(os.Stderr, "listen:", err)
		os.Exit(1)
	}
	if *portFile != "" {
		_, p, _ := net.SplitHostPort(ln.Addr().String())
		os.WriteFile(*portFile, []byte(p+"\n"), 0o644)
	}
	if *enginePortFile != "" {
		el, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			fmt.Fprintln(os.Stderr, "engine listen:", err)
			os.Exit(1)
		}
		_, p, _ := net.SplitHostPort(el.Addr().String())
		os.WriteFile(*enginePortFile, []byte(p+"\n"), 0o644)
		go func() {
			for {
				c, err := el.Accept()
				if err != nil {
					return
				}
				go func() { defer c.Close(); bufio.NewReader(c).ReadString('\n'); io.WriteString(c, "engine-internal\n") }()
			}
		}()
	}
	srv := &http.Server{
		Handler: cfg.handler(), ReadHeaderTimeout: *hdrTO, ReadTimeout: 4 * time.Second,
		WriteTimeout: 10 * time.Second, IdleTimeout: 5 * time.Second,
		TLSConfig: tc,
	}
	lim := &sourceLimitListener{Listener: ln, cap: *connCap, open: map[string]int{}}
	fmt.Fprintln(os.Stderr, "refserver listening", ln.Addr())
	if err := srv.Serve(tls.NewListener(lim, tc)); err != nil {
		fmt.Fprintln(os.Stderr, "serve:", err)
		os.Exit(1)
	}
}

// ----------------------------------------------------------------------- probe

func probe(args []string) {
	fs := flag.NewFlagSet("probe", flag.ExitOnError)
	addr := fs.String("addr", "", "host:port")
	cafile := fs.String("cacert", "", "CA PEM")
	sni := fs.String("servername", "localhost", "server name to verify")
	maxv := fs.String("maxver", "", "highest TLS version to offer: 1.0|1.1|1.2|1.3")
	minv := fs.String("minver", "", "lowest TLS version to offer")
	ciphers := fs.String("ciphers", "", "cbc = offer only an ECDHE CBC-SHA1 suite (weak)")
	fs.Parse(args)
	ver := map[string]uint16{"1.0": tls.VersionTLS10, "1.1": tls.VersionTLS11, "1.2": tls.VersionTLS12, "1.3": tls.VersionTLS13}
	cfg := &tls.Config{ServerName: *sni}
	if *cafile != "" {
		pool := x509.NewCertPool()
		b, err := os.ReadFile(*cafile)
		if err != nil || !pool.AppendCertsFromPEM(b) {
			fmt.Println("RESULT error bad-cacert")
			os.Exit(2)
		}
		cfg.RootCAs = pool
	}
	if *maxv != "" {
		cfg.MaxVersion = ver[*maxv]
		cfg.MinVersion = tls.VersionTLS10
	}
	if *minv != "" {
		cfg.MinVersion = ver[*minv]
	}
	if *ciphers == "cbc" {
		cfg.MaxVersion = tls.VersionTLS12
		cfg.CipherSuites = []uint16{tls.TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA, tls.TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA}
	}
	d := &net.Dialer{Timeout: 8 * time.Second}
	conn, err := tls.DialWithDialer(d, "tcp", *addr, cfg)
	if err != nil {
		fmt.Println("RESULT refused", err)
		os.Exit(0)
	}
	st := conn.ConnectionState()
	fmt.Printf("RESULT connected version=%s cipher=%s\n", tls.VersionName(st.Version), tls.CipherSuiteName(st.CipherSuite))
	conn.Close()
}
