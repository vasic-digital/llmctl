package registry

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"syscall"
	"time"

	"digital.vasic.containers/pkg/network"
)

// PortRequest asks for a port for one service.
type PortRequest struct {
	Name       string   // service/instance key, e.g. "chat-fast", "decide-nli.2"
	Profile    string   // names the override variable; defaults to Name
	Documented int      // the profile's documented port (fixed strategy)
	Strategy   Strategy // overrides the configured strategy when set
}

// PortResult is the outcome of an allocation.
type PortResult struct {
	Name     string `json:"name"`
	Port     int    `json:"port"`
	Strategy string `json:"strategy"` // fixed | dynamic | explicit
	Source   string `json:"source"`   // documented | explicit | range | sticky
	Var      string `json:"var"`      // LLMCTL_PORT_<PROFILE>
	Sticky   bool   `json:"sticky"`
}

// PortTakenError is returned when a requested port is in use or held.
type PortTakenError struct {
	Name   string
	Port   int
	Var    string
	Holder string // other service holding the port, if known
}

func (e *PortTakenError) Error() string {
	why := "is already in use by another program"
	if e.Holder != "" {
		why = fmt.Sprintf("is already assigned to service %q", e.Holder)
	}
	return fmt.Sprintf("port %d for %q %s; set %s=<free port> (or %s=auto) to choose another, or LLMCTL_PORT_STRATEGY=dynamic",
		e.Port, e.Name, why, e.Var, e.Var)
}

// UsageError marks a request that is malformed rather than failed.
type UsageError struct{ Msg string }

func (e *UsageError) Error() string { return e.Msg }

func usagef(f string, a ...any) error { return &UsageError{fmt.Sprintf(f, a...)} }

type heldPort struct {
	Port int       `json:"port"`
	At   time.Time `json:"at"`
}

type portState struct {
	Held map[string]heldPort `json:"held"`
	Last map[string]int      `json:"last"` // sticky hints, survive release
}

// Ports assigns ports. The assignment itself - range walk and bind test - is
// the Containers pkg/network.PortAllocator; this type adds what that in-memory
// allocator lacks for llmctl: durable state shared by every llmctl process,
// serialised with a file lock, plus sticky reuse and the env-driven strategy.
type Ports struct {
	cfg Config
	get func(string) string
	now func() time.Time
}

func NewPorts(cfg Config, get func(string) string) *Ports {
	return &Ports{cfg: cfg, get: get, now: time.Now}
}

const portsLock = ".ports.lock"

var nameRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)

// localBindAddrs lists the addresses a free port must also be bindable on: the IPv4 and IPv6
// wildcards and every unicast address of every local interface (a variable so tests can inject).
// The Containers allocator only tests 127.0.0.1 (evidence/containers-gaps.md G9), so a service
// listening on 192.168.x.y:P, or on the wildcard of the other family, would otherwise go unnoticed.
var localBindAddrs = func() []string {
	out := []string{"0.0.0.0", "::"}
	as, err := net.InterfaceAddrs()
	if err != nil {
		return out
	}
	for _, a := range as {
		ipn, ok := a.(*net.IPNet)
		if !ok || ipn.IP.IsLoopback() || ipn.IP.IsMulticast() {
			continue
		}
		ip := ipn.IP.String()
		if ipn.IP.To4() == nil && ipn.IP.IsLinkLocalUnicast() {
			continue // a link-local IPv6 address needs a zone to bind; its port space is the wildcard's
		}
		out = append(out, ip)
	}
	return out
}

// bindTest proves a single port is free by actually binding it: on 127.0.0.1 through the
// Containers allocator, then on the wildcards and on every local interface address. Only a
// conflict (address in use / permission denied) means "taken"; an address the host cannot bind
// (not assigned, family unsupported) says nothing about the port and is skipped.
func bindTest(port int) error {
	if port < 1 || port > 65535 {
		return fmt.Errorf("port %d out of range", port)
	}
	if _, err := network.NewPortAllocator(port, port+1).Allocate("bind-test"); err != nil {
		return err
	}
	for _, addr := range localBindAddrs() {
		ln, err := net.Listen("tcp", net.JoinHostPort(addr, strconv.Itoa(port)))
		if err == nil {
			_ = ln.Close()
			continue
		}
		if errors.Is(err, syscall.EADDRINUSE) || errors.Is(err, syscall.EACCES) {
			return fmt.Errorf("port %d is in use on %s: %w", port, addr, err)
		}
	}
	return nil
}

