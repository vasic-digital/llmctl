// Package gateway wires the decision gateway's Backend (internal/server): it loads the decision
// profiles from models/catalog.json, finds the instances that serve them through a Resolver,
// talks to them over loopback with a per-start internal key, and turns their output into typed
// answers (internal/contract) with the shared letter-logit math (internal/readout).
//
// Three protocol drivers exist (catalog `decision.protocol`):
//
//	letter-logit      LetterLogitBackend  llama-server /v1/chat/completions, first-token logprobs
//	nli-onnx          NLIBackend          encoder runtime POST /v1/score (entailment per pair)
//	systemone-native  NativeBackend       llama-server /v1/systemone (b11361+), DISABLED until the
//	                                      engine advance gate (OD-1) opens: RouterConfig.NativeEnabled
//
// The Router picks among healthy instances (deterministic: primary first, overflow only when it is
// saturated; throughput: least loaded) and implements server.Backend.
package gateway

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/vasic-digital/llmctl/internal/contract"
)

// Decision protocols (catalog `decision.protocol`).
const (
	ProtoLetter = "letter-logit"
	ProtoNative = "systemone-native"
	ProtoNLI    = "nli-onnx"
)

// ReadoutSpec is the catalog's letter-logit readout block.
type ReadoutSpec struct {
	NProbs        int
	MassThreshold float64
	Spellings     []string
	CachePrompt   bool
}

// ProfileSpec is the part of a catalog decision profile the gateway depends on
// (contracts/catalog-schema.md); every other field is ignored.
type ProfileSpec struct {
	ID           string
	Protocol     string
	Port         int
	MaxOptions   int
	ScoreLevels  [2]int
	Readout      ReadoutSpec
	Experimental []string
	Notes        string
	// Ctx is the per-request context of the serving instance in tokens (catalog defaults.ctx; the
	// scheduler passes --ctx-size ctx*parallel, and llama-server divides it across the slots, so one
	// request always sees ctx tokens - measured, evidence/review-2/ctx-measurements.json). For an
	// encoder profile it is the pair window (max_tokens). 0 = unknown: no token budget is enforced.
	Ctx int
	// Parallel is the catalog slot count (informational: the per-slot context is Ctx).
	Parallel int
	// Desc is the profile's `desc` (the SDK listing's description); ReleaseDate is the optional
	// `decision.release_date` (YYYY-MM-DD) - "" means the documented default (server.DefaultReleaseDate).
	Desc        string
	ReleaseDate string
	// ModelSHA256 is the checksum of the profile's single model file (files[role=model].sha256, the
	// value the downloader verified), "" when the catalog names none or several (SingleModelSHA).
	// It is the "live model" a calibration profile must be bound to.
	ModelSHA256 string
}

type rawCatalog struct {
	Profiles map[string]struct {
		Port       int      `json:"port"`
		Desc       string   `json:"desc"`
		Capability []string `json:"capability"`
		Files      []struct {
			Role   string  `json:"role"`
			SHA256 *string `json:"sha256"`
		} `json:"files"`
		Defaults *struct {
			Ctx      *int `json:"ctx"`
			Parallel *int `json:"parallel"`
		} `json:"defaults"`
		Decision *struct {
			Protocol     string   `json:"protocol"`
			MaxOptions   *int     `json:"max_options"`
			ScoreLevels  []int    `json:"score_levels"`
			Experimental []string `json:"experimental"`
			TierNote     string   `json:"tier_note"`
			ReleaseDate  string   `json:"release_date"`
			Readout      *struct {
				NProbs        *int     `json:"n_probs"`
				MassThreshold *float64 `json:"mass_threshold"`
				Spellings     []string `json:"spellings"`
				CachePrompt   bool     `json:"cache_prompt"`
			} `json:"readout"`
		} `json:"decision"`
	} `json:"profiles"`
}

// Defaults applied when the catalog omits a value.
const (
	DefaultMaxOptions    = 20
	DefaultNProbs        = 32
	DefaultMassThreshold = 0.5
)

