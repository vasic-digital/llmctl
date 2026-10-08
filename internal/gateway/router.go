package gateway

import (
	"context"
	"errors"
	"sync"

	"github.com/vasic-digital/llmctl/internal/contract"
	"github.com/vasic-digital/llmctl/internal/server"
)

// RouterConfig assembles a Router.
type RouterConfig struct {
	Specs    []ProfileSpec
	Resolver Resolver
	Mode     Mode
	// Concurrency is the number of simultaneous requests per instance (default 1: deterministic
	// serving needs one slot; raise it with throughput mode).
	Concurrency int
	// NativeEnabled opens the engine advance gate for systemone-native profiles (OD-1).
	NativeEnabled bool
	Drivers       map[string]Driver
	Profiles      *contract.Profiles // for aliases in Models(); nil = none
	// BaseLimits are the global request limits Models() derives each profile's advertised budgets
	// from (zero value = contract.DefaultLimits()).
	BaseLimits contract.Limits
	// Calibrations holds the calibration profiles the router applies to the confidence of the
	// answers it returns (nil = none). The caller (re)loads it; see CalibrationSet.Reload.
	Calibrations *CalibrationSet
	// Temperature is the effective global readout temperature (LLMCTL_DECIDE_TEMPERATURE, 0 = 1);
	// it is part of every letter-logit profile's template hash.
	Temperature float64
}

// Router implements server.Backend over the three drivers.
type Router struct {
	cfg   RouterConfig
	specs map[string]ProfileSpec
	order []string

	mu    sync.Mutex
	slots map[string]*instSlots
	hash  map[string]string // profile id -> template hash
}

type instSlots struct {
	sem      chan struct{}
	inflight int // guarded by Router.mu
}

// NewRouter validates cfg.
func NewRouter(cfg RouterConfig) (*Router, error) {
	if cfg.Resolver == nil || len(cfg.Specs) == 0 {
		return nil, errors.New("gateway: Router needs a resolver and at least one profile")
	}
	if cfg.Concurrency < 1 {
		cfg.Concurrency = 1
	}
	if cfg.Mode == "" {
		cfg.Mode = Deterministic
	}
	if cfg.BaseLimits == (contract.Limits{}) {
		cfg.BaseLimits = contract.DefaultLimits()
	}
	if cfg.Mode == Deterministic {
		for _, s := range cfg.Specs {
			if s.Protocol == ProtoLetter && s.Readout.CachePrompt {
				return nil, errors.New("gateway: profile " + s.ID + " sets readout.cache_prompt=true, which breaks byte-identical repeats in deterministic mode (prompt caching changes the logits); set it to false or serve in throughput mode")
			}
		}
	}
	r := &Router{cfg: cfg, specs: map[string]ProfileSpec{}, slots: map[string]*instSlots{}, hash: map[string]string{}}
	for _, s := range cfg.Specs {
		if h, err := TemplateHash(s, cfg.Temperature); err == nil {
			r.hash[s.ID] = h
		}
		if cfg.Drivers[s.Protocol] == nil {
			return nil, errors.New("gateway: no driver for protocol " + s.Protocol)
		}
		r.specs[s.ID] = s
		r.order = append(r.order, s.ID)
	}
	return r, nil
}

var _ server.Backend = (*Router)(nil)
var _ server.ModeReporter = (*Router)(nil)

// Mode is "deterministic" or "throughput": the serving mode, reported on every decision as the
// x-llmctl-decide-mode header (B-07) so a caller can tell whether byte-identity was promised.
func (r *Router) Mode() string { return string(r.cfg.Mode) }

// pairBudgeter is implemented by the driver of an encoder profile.
type pairBudgeter interface{ PairBudget() int }

// usable reports whether the profile's protocol may serve at all.
func (r *Router) usable(s ProfileSpec) bool { return s.Protocol != ProtoNative || r.cfg.NativeEnabled }

// degrader is implemented by a Driver that can tell an instance is mis-configured (the NLI driver
// when the encoder runtime's labels cannot be mapped): such an instance is reported degraded and
// takes no traffic instead of being served with guessed semantics.
type degrader interface{ Degraded(Endpoint) bool }

func (r *Router) degraded(spec ProfileSpec, e Endpoint) bool {
	d, ok := r.cfg.Drivers[spec.Protocol].(degrader)
	return ok && d.Degraded(e)
}

func (r *Router) healthy(spec ProfileSpec) []Endpoint {
	if !r.usable(spec) {
		return nil
	}
	eps, err := r.cfg.Resolver.Resolve(KindDecide, spec.ID)
	if err != nil {
		return nil
	}
	var out []Endpoint
	for _, e := range eps {
		if e.Healthy && !r.degraded(spec, e) {
			out = append(out, e)
		}
	}
	return out
}

// Ready is true when at least one served profile has a healthy instance.
func (r *Router) Ready() bool {
	for _, id := range r.order {
		if len(r.healthy(r.specs[id])) > 0 {
			return true
		}
	}
	return false
}