func (p *Ports) stateFile() string { return filepath.Join(p.cfg.Dir(), "ports.json") }

func (p *Ports) load() (*portState, error) {
	st := &portState{Held: map[string]heldPort{}, Last: map[string]int{}}
	b, err := os.ReadFile(p.stateFile())
	if errors.Is(err, os.ErrNotExist) {
		return st, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read ports.json: %w", err)
	}
	if err := json.Unmarshal(b, st); err != nil {
		return nil, fmt.Errorf("%s is corrupt (%v); move it aside to start over", p.stateFile(), err)
	}
	if st.Held == nil {
		st.Held = map[string]heldPort{}
	}
	if st.Last == nil {
		st.Last = map[string]int{}
	}
	return st, nil
}

// save writes the state atomically (temp file in the same directory, fsync,
// rename) so a crash leaves the previous state, never a torn file.
func (p *Ports) save(st *portState) error {
	b, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(p.cfg.Dir(), "ports-*.json.tmp")
	if err != nil {
		return fmt.Errorf("write ports.json: %w", err)
	}
	name := tmp.Name()
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		os.Remove(name)
		return fmt.Errorf("write ports.json: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		os.Remove(name)
		return fmt.Errorf("sync ports.json: %w", err)
	}
	if err := tmp.Close(); err != nil {
		os.Remove(name)
		return err
	}
	if err := os.Rename(name, p.stateFile()); err != nil {
		os.Remove(name)
		return fmt.Errorf("commit ports.json: %w", err)
	}
	return nil
}

func (p *Ports) mutate(fn func(*portState) error) error {
	return withLock(p.cfg.Dir(), portsLock, true, func() error {
		st, err := p.load()
		if err != nil {
			return err
		}
		if err := fn(st); err != nil {
			return err
		}
		return p.save(st)
	})
}

func holderOf(st *portState, port int, except string) string {
	for n, h := range st.Held {
		if n != except && h.Port == port {
			return n
		}
	}
	return ""
}

