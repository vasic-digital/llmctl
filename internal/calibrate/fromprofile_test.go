package calibrate

import (
	"encoding/json"
	"math"
	"strings"
	"testing"
)

// roundTrip puts a fitted calibrator through the same JSON file form a profile is stored in.
func roundTrip(t *testing.T, c Calibrator, n int) *Profile {
	t.Helper()
	p := &Profile{Version: ProfileVersion, Profile: "decide-tiny", Bound: true,
		ModelSHA256: strings.Repeat("a", 64), TemplateHash: strings.Repeat("b", 64),
		Method: c.Method(), Params: c.Params(), NSamples: n}
	b, err := json.Marshal(p)
	if err != nil {
		t.Fatal(err)
	}
	var out Profile
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatal(err)
	}
	return &out
}

func TestFromProfileReproducesFitBitForBit(t *testing.T) {
	data := syntheticOverconfident(1500, 11, 0.5)
	for _, m := range Methods {
		fit, err := Fit(m, data)
		if err != nil {
			t.Fatalf("%s: %v", m, err)
		}
		back, err := FromProfile(roundTrip(t, fit, len(data)))
		if err != nil {
			t.Fatalf("%s: FromProfile: %v", m, err)
		}
		if back.Method() != m {
			t.Errorf("%s: method = %s", m, back.Method())
		}
		for i, d := range data {
			if a, b := fit.Apply(d.P), back.Apply(d.P); math.Float64bits(a) != math.Float64bits(b) {
				t.Fatalf("%s: point %d p=%v: Fit gives %v, FromProfile gives %v (not bit-identical)", m, i, d.P, a, b)
			}
		}
		for _, p := range []float64{0, 0.001, 0.37, 0.5, 0.999, 1} { // off the training points too
			if a, b := fit.Apply(p), back.Apply(p); math.Float64bits(a) != math.Float64bits(b) {
				t.Errorf("%s: Apply(%v): %v vs %v", m, p, a, b)
			}
		}
	}
}

func TestFromProfileIsotonicMonotone(t *testing.T) {
	fit, err := Fit(MethodIsotonic, syntheticOverconfident(2000, 5, 0.4))
	if err != nil {
		t.Fatal(err)
	}
	back, err := FromProfile(roundTrip(t, fit, 2000))
	if err != nil {
		t.Fatal(err)
	}
	prev := -1.0
	for i := 0; i <= 1000; i++ {
		v := back.Apply(float64(i) / 1000)
		if v < prev-1e-15 {
			t.Fatalf("not monotone at %d: %v after %v", i, v, prev)
		}
		if v < 0 || v > 1 {
			t.Fatalf("Apply out of [0,1]: %v", v)
		}
		prev = v
	}
}

func TestFromProfileRefusesMalformed(t *testing.T) {
	mk := func(method string, params map[string]any) *Profile {
		return &Profile{Method: method, Params: params, Bound: true}
	}
	bad := map[string]*Profile{
		"unknown method":      mk("magic", map[string]any{"temperature": 1.0}),
		"temperature missing": mk(MethodTemperature, map[string]any{}),
		"temperature zero":    mk(MethodTemperature, map[string]any{"temperature": 0.0}),
		"temperature neg":     mk(MethodTemperature, map[string]any{"temperature": -2.0}),
		"temperature NaN":     mk(MethodTemperature, map[string]any{"temperature": math.NaN()}),
		"temperature string":  mk(MethodTemperature, map[string]any{"temperature": "1.5"}),
		"platt missing b":     mk(MethodPlatt, map[string]any{"a": 1.0}),
		"platt inf":           mk(MethodPlatt, map[string]any{"a": math.Inf(1), "b": 0.0}),
		"isotonic no knots":   mk(MethodIsotonic, map[string]any{"knots_x": []any{}, "knots_y": []any{}}),
		"isotonic len":        mk(MethodIsotonic, map[string]any{"knots_x": []any{0.1, 0.2}, "knots_y": []any{0.1}}),
		"isotonic x order":    mk(MethodIsotonic, map[string]any{"knots_x": []any{0.5, 0.2}, "knots_y": []any{0.1, 0.2}}),
		"isotonic y down":     mk(MethodIsotonic, map[string]any{"knots_x": []any{0.2, 0.5}, "knots_y": []any{0.9, 0.2}}),
		"isotonic y range":    mk(MethodIsotonic, map[string]any{"knots_x": []any{0.2, 0.5}, "knots_y": []any{0.1, 1.2}}),
	}
	for name, p := range bad {
		if c, err := FromProfile(p); err == nil {
			t.Errorf("%s: accepted (%v)", name, c)
		}
	}
	if _, err := FromProfile(nil); err == nil {
		t.Error("nil profile accepted")
	}
}