// pyInt parses a whole number the way Python's int(str) does for ASCII input, which is what the
// launcher (lib/catalog.sh resolve_ctx) uses: surrounding blanks, an optional sign, and single
// underscores BETWEEN digits ("4_096"). Python also accepts non-ASCII decimal digits; the gateway
// refuses them (loudly, at start, naming the variable) - the one documented difference.
func pyInt(s string) (int, error) {
	t := strings.TrimSpace(s)
	body := strings.TrimLeft(t, "+-")
	if len(t)-len(body) > 1 || body == "" {
		return 0, strconv.ErrSyntax
	}
	var clean strings.Builder
	if t != body {
		clean.WriteByte(t[0])
	}
	for i := 0; i < len(body); i++ {
		c := body[i]
		switch {
		case c >= '0' && c <= '9':
			clean.WriteByte(c)
		case c == '_' && i > 0 && i < len(body)-1 && body[i-1] != '_' && body[i+1] >= '0' && body[i+1] <= '9':
		default:
			return 0, strconv.ErrSyntax
		}
	}
	return strconv.Atoi(clean.String())
}

// minOverrideCtx mirrors MIN_CTX of lib/catalog.sh resolve_ctx.
const minOverrideCtx = 512

// ctxEnvName is the per-profile context override variable (upper-cased id, '-' -> '_').
func ctxEnvName(id string) string {
	return "LLMCTL_CTX_" + strings.ToUpper(strings.ReplaceAll(id, "-", "_"))
}

// LoadCatalog reads the decision profiles from a catalog file.
func LoadCatalog(path string) ([]ProfileSpec, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("gateway: read catalog: %w", err)
	}
	return ParseCatalog(b)
}

// ParseCatalog extracts the decision profiles (capability "decide" or a `decision` object),
// sorted by id. Unknown fields are tolerated; illegal values are errors.
func ParseCatalog(data []byte) ([]ProfileSpec, error) {
	var c rawCatalog
	if err := json.Unmarshal(data, &c); err != nil {
		return nil, fmt.Errorf("gateway: catalog is not valid JSON: %w", err)
	}
	var specs []ProfileSpec
	for id, p := range c.Profiles {
		isDecide := p.Decision != nil
		for _, cap := range p.Capability {
			if cap == "decide" {
				isDecide = true
			}
		}
		if !isDecide {
			continue
		}
		if p.Decision == nil {
			return nil, fmt.Errorf("gateway: profile %s has capability decide but no decision object", id)
		}
		if id == "" || strings.Trim(id, "abcdefghijklmnopqrstuvwxyz0123456789-") != "" {
			return nil, fmt.Errorf("gateway: invalid decision profile name %q", id)
		}
		d := p.Decision
		var modelShas []string
		for _, f := range p.Files {
			if f.Role == "model" {
				sh := ""
				if f.SHA256 != nil {
					sh = *f.SHA256
				}
				modelShas = append(modelShas, sh)
			}
		}
		msha, _ := SingleModelSHA(modelShas) // "" when unresolvable: never guessed
		s := ProfileSpec{ModelSHA256: msha, ID: id, Protocol: d.Protocol, Port: p.Port, MaxOptions: DefaultMaxOptions,
			ScoreLevels: [2]int{2, 10}, Experimental: d.Experimental, Notes: d.TierNote, Desc: p.Desc}
		if p.Defaults != nil {
			if c := p.Defaults.Ctx; c != nil {
				if *c < 16 || *c > 1<<24 {
					return nil, fmt.Errorf("gateway: profile %s: defaults.ctx out of range", id)
				}
				s.Ctx = *c
			}
			if c := p.Defaults.Parallel; c != nil {
				if *c < 1 || *c > 1024 {
					return nil, fmt.Errorf("gateway: profile %s: defaults.parallel out of range", id)
				}
				s.Parallel = *c
			}
		}
		// the launcher serves LLMCTL_CTX_<PROFILE> when set (lib/catalog.sh resolve_ctx, same naming and
		// validation): the token budget must follow it (B2-05)
		if ov, ok := os.LookupEnv(ctxEnvName(id)); ok && ov != "" {
			n, perr := pyInt(ov)
			if perr != nil {
				return nil, fmt.Errorf("gateway: %s=%q is not a valid context size", ctxEnvName(id), ov)
			}
			if n < minOverrideCtx || n > 1<<24 {
				return nil, fmt.Errorf("gateway: %s=%q must be between %d and %d", ctxEnvName(id), ov, minOverrideCtx, 1<<24)
			}
			s.Ctx = n
		}
		if d.ReleaseDate != "" {
			if t, err := time.Parse("2006-01-02", d.ReleaseDate); err != nil || t.Format("2006-01-02") != d.ReleaseDate {
				return nil, fmt.Errorf("gateway: profile %s: release_date must be YYYY-MM-DD", id)
			}
			s.ReleaseDate = d.ReleaseDate
		}
		switch d.Protocol {
		case ProtoLetter, ProtoNative, ProtoNLI:
		default:
			return nil, fmt.Errorf("gateway: profile %s: unknown decision protocol %q", id, d.Protocol)
		}
		if d.MaxOptions != nil {
			if *d.MaxOptions < 2 || *d.MaxOptions > contract.HostedMaxOptions {
				return nil, fmt.Errorf("gateway: profile %s: max_options must be 2..255", id)
			}
			s.MaxOptions = *d.MaxOptions
		}
		if len(d.ScoreLevels) == 2 {
			s.ScoreLevels = [2]int{d.ScoreLevels[0], d.ScoreLevels[1]}
		} else if len(d.ScoreLevels) != 0 {
			return nil, fmt.Errorf("gateway: profile %s: score_levels must be [min,max]", id)
		}
		if s.ScoreLevels[0] < 2 || s.ScoreLevels[0] > s.ScoreLevels[1] || s.ScoreLevels[1] > 10 {
			return nil, fmt.Errorf("gateway: profile %s: score_levels out of range", id)
		}
		s.Readout = ReadoutSpec{NProbs: DefaultNProbs, MassThreshold: DefaultMassThreshold, Spellings: []string{"A", " A"}}
		if r := d.Readout; r != nil {
			if r.NProbs != nil {
				if *r.NProbs < 5 || *r.NProbs > 1000 {
					return nil, fmt.Errorf("gateway: profile %s: n_probs out of range", id)
				}
				s.Readout.NProbs = *r.NProbs
			}
			if r.MassThreshold != nil {
				if !(*r.MassThreshold > 0 && *r.MassThreshold <= 1) {
					return nil, fmt.Errorf("gateway: profile %s: mass_threshold must be in (0,1]", id)
				}
				s.Readout.MassThreshold = *r.MassThreshold
			}
			if len(r.Spellings) > 0 {
				s.Readout.Spellings = r.Spellings
			}
			s.Readout.CachePrompt = r.CachePrompt
		}
		specs = append(specs, s)
	}
	sort.Slice(specs, func(i, j int) bool { return specs[i].ID < specs[j].ID })
	return specs, nil
}