// Allocate returns a port for req.Name and records it. Precedence: an
// explicit numeric LLMCTL_PORT_<PROFILE> always wins; "auto" selects the
// dynamic strategy for that profile; otherwise the global/request strategy.
func (p *Ports) Allocate(req PortRequest) (PortResult, error) {
	if err := validRowName(req.Name); err != nil { // C3-08: the same tenant grammar as Register
		return PortResult{}, err
	}
	profile := req.Profile
	if profile == "" {
		profile = req.Name
	}
	v := ProfileVar(profile)
	res := PortResult{Name: req.Name, Var: v}
	raw := p.get(v)

	strategy := p.cfg.Strategy
	if req.Strategy != "" {
		strategy = req.Strategy
	}
	explicit := 0
	switch {
	case raw == "auto":
		strategy = Dynamic
	case raw != "":
		n, err := strconv.Atoi(raw)
		if err != nil || n < 1 || n > 65535 || strconv.Itoa(n) != raw {
			return res, usagef("%s=%q: want a port number (1-65535) or auto", v, raw)
		}
		explicit = n
	}
	if explicit == 0 && strategy == Fixed && req.Documented <= 0 {
		return res, usagef("%q has no documented port for the fixed strategy: pass the documented port or set %s", req.Name, v)
	}

	err := p.mutate(func(st *portState) error {
		claim := func(port int, strategyName, source string) error {
			if h := holderOf(st, port, req.Name); h != "" {
				return &PortTakenError{Name: req.Name, Port: port, Var: v, Holder: h}
			}
			if err := bindTest(port); err != nil {
				return &PortTakenError{Name: req.Name, Port: port, Var: v}
			}
			st.Held[req.Name] = heldPort{Port: port, At: p.now()}
			res.Port, res.Strategy, res.Source = port, strategyName, source
			return nil
		}
		switch {
		case explicit > 0:
			return claim(explicit, "explicit", "explicit")
		case strategy == Fixed:
			return claim(req.Documented, "fixed", "documented")
		}
		// dynamic: sticky first
		// (only ports inside the configured range count: an earlier explicit or
		// documented assignment is not a dynamic hint)
		inRange := func(n int) bool { return n >= p.cfg.RangeLo && n <= p.cfg.RangeHi }
		cand := st.Held[req.Name].Port
		if !inRange(cand) {
			cand = st.Last[req.Name]
		}
		if inRange(cand) && holderOf(st, cand, req.Name) == "" && bindTest(cand) == nil {
			st.Held[req.Name] = heldPort{Port: cand, At: p.now()}
			res.Port, res.Strategy, res.Source, res.Sticky = cand, "dynamic", "sticky", true
			return nil
		}
		port, err := pickFromRange(st, req.Name, p.cfg.RangeLo, p.cfg.RangeHi)
		if err != nil {
			return err
		}
		st.Held[req.Name] = heldPort{Port: port, At: p.now()}
		st.Last[req.Name] = port
		res.Port, res.Strategy, res.Source = port, "dynamic", "range"
		return nil
	})
	if err != nil {
		return res, err
	}
	return res, nil
}

// pickFromRange walks the range with the Containers allocator, skipping every
// port held by another service (first pass: also other services' sticky hints,
// so a restarting service finds its port still free).
func pickFromRange(st *portState, name string, lo, hi int) (int, error) {
	for _, withHints := range []bool{true, false} {
		a := network.NewPortAllocator(lo, hi+1)
		for n, h := range st.Held {
			if n != name {
				a.MarkAllocated(h.Port, n)
			}
		}
		if withHints {
			for n, port := range st.Last {
				if n != name {
					a.MarkAllocated(port, "hint:"+n)
				}
			}
		}
		for {
			port, err := a.Allocate(name)
			if err != nil {
				break
			}
			// the Containers allocator proved 127.0.0.1 only; prove every other local address too
			if bindTest(port) == nil {
				return port, nil
			}
			a.MarkAllocated(port, "busy")
		}
	}
	return 0, fmt.Errorf("no free port in range %d-%d for %q (%d held by llmctl services; widen LLMCTL_PORT_RANGE)", lo, hi, name, len(st.Held))
}

// Release drops name's hold (the sticky hint stays); it reports whether a hold existed.
func (p *Ports) Release(name string) (bool, error) {
	had := false
	err := p.mutate(func(st *portState) error {
		if _, had = st.Held[name]; had {
			delete(st.Held, name)
		}
		return nil
	})
	return had, err
}

func (p *Ports) releaseIf(name string, port int) error {
	return p.mutate(func(st *portState) error {
		if h, ok := st.Held[name]; ok && h.Port == port {
			delete(st.Held, name)
		}
		return nil
	})
}

// Held returns name -> port for every current hold.
func (p *Ports) Held() (map[string]int, error) {
	out := map[string]int{}
	err := withLock(p.cfg.Dir(), portsLock, false, func() error {
		st, err := p.load()
		if err != nil {
			return err
		}
		for n, h := range st.Held {
			out[n] = h.Port
		}
		return nil
	})
	return out, err
}

// Prune drops holds older than grace whose port is not bound by anything
// (an allocation whose service never started or died without releasing).
func (p *Ports) Prune(grace time.Duration, now time.Time) (int, error) {
	n := 0
	err := p.mutate(func(st *portState) error {
		for name, h := range st.Held {
			if now.Sub(h.At) >= grace && bindTest(h.Port) == nil {
				delete(st.Held, name)
				n++
			}
		}
		return nil
	})
	return n, err
}
