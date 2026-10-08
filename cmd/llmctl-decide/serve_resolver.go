package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"sync"
	"time"

	"github.com/vasic-digital/llmctl/internal/gateway"
	"github.com/vasic-digital/llmctl/internal/registry"
)

// Resolver selection (LLMCTL_DECIDE_RESOLVER):
//
//	registry  engines come from the service registry (the engines published by `llmctl up`), health
//	          from the registry; the gateway follows registry changes without a restart
//	static    LLMCTL_DECIDE_ENDPOINT_<PROFILE> / catalog ports, probed with a TCP connect
//	auto      (default) decided PER PROFILE on every request: the registry when it holds a healthy
//	          entry for that profile, else the static endpoint (a mixed deployment keeps both)
const resolverVar = "LLMCTL_DECIDE_RESOLVER"

// registryIntervalVar is the poll interval at which the gateway follows registry changes.
const registryIntervalVar = "LLMCTL_DECIDE_REGISTRY_INTERVAL"

// registerWaitVar is how long the unit hooks wait for a loading engine to answer (seconds).
const registerWaitVar = "LLMCTL_REGISTER_WAIT"

// The gateway runs the registry reconciler in-process (G-057), once per registry (an flock owner).
//
//	LLMCTL_DECIDE_RECONCILE_INTERVAL  seconds between reconcile passes (default 5; a positive number)
//	LLMCTL_DECIDE_RECONCILE_GRACE     seconds an unhealthy entry is kept before removal (default 30; a non-negative number)
const (
	reconcileIntervalVar = "LLMCTL_DECIDE_RECONCILE_INTERVAL"
	reconcileGraceVar    = "LLMCTL_DECIDE_RECONCILE_GRACE"
	defaultReconcileSecs = 5.0
	defaultGraceSecs     = 30.0
)

var secondsRE = regexp.MustCompile(`^[0-9]+(\.[0-9]+)?$`)

// parseSeconds strictly parses a plain decimal number of seconds (no sign, exponent, unit, hex,
// inf/nan); min/max bound it (min exclusive when minExcl).
func parseSeconds(name, v string, def, max float64, minExcl bool) (time.Duration, error) {
	if v == "" {
		return time.Duration(def * float64(time.Second)), nil
	}
	f, err := strconv.ParseFloat(v, 64)
	if !secondsRE.MatchString(v) || err != nil || f > max || (minExcl && f <= 0) {
		low := "a non-negative"
		if minExcl {
			low = "a positive"
		}
		return 0, fmt.Errorf("%s=%q: want %s number of seconds (at most %g), e.g. 5", name, v, low, max)
	}
	return time.Duration(f * float64(time.Second)), nil
}

// serveRegistry is the gateway's link to the registry: the resolver it routes by (nil in static
// mode) and the registry the gateway publishes itself in (nil when there is no usable state dir).
type serveRegistry struct {
	reg  *registry.Registry
	res  *gateway.RegistryResolver
	mode string        // registry | static
	auto *autoResolver // set when mode "auto" started on an empty registry (C2-13)

	reconcileEvery time.Duration
	reconcileOpts  registry.ReconcileOptions
	onPass         func() // test hook, see registry.Registry.OnReconcilePass
}

// buildResolver chooses and builds the router's Resolver.
func (p *prepared) buildResolver(specs []gateway.ProfileSpec) (gateway.Resolver, error) {
	env := p.env
	get := func(k string) string { return env[k] }
	p.regs = &serveRegistry{mode: "static"}
	mode := env[resolverVar]
	switch mode {
	case "", "auto", "registry", "static":
	default:
		return nil, fmt.Errorf("%s=%q: want registry, static or auto", resolverVar, mode)
	}
	interval := time.Second
	if s := env[registryIntervalVar]; s != "" {
		d, err := time.ParseDuration(s)
		if err != nil || d <= 0 {
			return nil, fmt.Errorf("%s=%q: want a positive duration such as 1s", registryIntervalVar, s)
		}
		interval = d
	}
	var perr error
	if p.regs.reconcileEvery, perr = parseSeconds(reconcileIntervalVar, env[reconcileIntervalVar], defaultReconcileSecs, 3600, true); perr != nil {
		return nil, perr
	}
	if p.regs.reconcileOpts.Grace, perr = parseSeconds(reconcileGraceVar, env[reconcileGraceVar], defaultGraceSecs, 86400, false); perr != nil {
		return nil, perr
	}
	// An allocated-but-unbound port hold must outlive the longest model load the unit hooks wait for
	// (LLMCTL_REGISTER_WAIT, default 600 s = registry.DefaultPortGrace): pruning it sooner would hand
	// the port to another allocator while the engine is still loading (C-11).
	if w, werr := strconv.Atoi(env[registerWaitVar]); werr == nil && time.Duration(w)*time.Second > registry.DefaultPortGrace {
		p.regs.reconcileOpts.PortGrace = time.Duration(w) * time.Second
	}
	cfg, cerr := registry.ConfigFromEnv(get)
	if cerr == nil {
		p.regs.reg = registry.New(cfg)
	}
	static := func() gateway.Resolver {
		return gateway.NewProbeResolver(gateway.StaticResolverFromEnv(specs, get), 300*time.Millisecond, time.Second)
	}
	if mode == "static" {
		return static(), nil
	}
	if cerr != nil {
		if mode == "registry" {
			return nil, fmt.Errorf("%s=registry: %v", resolverVar, cerr)
		}
		return static(), nil
	}
	if mode != "registry" {
		// auto: PER PROFILE (B3-09). A profile with a healthy registry entry is served from the registry;
		// every other profile keeps its static endpoint (LLMCTL_DECIDE_ENDPOINT_<P>, or the catalog port).
		// A stale decide-gateway row, an unhealthy or an unrelated entry never leaves the gateway without
		// backends the static endpoints would have provided (C-23), and engines that register later win
		// from the moment they are healthy (C2-13): there is no startup decision.
		rr := gateway.NewRegistryResolver(p.regs.reg, interval, "")
		p.regs.res = rr // followed by publishSelf like in registry mode
		ar := &autoResolver{
			reg:      p.regs.reg,
			static:   static(),
			registry: gateway.NewProbeResolver(rr, 300*time.Millisecond, time.Second),
			every:    interval,
		}
		p.regs.auto = ar
		return ar, nil
	}
	// not started yet: until publishSelf starts the watch (the serving process only) it reads the
	// registry directly, so preparing a gateway - tests, `--status` - leaves no goroutine behind
	rr := gateway.NewRegistryResolver(p.regs.reg, interval, "") // keys: entry key_file, else the key files (KeyedResolver)
	p.regs.res, p.regs.mode = rr, "registry"
	// the registry's reconciler writes health; the TCP probe covers the interval between its runs
	return gateway.NewProbeResolver(rr, 300*time.Millisecond, time.Second), nil
}