// Limits returns the request limits of the profile. A decoder profile's practical option cap is
// the smaller of its catalog cap and the global cap (LLMCTL_DECIDE_MAX_OPTIONS); native and encoder
// profiles may use their own, larger cap (the hosted maximum is 255).
func (s ProfileSpec) Limits(base contract.Limits) contract.Limits {
	l := base
	l.MinScale, l.MaxScale = s.ScoreLevels[0], s.ScoreLevels[1]
	switch s.Protocol {
	case ProtoLetter:
		l.MaxOptions = min(s.MaxOptions, base.MaxOptions, 26)
		l.MaxPromptTokens = contract.PromptTokenBudget(s.Ctx)
	case ProtoNLI:
		l.MaxOptions = s.MaxOptions
		if s.Ctx > 0 {
			l.MaxPromptTokens, l.PairMode = s.Ctx, true
		}
	default: // native: the engine renders the prompt itself; its own overflow answer is mapped to 422
		l.MaxOptions = s.MaxOptions
	}
	return l
}

// BuildProfiles builds the contract profile set (ids in catalog order, per-profile limits).
func BuildProfiles(specs []ProfileSpec, def string, base contract.Limits) (*contract.Profiles, error) {
	if len(specs) == 0 {
		return nil, errors.New("gateway: no decision profiles in the catalog")
	}
	ids := make([]string, len(specs))
	lim := map[string]contract.Limits{}
	for i, s := range specs {
		ids[i] = s.ID
		lim[s.ID] = s.Limits(base)
	}
	return contract.NewProfiles(ids, def, lim)
}
