package gateway

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/url"
	"strings"
	"time"

	"github.com/vasic-digital/llmctl/internal/contract"
)

// ErrSmokeUnreachable: nothing is listening at the smoke URL (exit 6 of `llmctl-decide smoke`).
var ErrSmokeUnreachable = errors.New("smoke: engine unreachable")

// ErrSmokeUsage: the smoke configuration itself is invalid (exit 2).
var ErrSmokeUsage = errors.New("smoke: invalid configuration")

// SmokeConfig describes one deterministic one-question smoke against ONE engine.
type SmokeConfig struct {
	URL      string // loopback engine base URL
	Key      string // internal engine key ("" = unauthenticated engine)
	Protocol string // ProtoLetter | ProtoNLI | ProtoNative
	Options  int    // option count, 2..26 (default 2)
	// ExpectChoice, when set, must be the answer's argmax: the model-sanity half of the smoke
	// (the invoice question has one defensible answer, "billing").
	ExpectChoice string
	Timeout      time.Duration
}

// SmokeResult is the typed answer of a successful smoke.
type SmokeResult struct {
	Protocol      string                 `json:"protocol"`
	Type          string                 `json:"type"`
	Choice        string                 `json:"choice"`
	Confidence    float64                `json:"confidence"`
	Probabilities []contract.Probability `json:"-"`
	OK            bool                   `json:"ok"`
}

func smokeUsage(format string, a ...any) error {
	return fmt.Errorf("%w: %s", ErrSmokeUsage, fmt.Sprintf(format, a...))
}

// smokeBody builds the fixed request: one choice question, option 1 is the defensible answer.
func smokeBody(n int) string {
	var b strings.Builder
	b.WriteString(`{"model":"smoke","state":"Routing.","questions":{"q":{"type":"choice","instructions":"Which team handles invoices?","criteria":{"billing":"handles invoices","legal":"contracts"`)
	for i := 3; i <= n; i++ {
		fmt.Fprintf(&b, `,"team%d":"unrelated team %d"`, i, i)
	}
	b.WriteString(`}}}}`)
	return b.String()
}

// Smoke asks the engine one deterministic choice question through the production driver for the
// protocol and returns the typed answer. It succeeds only for a valid typed answer: finite
// probabilities summing to 1 (contract.BuildAnswer), and - when ExpectChoice is set - that choice.
func Smoke(ctx context.Context, cfg SmokeConfig) (*SmokeResult, error) {
	if cfg.Options == 0 {
		cfg.Options = 2
	}
	if cfg.Options < 2 || cfg.Options > 26 {
		return nil, smokeUsage("--options must be 2..26, got %d", cfg.Options)
	}
	switch cfg.Protocol {
	case ProtoLetter, ProtoNLI, ProtoNative:
	default:
		return nil, smokeUsage("unknown protocol %q (letter-logit|nli-onnx|systemone-native)", cfg.Protocol)
	}
	if cfg.URL == "" {
		return nil, smokeUsage("--url is required")
	}
	if err := checkLoopback(cfg.URL); err != nil {
		return nil, smokeUsage("%v", err)
	}
	if cfg.Timeout <= 0 {
		cfg.Timeout = 30 * time.Second
	}
	u, _ := url.Parse(cfg.URL)
	conn, err := net.DialTimeout("tcp", u.Host, 3*time.Second)
	if err != nil {
		return nil, fmt.Errorf("%w: %s", ErrSmokeUnreachable, u.Host)
	}
	_ = conn.Close()

	spec := ProfileSpec{
		ID: "smoke", Protocol: cfg.Protocol, MaxOptions: 26, ScoreLevels: [2]int{2, 10},
		Readout: ReadoutSpec{NProbs: DefaultNProbs, MassThreshold: DefaultMassThreshold, CachePrompt: false},
	}
	lim := contract.DefaultLimits()
	lim.MaxOptions = 26 // the smoke covers the whole letter range, whatever the serving default is
	profiles, err := BuildProfiles([]ProfileSpec{spec}, "smoke", lim)
	if err != nil {
		return nil, err
	}
	req, err := contract.ParseRequest([]byte(smokeBody(cfg.Options)), lim, profiles)
	if err != nil {
		return nil, fmt.Errorf("smoke: fixture request refused: %w", err)
	}
	ctx, cancel := context.WithTimeout(ctx, cfg.Timeout)
	defer cancel()
	drv := DefaultDrivers(Deterministic, true)[cfg.Protocol]
	answers, _, err := drv.Decide(ctx, Endpoint{URL: cfg.URL, Key: cfg.Key, Healthy: true, Instance: "smoke"}, spec, req)
	if err != nil {
		return nil, fmt.Errorf("smoke: backend failed: %w", err)
	}
	if len(answers) != 1 || answers[0].Answer.Type != "choice" || answers[0].Answer.Choice == "" {
		return nil, errors.New("smoke: backend returned no typed choice answer")
	}
	a := answers[0].Answer
	if len(a.Flags) > 0 {
		// the engine's first-token readout does not list every option letter: the profile's tokenisation /
		// readout protocol does not match the model, which is exactly what admission must catch
		return nil, fmt.Errorf("smoke: the engine readout is flagged (%s): an option letter is absent from its first-token alternatives", strings.Join(a.Flags, ","))
	}
	if cfg.ExpectChoice != "" && a.Choice != cfg.ExpectChoice {
		return nil, fmt.Errorf("smoke: model chose %q, expected %q", a.Choice, cfg.ExpectChoice)
	}
	return &SmokeResult{Protocol: cfg.Protocol, Type: a.Type, Choice: a.Choice, Confidence: a.Confidence,
		Probabilities: a.Probabilities, OK: true}, nil
}
