package gateway

import (
	"context"
	"errors"
	"net"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

// KindDecide is the resolver kind of decision instances.
const KindDecide = "decide"

// Endpoint is one decision instance: where it listens, the internal key it expects, and whether
// it is currently healthy.
type Endpoint struct {
	URL      string
	Key      string
	Healthy  bool
	Instance string // optional label ("decide-tiny", "decide-tiny.2")
	// FromRegistry marks an endpoint taken from the service registry: only then can a 404/405 be a
	// stale entry that heals (B3-06). A statically configured endpoint that answers 404 is a fixed
	// misconfiguration.
	FromRegistry bool
}

// Resolver finds the instances serving a profile. The registry adapter (internal/registry) plugs
// in here; StaticResolver is the catalog/env fed implementation. Order is significant: the first
// healthy endpoint is the profile's primary instance.
type Resolver interface {
	Resolve(kind, profile string) ([]Endpoint, error)
}

// StaticResolver is an in-memory Resolver.
type StaticResolver struct {
	mu sync.RWMutex
	m  map[string][]Endpoint
}

// NewStaticResolver returns an empty resolver.
func NewStaticResolver() *StaticResolver { return &StaticResolver{m: map[string][]Endpoint{}} }

// Set replaces the endpoints of (kind, profile).
func (r *StaticResolver) Set(kind, profile string, eps ...Endpoint) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.m[kind+"/"+profile] = append([]Endpoint(nil), eps...)
}

// Resolve returns a copy of the endpoints (empty, not an error, for an unknown profile).
func (r *StaticResolver) Resolve(kind, profile string) ([]Endpoint, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return append([]Endpoint(nil), r.m[kind+"/"+profile]...), nil
}

// EndpointVar names the env var that lists a profile's instance URLs (comma separated).
func EndpointVar(profile string) string {
	return "LLMCTL_DECIDE_ENDPOINT_" + strings.ToUpper(strings.ReplaceAll(profile, "-", "_"))
}

// PortVar names the env var that rebinds a profile's port on this host (same rule as the bash side,
// lib/catalog.sh catalog_port_override_env_name).
func PortVar(profile string) string {
	return "LLMCTL_PORT_" + strings.ToUpper(strings.ReplaceAll(profile, "-", "_"))
}

// StaticResolverFromEnv builds a resolver from LLMCTL_DECIDE_ENDPOINT_<PROFILE> (loopback URLs);
// a profile without the variable is assumed at http://127.0.0.1:<port> where <port> is LLMCTL_PORT_<PROFILE>
// when that is a valid port (1-65535), else the catalog port (when it has one).
// Instances are presumed healthy: the real health comes from the registry adapter.
func StaticResolverFromEnv(specs []ProfileSpec, get func(string) string) *StaticResolver {
	r := NewStaticResolver()
	for _, s := range specs {
		var urls []string
		for _, u := range strings.Split(get(EndpointVar(s.ID)), ",") {
			if u = strings.TrimSpace(u); u != "" {
				urls = append(urls, u)
			}
		}
		if len(urls) == 0 {
			// LLMCTL_PORT_<PROFILE> (host-local rebind, honoured by the bash side) beats the catalog
			// port; an invalid value (non-numeric, <1, >65535, "auto") is ignored.
			port := s.Port
			if p, err := strconv.Atoi(strings.TrimSpace(get(PortVar(s.ID)))); err == nil && p >= 1 && p <= 65535 {
				port = p
			}
			if port > 0 {
				urls = []string{"http://127.0.0.1:" + itoa(port)}
			}
		}
		var eps []Endpoint
		for i, u := range urls {
			inst := s.ID
			if i > 0 {
				inst += "." + itoa(i+1)
			}
			eps = append(eps, Endpoint{URL: u, Healthy: true, Instance: inst})
		}
		r.Set(KindDecide, s.ID, eps...)
	}
	return r
}

func itoa(i int) string {
	if i == 0 {
		return "0"
	}
	var b []byte
	for ; i > 0; i /= 10 {
		b = append([]byte{byte('0' + i%10)}, b...)
	}
	return string(b)
}