// Models lists the profiles that have at least one registered instance and are usable.
func (r *Router) Models() []server.ModelInfo {
	var out []server.ModelInfo
	for _, id := range r.order {
		s := r.specs[id]
		if !r.usable(s) {
			continue
		}
		eps, err := r.cfg.Resolver.Resolve(KindDecide, id)
		if err != nil || len(eps) == 0 {
			continue
		}
		status := "degraded"
		for _, e := range eps {
			if e.Healthy && !r.degraded(s, e) {
				status = "ready"
			}
		}
		m := server.ModelInfo{ID: id, Protocol: s.Protocol, Status: status, MaxOptions: s.MaxOptions,
			ScoreLevels: s.ScoreLevels, Notes: s.Notes, Description: s.Desc, ReleaseDate: s.ReleaseDate}
		lim := s.Limits(r.cfg.BaseLimits)
		// advertise what the engine really serves when it says (B2-05): the smaller of the
		// configured and the reported per-slot budget
		if s.Protocol == ProtoLetter {
			// the smallest budget over the healthy instances: an overflow instance with a smaller
			// context must not receive what the advertised limit lets through (B3-10 M8)
			for _, e := range eps {
				if !e.Healthy {
					continue
				}
				if n, ok := engineCtx(context.Background(), nil, e); ok {
					if b := contract.PromptTokenBudget(n); lim.MaxPromptTokens == 0 || b < lim.MaxPromptTokens {
						lim.MaxPromptTokens = b
					}
				}
			}
		}
		m.MaxStateChars, m.MaxContextTokens = lim.EffectiveStateChars(), lim.MaxPromptTokens
		m.TemplateHash = r.hash[id]
		if st, ok := r.cfg.Calibrations.Status(id); ok {
			m.Calibration = &st
		}
		if pb, ok := r.cfg.Drivers[s.Protocol].(pairBudgeter); ok {
			m.MaxPairs = pb.PairBudget()
		}
		if r.cfg.Profiles != nil {
			m.Aliases = r.cfg.Profiles.Aliases(id)
		} else {
			m.Aliases = []string{"llmctl-" + id}
		}
		if r.cfg.Mode == Throughput {
			if m.Notes != "" {
				m.Notes += "; "
			}
			m.Notes += "throughput mode: results are not byte-identical across instances"
		}
		out = append(out, m)
	}
	return out
}

func (r *Router) slotFor(url string) *instSlots {
	r.mu.Lock()
	defer r.mu.Unlock()
	s, ok := r.slots[url]
	if !ok {
		s = &instSlots{sem: make(chan struct{}, r.cfg.Concurrency)}
		r.slots[url] = s
	}
	return s
}

func (r *Router) tryAcquire(s *instSlots) bool {
	select {
	case s.sem <- struct{}{}:
		r.mu.Lock()
		s.inflight++
		r.mu.Unlock()
		return true
	default:
		return false
	}
}

func (r *Router) release(s *instSlots) {
	r.mu.Lock()
	s.inflight--
	r.mu.Unlock()
	<-s.sem
}

func (r *Router) load(s *instSlots) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return s.inflight
}

// acquire picks an instance and takes its slot. Deterministic: the first healthy endpoint in
// resolver order, then the next only while earlier ones are saturated; when every slot is taken it
// waits on the primary until ctx ends (529). Throughput: least loaded, ties by resolver order.
func (r *Router) acquire(ctx context.Context, eps []Endpoint) (Endpoint, *instSlots, error) {
	if r.cfg.Mode == Throughput {
		for {
			best, bestLoad := -1, 0
			for i, e := range eps {
				if l := r.load(r.slotFor(e.URL)); best < 0 || l < bestLoad {
					best, bestLoad = i, l
				}
			}
			// try the least loaded first, then the rest in order, without blocking
			order := []int{best}
			for i := range eps {
				if i != best {
					order = append(order, i)
				}
			}
			for _, i := range order {
				if s := r.slotFor(eps[i].URL); r.tryAcquire(s) {
					return eps[i], s, nil
				}
			}
			if !waitSlot(ctx) {
				return Endpoint{}, nil, overloaded()
			}
		}
	}
	for _, e := range eps {
		if s := r.slotFor(e.URL); r.tryAcquire(s) {
			return e, s, nil
		}
	}
	e := eps[0]
	s := r.slotFor(e.URL)
	select {
	case s.sem <- struct{}{}:
		r.mu.Lock()
		s.inflight++
		r.mu.Unlock()
		return e, s, nil
	case <-ctx.Done():
		return Endpoint{}, nil, overloaded()
	}
}

func waitSlot(ctx context.Context) bool {
	t := make(chan struct{})
	go func() { defer close(t); sleepTick() }()
	select {
	case <-t:
		return true
	case <-ctx.Done():
		return false
	}
}

// Decide implements server.Backend.
func (r *Router) Decide(ctx context.Context, req *contract.ParsedRequest) ([]contract.NamedAnswer, contract.Usage, error) {
	spec, ok := r.specs[req.Model]
	if !ok {
		return nil, contract.Usage{}, notReady()
	}
	eps := r.healthy(spec)
	if len(eps) == 0 {
		return nil, contract.Usage{}, notReady()
	}
	ep, slot, err := r.acquire(ctx, eps)
	if err != nil {
		return nil, contract.Usage{}, err
	}
	defer r.release(slot)
	contract.NoteInstance(ctx, ep.Instance)
	answers, usage, err := r.cfg.Drivers[spec.Protocol].Decide(ctx, ep, spec, req)
	if err != nil || r.cfg.Calibrations == nil {
		return answers, usage, err
	}
	for i := range answers {
		answers[i].Answer = r.cfg.Calibrations.Apply(spec.ID, answers[i].Answer)
	}
	return answers, usage, nil
}

var _ server.DecisionMetaProvider = (*Router)(nil)

// DecisionMeta describes a profile for the decision log: the live model checksum, the template
// hash and the calibration profile currently applied to it ("" = none).
func (r *Router) DecisionMeta(profile string) server.DecisionMeta {
	m := server.DecisionMeta{ModelSHA256: r.specs[profile].ModelSHA256, TemplateHash: r.hash[profile]}
	if st, ok := r.cfg.Calibrations.Status(profile); ok && st.Applied {
		m.CalibrationProfile = st.ProfileID
	}
	return m
}
