package registry

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"digital.vasic.containers/pkg/health"
	"digital.vasic.containers/pkg/serviceregistry"
)

// Internal bookkeeping rides in the submodule Service's label map under this
// prefix (the submodule Service has no pid/started/loopback fields); it is
// stripped from Entry.Labels.
const lblPrefix = "llmctl."

const (
	lblPID       = lblPrefix + "pid"
	lblStarted   = lblPrefix + "started"
	lblLoopback  = lblPrefix + "loopback"
	lblToken     = lblPrefix + "token"
	lblUnhealthy = lblPrefix + "unhealthy_since"
	lblFP        = lblPrefix + "proc_fp"
	lblUnknown   = lblPrefix + "unknown_since"
)

const registryLock = ".lock"

// Registry is the llmctl service registry on top of
// digital.vasic.containers/pkg/serviceregistry. Every operation takes a
// cross-process file lock and opens a fresh submodule handle, so concurrent
// llmctl processes never lose each other's updates (see lock.go).
type Registry struct {
	cfg      Config
	Identity ProcessIdentity // liveness proof; default OSIdentity
	// Fingerprint identifies one SPECIFIC process (default ProcFingerprint): recorded at Register and
	// compared at every liveness proof, so pid reuse and a sibling instance of the same program are
	// not mistaken for the registered service (C-01).
	Fingerprint func(pid int) string
	Prober      Prober // health probe; default *health.DefaultChecker
	Now         func() time.Time
	// OnReconcilePass, when set, is called after every pass of RunOwnedReconciler (a test hook:
	// only the process that owns the reconciler role passes).
	OnReconcilePass func()

	owner atomic.Bool
}

// New returns a registry rooted at cfg.Dir().
func New(cfg Config) *Registry {
	return &Registry{cfg: cfg, Identity: OSIdentity, Prober: health.NewDefaultChecker(), Now: time.Now}
}

type loadLog struct {
	mu   sync.Mutex
	errs []string
}

func (l *loadLog) Info(string, ...any)  {}
func (l *loadLog) Debug(string, ...any) {}
func (l *loadLog) Warn(string, ...any)  {}
func (l *loadLog) Error(msg string, args ...any) {
	l.mu.Lock()
	l.errs = append(l.errs, fmt.Sprintf(msg, args...))
	l.mu.Unlock()
}

// open loads the registry from disk. The submodule moves a corrupt file aside
// and carries on with an empty registry; that must never look like "no
// services", so it is surfaced as an error here (the bytes are kept in
// services.json.corrupt).
func (r *Registry) open() (*serviceregistry.ServiceRegistry, error) {
	lg := &loadLog{}
	sr := serviceregistry.New(
		serviceregistry.WithRegistryDir(r.cfg.Dir()),
		serviceregistry.WithDefaultHost("127.0.0.1"),
		serviceregistry.WithLogger(lg),
	)
	if len(lg.errs) > 0 {
		msg := strings.Join(lg.errs, "; ")
		r.noteCorrupt(msg)
		return nil, fmt.Errorf("service registry was corrupt and has been moved aside, start over: %s", msg)
	}
	return sr, nil
}

// corruptMarker is the sticky "the registry was found corrupt" note. The submodule moves a corrupt
// file aside, so only the FIRST operation errors and every later one would see an empty registry -
// exactly the "looks like no services" outcome open() must not allow. The marker stays until
// AckCorrupt, and reconcile / diff / list keep reporting it (C-24).
const corruptMarker = ".corrupt-detected"

func (r *Registry) noteCorrupt(msg string) {
	dir := r.cfg.Dir()
	// the submodule overwrites services.json.corrupt on a second corruption: keep a dated copy
	if b, err := os.ReadFile(filepath.Join(dir, "services.json.corrupt")); err == nil {
		_ = os.WriteFile(filepath.Join(dir, fmt.Sprintf("services.json.corrupt.%d", r.now().UnixNano())), b, 0o600)
	}
	_ = os.WriteFile(filepath.Join(dir, corruptMarker),
		[]byte(fmt.Sprintf("%s %s\n", r.now().UTC().Format(time.RFC3339), msg)), 0o600)
}