// checkLoopback refuses any engine URL that is not http(s) on a loopback host without userinfo.
// Engines are reached only over loopback; the host is never taken from a request.
func checkLoopback(raw string) error {
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil || u.Host == "" {
		return errors.New("gateway: engine endpoint must be an http(s) loopback URL")
	}
	h := u.Hostname()
	if h == "localhost" {
		return nil
	}
	if ip := net.ParseIP(h); ip != nil && ip.IsLoopback() {
		return nil
	}
	return errors.New("gateway: engine endpoint must be on a loopback address")
}

// ProbeResolver wraps a Resolver and overrides Healthy with a short TCP connect probe (cached for
// TTL per address), so an instance that is not listening yields 503 not_ready rather than 502.
// The registry adapter, which knows real health, replaces it.
type ProbeResolver struct {
	Inner   Resolver
	Timeout time.Duration
	TTL     time.Duration

	now  func() time.Time
	dial func(network, addr string, d time.Duration) (net.Conn, error)
	mu   sync.Mutex
	seen map[string]probeResult
}

type probeResult struct {
	at time.Time
	ok bool
}

// NewProbeResolver wraps inner.
func NewProbeResolver(inner Resolver, timeout, ttl time.Duration) *ProbeResolver {
	return &ProbeResolver{Inner: inner, Timeout: timeout, TTL: ttl, now: time.Now, dial: net.DialTimeout, seen: map[string]probeResult{}}
}

// Resolve implements Resolver.
func (p *ProbeResolver) Resolve(kind, profile string) ([]Endpoint, error) {
	eps, err := p.Inner.Resolve(kind, profile)
	if err != nil {
		return nil, err
	}
	for i := range eps {
		if eps[i].Healthy {
			eps[i].Healthy = p.reachable(eps[i].URL)
		}
	}
	return eps, nil
}

func (p *ProbeResolver) reachable(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return false
	}
	host := u.Host
	if u.Port() == "" {
		port := "80"
		if u.Scheme == "https" {
			port = "443"
		}
		host = net.JoinHostPort(u.Hostname(), port)
	}
	now := p.now()
	p.mu.Lock()
	if r, ok := p.seen[host]; ok && now.Sub(r.at) < p.TTL {
		p.mu.Unlock()
		return r.ok
	}
	p.mu.Unlock()
	c, err := p.dial("tcp", host, p.Timeout)
	ok := err == nil
	if ok {
		_ = c.Close()
	}
	p.mu.Lock()
	p.seen[host] = probeResult{at: now, ok: ok}
	p.mu.Unlock()
	return ok
}

// newLoopbackDialer returns a DialContext that connects ONLY to loopback addresses (review-2 B-13).
// A literal IP must itself be loopback; a name (in practice "localhost") is resolved here and only
// its loopback answers are used - if there are none the dial is refused - so the internal key and
// the state can never travel to a host that /etc/hosts or a resolver pointed somewhere else.
// lookup nil = the system resolver; tests inject their own.
func newLoopbackDialer(lookup func(ctx context.Context, host string) ([]net.IPAddr, error)) func(ctx context.Context, network, addr string) (net.Conn, error) {
	if lookup == nil {
		lookup = net.DefaultResolver.LookupIPAddr
	}
	d := &net.Dialer{Timeout: 10 * time.Second}
	return func(ctx context.Context, network, addr string) (net.Conn, error) {
		host, port, err := net.SplitHostPort(addr)
		if err != nil {
			return nil, err
		}
		if ip := net.ParseIP(host); ip != nil {
			if !ip.IsLoopback() {
				return nil, errors.New("gateway: refusing a non-loopback engine address")
			}
			return d.DialContext(ctx, network, addr)
		}
		ips, err := lookup(ctx, host)
		if err != nil {
			return nil, err
		}
		var lastErr error = errors.New("gateway: the engine host name has no loopback address")
		for _, ia := range ips {
			if !ia.IP.IsLoopback() {
				continue
			}
			c, err := d.DialContext(ctx, network, net.JoinHostPort(ia.IP.String(), port))
			if err == nil {
				return c, nil
			}
			lastErr = err
		}
		return nil, lastErr
	}
}