// closeRegistry stops following the registry.
func (p *prepared) closeRegistry() {
	if p.regs != nil && p.regs.res != nil {
		p.regs.res.Close()
	}
}

// publishSelf starts following the registry (registry mode) and registers the gateway in the registry (kind=gateway) now that it is listening and
// returns the function that unregisters it on drain. A registry that cannot be written is a
// warning, never a reason to refuse service.
func (p *prepared) publishSelf(stderr io.Writer) func() {
	if p.regs == nil || p.regs.reg == nil {
		return func() {}
	}
	if p.regs.res != nil { // follow registry changes from now on
		if err := p.regs.res.Start(context.Background()); err != nil {
			fmt.Fprintf(stderr, "llmctl serve: registry watch not started (reading the registry per request instead): %v\n", err)
		}
	}
	un, err := gateway.PublishGatewayCA(p.regs.reg, p.bind, p.port, binName(), p.caFile())
	if err != nil {
		fmt.Fprintf(stderr, "llmctl serve: not published in the registry (serving anyway): %v\n", err)
		return func() {}
	}
	// health flags are written by the reconciler: the gateway runs it itself, so they stay
	// current without an external cron. One owner per registry (flock); stops when the drain starts.
	rctx, rcancel := context.WithCancel(context.Background())
	p.regs.reg.OnReconcilePass = p.regs.onPass
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		// let the listener start serving before the first pass probes this gateway's own /healthz
		select {
		case <-rctx.Done():
			return
		case <-time.After(min(p.regs.reconcileEvery, 2*time.Second)):
		}
		p.regs.reg.RunOwnedReconciler(rctx, p.regs.reconcileEvery, p.regs.reconcileOpts)
	}()
	var once sync.Once
	return func() {
		once.Do(func() { rcancel(); wg.Wait() })
		un()
	}
}

// caFile is the CA that certifies this gateway, recorded in its registry entry (label ca_file) so a
// reconciler without this process's environment still verifies against it. "" when none exists.
func (p *prepared) caFile() string {
	path := ""
	if p.cert != nil {
		path = p.cert.CACert
	}
	if path == "" {
		path = registry.ResolveCA(func(k string) string { return p.env[k] })
	}
	if path == "" {
		return ""
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return ""
	}
	if st, err := os.Stat(abs); err != nil || !st.Mode().IsRegular() {
		return ""
	}
	return abs
}

func (p *prepared) resolverMode() string {
	if p.regs == nil {
		return "static"
	}
	if p.regs.auto != nil {
		return p.regs.auto.mode()
	}
	return p.regs.mode
}

// autoResolver is the resolver of LLMCTL_DECIDE_RESOLVER=auto. It decides PER PROFILE on every
// request: a profile with at least one HEALTHY registry entry is served from the registry, any other
// profile from its static endpoints. A mixed deployment (profile X registered, profile Y configured
// only through LLMCTL_DECIDE_ENDPOINT_Y) therefore keeps both. The registry read is the resolver's own
// (watch snapshot or file read, a TCP probe per endpoint); this type holds no lock around any I/O.
type autoResolver struct {
	reg      *registry.Registry
	static   gateway.Resolver
	registry gateway.Resolver
	every    time.Duration

	mu      sync.Mutex // guards only the two fields below, never held across I/O
	checked time.Time
	anyReg  bool
}

// Resolve implements gateway.Resolver: the registry endpoints of the profile when one is healthy,
// else the static ones.
func (a *autoResolver) Resolve(kind, profile string) ([]gateway.Endpoint, error) {
	if eps, err := a.registry.Resolve(kind, profile); err == nil {
		for _, e := range eps {
			if e.Healthy {
				return eps, nil
			}
		}
	}
	return a.static.Resolve(kind, profile)
}

// mode reports "registry" while the registry holds at least one healthy decision engine, else
// "static" (a status line only: requests are decided per profile in Resolve). The value is cached for
// one refresh interval; the registry is read outside the lock.
func (a *autoResolver) mode() string {
	a.mu.Lock()
	fresh := !a.checked.IsZero() && time.Since(a.checked) < a.every
	cached := a.anyReg
	a.mu.Unlock()
	if !fresh {
		es, err := a.reg.Resolve(map[string]string{registry.LabelKind: gateway.KindDecide})
		cached = err == nil && len(es) > 0
		a.mu.Lock()
		a.anyReg, a.checked = cached, time.Now()
		a.mu.Unlock()
	}
	if cached {
		return "registry"
	}
	return "static"
}