// CorruptNotice returns the unacknowledged corruption note ("" when there is none).
func (r *Registry) CorruptNotice() string {
	b, err := os.ReadFile(filepath.Join(r.cfg.Dir(), corruptMarker))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// AckCorrupt clears the corruption note; it reports whether there was one.
func (r *Registry) AckCorrupt() (bool, error) {
	err := os.Remove(filepath.Join(r.cfg.Dir(), corruptMarker))
	if os.IsNotExist(err) {
		return false, nil
	}
	return err == nil, err
}

func (r *Registry) read(fn func(sr *serviceregistry.ServiceRegistry) error) error {
	return withLock(r.cfg.Dir(), registryLock, false, func() error {
		sr, err := r.open()
		if err != nil {
			return err
		}
		return fn(sr)
	})
}

func (r *Registry) write(fn func(sr *serviceregistry.ServiceRegistry) error) error {
	return withLock(r.cfg.Dir(), registryLock, true, func() error {
		sr, err := r.open()
		if err != nil {
			return err
		}
		return fn(sr)
	})
}

func (r *Registry) now() time.Time {
	if r.Now != nil {
		return r.Now()
	}
	return time.Now()
}

func (r *Registry) fingerprint() func(int) string {
	if r.Fingerprint != nil {
		return r.Fingerprint
	}
	return ProcFingerprint
}

// FPUnavailable is stored in Entry.ProcFP when the process fingerprint could not be determined at Register
// (for example procfs hides /proc/<pid>/stat from this user). It is NOT "no fingerprint recorded": a row carrying
// it is never trusted - it is reported unknown and not routable until a later Reconcile can fingerprint the
// process (then the fingerprint is adopted), and, like any unknown row, it is only forgotten on the operator's
// --prune-unknown-after (C2-08).
const FPUnavailable = "unavailable"

// liveness proves entry e is still THE registered process. alive: the identity check passed (and the recorded
// fingerprint, when there is one, still matches). fpUnknown: the identity passed but the process cannot be
// fingerprinted, so the row cannot be trusted. adopt: a fingerprint obtained just now for a row that had none.
func (r *Registry) liveness(e Entry) (alive, fpUnknown bool, adopt string) {
	if !r.identity()(e.PID, e.CmdToken) {
		return false, false, ""
	}
	cur := r.fingerprint()(e.PID)
	if e.ProcFP == "" || e.ProcFP == FPUnavailable {
		if cur == "" {
			return true, true, ""
		}
		return true, false, cur
	}
	return cur == e.ProcFP, false, ""
}

// alive proves entry e is still THE registered process: the program identity check, then (when a
// fingerprint was recorded at registration) the same start time and argv - a recycled pid or a
// different instance of the same program fails it.
// A row whose fingerprint is unavailable counts as alive here (callers only ask whether it may be reaped, and a
// possibly-live process is not reaped); Reconcile treats it as unknown, never as trusted.
func (r *Registry) alive(e Entry) bool {
	a, _, _ := r.liveness(e)
	return a
}

func (r *Registry) identity() ProcessIdentity {
	if r.Identity != nil {
		return r.Identity
	}
	return OSIdentity
}

// rowNameKind classifies a row name against the tenant grammar (C3-08). A tenant's rows are named
// "<tenant>--<profile>": the FIRST "--" is the separator, so the name is unambiguous only when the tenant part does not
// end with "-" and the profile part neither starts with "-" nor holds another "--" (tenant ids and profile names may
// contain single dashes: "acme-eu--qwen-7b"). tenantRow: the name holds a "--". wellFormed: it follows the grammar
// (a name without "--" is a plain, well-formed non-tenant name).
func rowNameKind(name string) (tenantRow, wellFormed bool) {
	i := strings.Index(name, "--")
	if i < 0 {
		return false, true
	}
	t, p := name[:i], name[i+2:]
	if t == "" || p == "" || strings.HasPrefix(p, "-") || strings.Contains(p, "--") {
		return true, false
	}
	return true, true
}

// validRowName is nameRE plus the tenant grammar: "acme---small" and "acme--eu--small" are refused because they could
// belong to two different tenants (acme / acme- / acme--eu) and a tenant-scoped diff would leak across them.
func validRowName(name string) error {
	if !nameRE.MatchString(name) {
		return usagef("invalid service name %q (letters, digits, . _ - only)", name)
	}
	if _, ok := rowNameKind(name); !ok {
		return usagef("invalid service name %q: a name holding \"--\" must be \"<tenant>--<profile>\" with exactly one \"--\" and no dash touching it (tenant ids and profile names must not contain \"--\")", name)
	}
	return nil
}

// Validate checks an entry; the returned error is a *UsageError.
func (e *Entry) validate() error {
	if err := validRowName(e.Name); err != nil {
		return err
	}
	if e.Port < 1 || e.Port > 65535 {
		return usagef("invalid port %d (1-65535)", e.Port)
	}
	if e.PID <= 1 {
		return usagef("invalid pid %d: liveness is proven from a real process, pid must be > 1", e.PID)
	}
	if e.CmdToken == "" || len(e.CmdToken) > 256 {
		return usagef("a command token is required: the program name the pid must be running")
	}
	switch e.Protocol {
	case "", "http", "https", "tcp":
	default:
		return usagef("invalid protocol %q (http, https or tcp)", e.Protocol)
	}
	for k := range e.Labels {
		if strings.HasPrefix(k, lblPrefix) {
			return usagef("label key %q is reserved", k)
		}
	}
	return nil
}

func (e Entry) options() []serviceregistry.ServiceOption {
	labels := map[string]string{}
	for k, v := range e.Labels {
		labels[k] = v
	}
	labels[lblPID] = strconv.Itoa(e.PID)
	labels[lblStarted] = e.Started.UTC().Format(time.RFC3339Nano)
	labels[lblLoopback] = strconv.FormatBool(e.LoopbackOnly)
	labels[lblToken] = e.CmdToken
	if !e.UnhealthySince.IsZero() {
		labels[lblUnhealthy] = e.UnhealthySince.UTC().Format(time.RFC3339Nano)
	}
	if e.ProcFP != "" {
		labels[lblFP] = e.ProcFP
	}
	if !e.UnknownSince.IsZero() {
		labels[lblUnknown] = e.UnknownSince.UTC().Format(time.RFC3339Nano)
	}
	opts := []serviceregistry.ServiceOption{
		serviceregistry.WithHost(e.Host),
		serviceregistry.WithProtocol(e.Protocol),
		serviceregistry.WithLabels(labels),
	}
	if e.HealthPath != "" {
		opts = append(opts, serviceregistry.WithHealthPath(e.HealthPath))
	}
	return opts
}

func fromService(s serviceregistry.Service) Entry {
	e := Entry{
		Name: s.Name, Host: s.Host, Port: s.Port, Protocol: s.Protocol, HealthPath: s.HealthPath,
		Healthy: s.Healthy, Labels: map[string]string{},
	}
	for k, v := range s.Labels {
		switch k {
		case lblPID:
			e.PID, _ = strconv.Atoi(v)
		case lblStarted:
			e.Started, _ = time.Parse(time.RFC3339Nano, v)
		case lblLoopback:
			e.LoopbackOnly = v == "true"
		case lblToken:
			e.CmdToken = v
		case lblUnhealthy:
			e.UnhealthySince, _ = time.Parse(time.RFC3339Nano, v)
		case lblFP:
			e.ProcFP = v
		case lblUnknown:
			e.UnknownSince, _ = time.Parse(time.RFC3339Nano, v)
		default:
			e.Labels[k] = v
		}
	}
	if len(e.Labels) == 0 {
		e.Labels = nil
	}
	return e
}

// put stores e (replacing an entry of the same name) and applies its health flag.
func put(sr *serviceregistry.ServiceRegistry, e Entry) error {
	if err := sr.Register(e.Name, e.Port, e.options()...); err != nil {
		return err
	}
	return sr.UpdateHealth(e.Name, e.Healthy)
}

// Register publishes e (or replaces the entry of the same name). A different
// entry on the same host:port whose process is gone is reaped first; a live
// one is refused.
func (r *Registry) Register(e Entry) error {
	if e.Host == "" {
		e.Host = "127.0.0.1"
	}
	if e.Protocol == "" {
		e.Protocol = "http"
	}
	if err := e.validate(); err != nil {
		return err
	}
	if e.Started.IsZero() {
		e.Started = r.now()
	}
	e.Healthy, e.UnhealthySince, e.UnknownSince = true, time.Time{}, time.Time{}
	// C2-07: prove the pid runs the registered program BEFORE fingerprinting it. A pid that has not exec'd yet
	// (a launcher shell) would otherwise pin the launcher's argv as "the" fingerprint and the next reconcile
	// would remove a healthy service.
	if !r.identity()(e.PID, e.CmdToken) {
		return usagef("pid %d is not (yet) running %q: register after the process has exec'd the program (refusing to fingerprint another program)", e.PID, e.CmdToken)
	}
	if e.ProcFP == "" {
		if e.ProcFP = r.fingerprint()(e.PID); e.ProcFP == "" {
			e.ProcFP = FPUnavailable // C2-08: fail closed, never "no fingerprint recorded"
		}
	}
	if e.ProcFP == FPUnavailable {
		// C3-02: an unverifiable row is UNKNOWN from the first instant, not healthy until the first Reconcile
		// (the gateway's registry resolver and the auto mode route on Healthy).
		e.Healthy, e.UnknownSince = false, r.now()
	}
	return r.write(func(sr *serviceregistry.ServiceRegistry) error {
		for _, s := range sr.List() {
			o := fromService(s)
			if o.Name != e.Name && o.Host == e.Host && o.Port == e.Port && !r.alive(o) {
				if err := sr.Unregister(o.Name); err != nil {
					return err
				}
			}
		}
		return put(sr, e)
	})
}

// Unregister removes name; it reports whether it was present.
func (r *Registry) Unregister(name string) (bool, error) {
	had := false
	err := r.write(func(sr *serviceregistry.ServiceRegistry) error {
		if _, had = sr.Get(name); !had {
			return nil
		}
		return sr.Unregister(name)
	})
	return had, err
}

// List returns every entry (healthy or not), sorted by name.
func (r *Registry) List() ([]Entry, error) {
	var out []Entry
	err := r.read(func(sr *serviceregistry.ServiceRegistry) error {
		for _, s := range sr.List() {
			out = append(out, fromService(s))
		}
		return nil
	})
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, err
}

func (r *Registry) Get(name string) (Entry, bool, error) {
	var e Entry
	var ok bool
	err := r.read(func(sr *serviceregistry.ServiceRegistry) error {
		var s *serviceregistry.Service
		if s, ok = sr.Get(name); ok {
			e = fromService(*s)
		}
		return nil
	})
	return e, ok, err
}

// Resolve returns the HEALTHY entries whose labels include every given pair.
func (r *Registry) Resolve(labels map[string]string) ([]Entry, error) {
	all, err := r.List()
	if err != nil {
		return nil, err
	}
	var out []Entry
	for _, e := range all {
		if e.Healthy && e.ProcFP != FPUnavailable && matchLabels(e, labels) { // C3-02: the marker alone is never routable
			out = append(out, e)
		}
	}
	return out, nil
}

func matchLabels(e Entry, want map[string]string) bool {
	for k, v := range want {
		if e.Labels[k] != v {
			return false
		}
	}
	return true
}

// markHealth records a health flip (and the start of the unhealthy period).
func (r *Registry) markHealth(name string, healthy bool, since time.Time) error {
	return r.write(func(sr *serviceregistry.ServiceRegistry) error {
		s, ok := sr.Get(name)
		if !ok {
			return nil
		}
		e := fromService(*s)
		e.Healthy = healthy
		if healthy {
			e.UnhealthySince = time.Time{}
		} else {
			e.UnhealthySince = since
		}
		return put(sr, e)
	})
}

// ---- Reconcile ---------------------------------------------------------------

// ReconcileOptions tunes Reconcile.
type ReconcileOptions struct {
	Grace     time.Duration // unhealthy this long -> removed (0 = at the first failed probe)
	PortGrace time.Duration // abandoned port holds older than this are pruned (default DefaultPortGrace)
	// PruneUnknownAfter removes an https entry that has stayed "unknown" (no CA to verify against)
	// for this long. 0 (the default) never removes it: a missing CA is not proof the service is gone
	// (G-068); the operator opts in to forgetting rows that were never certifiable (G-074).
	PruneUnknownAfter time.Duration
}

// DefaultPortGrace is how long an allocated-but-unbound port hold is kept. It must outlast a cold
// model load: an engine such as onnx_server.py loads its model and runs a smoke inference BEFORE it
// binds, and svc_hook.sh waits LLMCTL_REGISTER_WAIT (default 600s) for it - pruning the hold sooner
// would hand the port to another allocator while the engine is still loading (C-11).
const DefaultPortGrace = 600 * time.Second

// Removal is one entry Reconcile removed, with the evidence.
type Removal struct{ Name, Reason string }

// ReconcileReport is what one Reconcile pass did.
type ReconcileReport struct {
	Removed   []Removal
	Unhealthy []string
	Healthy   []string
	Unknown   []Removal // https entries that could not be certified because no CA was found
	// Corrupt is the unacknowledged corruption note ("" = none): reported on EVERY pass until acked.
	Corrupt     string
	PortsPruned int
}

type probeResult struct {
	snap    Entry
	alive   bool
	ok      bool
	unknown bool // an https entry whose CA is not available: neither healthy nor failed
	err     string
	fpUnk   bool   // identity proven but the process cannot be fingerprinted: unknown, never trusted (C2-08)
	adopt   string // a fingerprint obtained now for a row that had none
}

// Reconcile proves each entry's liveness from the real process identity and a
// health probe: a gone (or different) process is removed at once; a failing
// probe marks the entry unhealthy and removes it once it has been unhealthy
// for Grace. Probes run outside the lock; results are applied only to entries
// still unchanged (same pid and start time).
func (r *Registry) Reconcile(ctx context.Context, o ReconcileOptions) (ReconcileReport, error) {
	var rep ReconcileReport
	snap, err := r.List()
	rep.Corrupt = r.CorruptNotice()
	if err != nil {
		return rep, err
	}
	res := make([]probeResult, len(snap))
	var wg sync.WaitGroup
	for i, e := range snap {
		wg.Add(1)
		go func(i int, e Entry) {
			defer wg.Done()
			pr := probeResult{snap: e}
			var fpUnk bool
			var adopt string
			if pr.alive, fpUnk, adopt = r.liveness(e); pr.alive {
				pr.fpUnk, pr.adopt = fpUnk, adopt
				if fpUnk {
					pr.unknown, pr.err = true, "process fingerprint unavailable: cannot prove this is still the registered process"
				} else {
					pr.ok, pr.unknown, pr.err = r.probeState(ctx, e)
				}
			}
			res[i] = pr
		}(i, e)
	}
	wg.Wait()

	now := r.now()
	var freed []Removal
	var ports []int
	err = r.write(func(sr *serviceregistry.ServiceRegistry) error {
		for _, pr := range res {
			s, ok := sr.Get(pr.snap.Name)
			if !ok {
				continue
			}
			cur := fromService(*s)
			if cur.PID != pr.snap.PID || !cur.Started.Equal(pr.snap.Started) {
				continue // re-registered since the snapshot
			}
			if pr.alive && pr.adopt != "" && cur.ProcFP == pr.snap.ProcFP {
				cur.ProcFP = pr.adopt // C2-08: the fingerprint is now determinable; the row is verifiable from here on
				if err := put(sr, cur); err != nil {
					return err
				}
			}
			switch {
			case !pr.alive:
				if err := sr.Unregister(cur.Name); err != nil {
					return err
				}
				rep.Removed = append(rep.Removed, Removal{cur.Name, fmt.Sprintf("process identity check failed: pid %d is gone or is not %q", cur.PID, cur.CmdToken)})
				freed, ports = append(freed, Removal{Name: cur.Name}), append(ports, cur.Port)
			case pr.unknown:
				// no CA to verify against: not routable, and removed only when the operator asked for
				// unknown rows to be forgotten after a while (PruneUnknownAfter, G-074 / G-068)
				since := cur.UnknownSince
				if since.IsZero() {
					since = now
				}
				if o.PruneUnknownAfter > 0 && now.Sub(since) >= o.PruneUnknownAfter {
					if err := sr.Unregister(cur.Name); err != nil {
						return err
					}
					rep.Removed = append(rep.Removed, Removal{cur.Name, fmt.Sprintf("unknown (%s) for %s (prune-unknown-after %s)", pr.err, now.Sub(since).Round(time.Second), o.PruneUnknownAfter)})
					// C2-14: the process is ALIVE (it passed the identity check), only uncertifiable. Forgetting the row
					// must not hand its port back to the pool; the hold is dropped by Prune once nothing listens on it.
					continue
				}
				if cur.Healthy || !cur.UnhealthySince.IsZero() || cur.UnknownSince.IsZero() {
					cur.Healthy, cur.UnhealthySince, cur.UnknownSince = false, time.Time{}, since
					if err := put(sr, cur); err != nil {
						return err
					}
				}
				rep.Unknown = append(rep.Unknown, Removal{cur.Name, pr.err})
			case pr.ok:
				if !cur.Healthy || !cur.UnhealthySince.IsZero() || !cur.UnknownSince.IsZero() {
					cur.Healthy, cur.UnhealthySince, cur.UnknownSince = true, time.Time{}, time.Time{}
					if err := put(sr, cur); err != nil {
						return err
					}
				}
				rep.Healthy = append(rep.Healthy, cur.Name)
			default:
				since := cur.UnhealthySince
				if since.IsZero() {
					since = now
				}
				if now.Sub(since) >= o.Grace {
					if err := sr.Unregister(cur.Name); err != nil {
						return err
					}
					rep.Removed = append(rep.Removed, Removal{cur.Name, fmt.Sprintf("health check failed for %s (grace %s): %s", now.Sub(since).Round(time.Millisecond), o.Grace, pr.err)})
					freed, ports = append(freed, Removal{Name: cur.Name}), append(ports, cur.Port)
					continue
				}
				if cur.Healthy || cur.UnhealthySince.IsZero() {
					cur.Healthy, cur.UnhealthySince = false, since
					if err := put(sr, cur); err != nil {
						return err
					}
				}
				rep.Unhealthy = append(rep.Unhealthy, cur.Name)
			}
		}
		return nil
	})
	if err != nil {
		return rep, err
	}
	// ports of removed services go back to the pool, abandoned holds are pruned
	pp := NewPorts(r.cfg, func(string) string { return "" })
	for i, f := range freed {
		if err := pp.releaseIf(f.Name, ports[i]); err != nil {
			return rep, err
		}
	}
	grace := o.PortGrace
	if grace <= 0 {
		grace = DefaultPortGrace
	}
	if rep.PortsPruned, err = pp.Prune(grace, now); err != nil {
		return rep, err
	}
	return rep, nil
}

// probe checks health. Plain http: an HTTP GET of the health path through the Containers health
// package; https: a TLS handshake verified against the llmctl CA plus a GET of the health path
// (TLSCheck - the submodule's checker cannot be given a trust pool, see tlsprobe.go); anything
// else (tcp, or http without a health path): a TCP dial.
func (r *Registry) probe(ctx context.Context, e Entry) (bool, string) {
	ok, _, why := r.probeState(ctx, e)
	return ok, why
}

// probeState is probe plus the "unknown" verdict: an https entry with no usable CA is unknown
// (not certifiable), not failed.
func (r *Registry) probeState(ctx context.Context, e Entry) (ok, unknown bool, why string) {
	t := health.HealthTarget{Name: e.Name, Host: e.Host, Port: strconv.Itoa(e.Port), Type: health.HealthTCP, Timeout: 2 * time.Second}
	pctx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()
	var hr *health.HealthResult
	switch {
	case e.Protocol == "https":
		pool, err := r.pickCA(e)
		if err != nil {
			return false, true, err.Error()
		}
		t.Path, t.Timeout = e.HealthPath, 3*time.Second
		hr = TLSCheck(pool)(pctx, t)
	default:
		if e.Protocol == "http" && e.HealthPath != "" {
			t.Type, t.Path = health.HealthHTTP, e.HealthPath
		}
		prober := r.Prober
		if prober == nil {
			prober = health.NewDefaultChecker()
		}
		hr = prober.Check(pctx, t)
	}
	if hr == nil || !hr.Healthy {
		msg := "no result"
		if hr != nil {
			msg = hr.Error
		}
		return false, false, msg
	}
	return true, false, ""
}

// ---- Diff --------------------------------------------------------------------

// LiveService is a service process known to be running.
type LiveService struct {
	Name string
	PID  int
}

// DiffReport lists where the registry and the live set disagree.
type DiffReport struct {
	RegistryOnly []string // row without a live service
	LiveOnly     []string // live service without a row
	PIDMismatch  []string // same name, different pid
}

func (d DiffReport) Empty() bool {
	return len(d.RegistryOnly)+len(d.LiveOnly)+len(d.PIDMismatch) == 0
}

// DiffScope narrows a Diff to the rows (and live services) one backend owns (C2-03). The registry is shared by
// every tenant and by non-tenant services, while a backend's live set lists only its own, so an unscoped diff
// reports the others' rows as "row without a live service".
type DiffScope struct {
	Prefix       string   // keep only names with this prefix (a tenant: "<tenant>--")
	Include      []string // names kept in addition to the prefix (services shared by every tenant, e.g. the gateway)
	NoTenantRows bool     // drop rows named "<tenant>--<profile>" (a non-tenant backend does not own them)
}

func (s DiffScope) keep(name string) bool {
	for _, n := range s.Include {
		if n == name {
			return true
		}
	}
	tenantRow, wellFormed := rowNameKind(name)
	if s.Prefix != "" {
		if !strings.HasPrefix(name, s.Prefix) {
			return false
		}
		// C3-08: a tenant scope ("<tenant>--") owns only rows that follow the grammar - an ambiguous legacy name such as
		// "acme---small" (tenant "acme-"?) or "acme--eu--small" (tenant "acme--eu"?) belongs to no tenant scope.
		if strings.HasSuffix(s.Prefix, "--") && !wellFormed {
			return false
		}
	}
	// a non-tenant scope drops WELL-FORMED tenant rows only; an ambiguous row stays visible (it is a defect, not a tenant's)
	if s.NoTenantRows && tenantRow && wellFormed {
		return false
	}
	return true
}

// Diff compares ALL registry rows with the live service set (FR-089).
func (r *Registry) Diff(live []LiveService) (DiffReport, error) {
	return r.DiffScoped(live, DiffScope{})
}

// DiffScoped is Diff restricted by scope on BOTH sides.
func (r *Registry) DiffScoped(live []LiveService, scope DiffScope) (DiffReport, error) {
	var d DiffReport
	rows, err := r.List()
	if err != nil {
		return d, err
	}
	byName := map[string]Entry{}
	for _, e := range rows {
		if scope.keep(e.Name) {
			byName[e.Name] = e
		}
	}
	seen := map[string]bool{}
	for _, l := range live {
		if !scope.keep(l.Name) {
			continue
		}
		seen[l.Name] = true
		e, ok := byName[l.Name]
		switch {
		case !ok:
			d.LiveOnly = append(d.LiveOnly, l.Name)
		case e.PID != l.PID:
			d.PIDMismatch = append(d.PIDMismatch, l.Name)
		}
	}
	for n := range byName {
		if !seen[n] {
			d.RegistryOnly = append(d.RegistryOnly, n)
		}
	}
	sort.Strings(d.RegistryOnly)
	sort.Strings(d.LiveOnly)
	sort.Strings(d.PIDMismatch)
	return d, nil
}

// ---- Watch -------------------------------------------------------------------

// Snapshot is the routable view of the registry at one moment.
type Snapshot struct {
	Seq     uint64
	At      time.Time
	Entries []Entry
}

// digest covers only what affects routing, not heartbeat timestamps.
func digest(es []Entry) [32]byte {
	type row struct {
		N, H, P, Pr string
		Port, PID   int
		Hl, Lo      bool
		L           map[string]string
	}
	rows := make([]row, len(es))
	for i, e := range es {
		rows[i] = row{e.Name, e.Host, e.HealthPath, e.Protocol, e.Port, e.PID, e.Healthy, e.LoopbackOnly, e.Labels}
	}
	b, _ := json.Marshal(rows) // map keys are sorted by encoding/json
	return sha256.Sum256(b)
}

// Watch emits the registry's state immediately and then whenever what is
// routable changes (poll + file identity). A slow consumer always converges on
// the latest state (older undelivered snapshots are dropped). The channel is
// closed when ctx ends.
func (r *Registry) Watch(ctx context.Context, every time.Duration) <-chan Snapshot {
	ch := make(chan Snapshot, 1)
	go func() {
		defer close(ch)
		file := filepath.Join(r.cfg.Dir(), "services.json")
		type fid struct {
			size int64
			mod  time.Time
			ino  uint64
		}
		ident := func() fid {
			st, err := os.Stat(file)
			if err != nil {
				return fid{}
			}
			return fid{st.Size(), st.ModTime(), inode(st)}
		}
		var last [32]byte
		var lastID fid
		var seq uint64
		first := true
		tick := time.NewTicker(every)
		defer tick.Stop()
		for {
			if id := ident(); first || id != lastID {
				if es, err := r.List(); err == nil {
					lastID = id
					if d := digest(es); first || d != last {
						last, first = d, false
						seq++
						s := Snapshot{Seq: seq, At: r.now(), Entries: es}
						select {
						case ch <- s:
						default:
							select {
							case <-ch:
							default:
							}
							ch <- s
						}
					}
				}
			}
			select {
			case <-ctx.Done():
				return
			case <-tick.C:
			}
		}
	}()
	return ch
}

// RunReconciler runs Reconcile every interval until ctx ends.
func (r *Registry) RunReconciler(ctx context.Context, every time.Duration, o ReconcileOptions) {
	tick := time.NewTicker(every)
	defer tick.Stop()
	for {
		_, _ = r.Reconcile(ctx, o)
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}
