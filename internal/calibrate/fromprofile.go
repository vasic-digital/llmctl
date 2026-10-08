package calibrate

import (
	"errors"
	"fmt"
	"math"
)

// FromProfile rebuilds the calibrator a profile was fitted with from its stored parameters. It is
// the inverse of Fit for the parameters Calibrator.Params reports: the parameters survive a JSON
// round trip exactly (Go writes the shortest decimal that parses back to the same float64), so
// FromProfile(Fit(x)) applies bit-for-bit like Fit(x).
//
// FromProfile validates the parameters (a hand-edited or corrupted file must be refused, never
// applied): temperature finite and above 0; Platt a and b finite; isotonic knots of equal length,
// at least one, X strictly increasing, Y non-decreasing and within [0,1]. It does NOT check the
// model/template binding - that is LoadProfile's job and runs first.
func FromProfile(p *Profile) (Calibrator, error) {
	if p == nil {
		return nil, errors.New("calibrate: no profile")
	}
	switch p.Method {
	case MethodTemperature:
		t, err := paramFloat(p.Params, "temperature")
		if err != nil {
			return nil, err
		}
		if !(t > 0) {
			return nil, fmt.Errorf("calibrate: temperature must be above 0 (got %v)", t)
		}
		return &Temperature{T: t}, nil
	case MethodPlatt:
		a, err := paramFloat(p.Params, "a")
		if err != nil {
			return nil, err
		}
		b, err := paramFloat(p.Params, "b")
		if err != nil {
			return nil, err
		}
		return &Platt{A: a, B: b}, nil
	case MethodIsotonic:
		xs, err := paramFloats(p.Params, "knots_x")
		if err != nil {
			return nil, err
		}
		ys, err := paramFloats(p.Params, "knots_y")
		if err != nil {
			return nil, err
		}
		if len(xs) == 0 || len(xs) != len(ys) {
			return nil, fmt.Errorf("calibrate: isotonic needs equally many knots_x and knots_y, at least one (got %d and %d)", len(xs), len(ys))
		}
		for i := range xs {
			if i > 0 && !(xs[i] > xs[i-1]) {
				return nil, errors.New("calibrate: isotonic knots_x must be strictly increasing")
			}
			if ys[i] < 0 || ys[i] > 1 {
				return nil, errors.New("calibrate: isotonic knots_y must lie within [0,1]")
			}
			if i > 0 && ys[i] < ys[i-1] {
				return nil, errors.New("calibrate: isotonic knots_y must not decrease")
			}
		}
		return &Isotonic{X: xs, Y: ys, N: p.NSamples}, nil
	}
	return nil, fmt.Errorf("calibrate: unknown method %q (temperature|platt|isotonic)", p.Method)
}

func paramFloat(m map[string]any, key string) (float64, error) {
	v, ok := m[key]
	if !ok {
		return 0, fmt.Errorf("calibrate: parameter %q is missing", key)
	}
	f, ok := v.(float64)
	if !ok || math.IsNaN(f) || math.IsInf(f, 0) {
		return 0, fmt.Errorf("calibrate: parameter %q is not a finite number", key)
	}
	return f, nil
}

// paramFloats reads a list of numbers stored either as the JSON-decoded []any or as the in-memory
// []float64 a freshly fitted calibrator reports.
func paramFloats(m map[string]any, key string) ([]float64, error) {
	v, ok := m[key]
	if !ok {
		return nil, fmt.Errorf("calibrate: parameter %q is missing", key)
	}
	switch l := v.(type) {
	case []float64:
		for _, f := range l {
			if math.IsNaN(f) || math.IsInf(f, 0) {
				return nil, fmt.Errorf("calibrate: parameter %q holds a non-finite number", key)
			}
		}
		return append([]float64(nil), l...), nil
	case []any:
		out := make([]float64, len(l))
		for i, e := range l {
			f, ok := e.(float64)
			if !ok || math.IsNaN(f) || math.IsInf(f, 0) {
				return nil, fmt.Errorf("calibrate: parameter %q holds a value that is not a finite number", key)
			}
			out[i] = f
		}
		return out, nil
	}
	return nil, fmt.Errorf("calibrate: parameter %q is not a list of numbers", key)
}
