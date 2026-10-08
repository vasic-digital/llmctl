package calibrate

import (
	"errors"
	"fmt"
	"math"
	"sort"
)

// Method names of the supported recalibrators.
const (
	MethodTemperature = "temperature"
	MethodPlatt       = "platt"
	MethodIsotonic    = "isotonic"
)

// Methods lists the supported methods in documentation order.
var Methods = []string{MethodTemperature, MethodPlatt, MethodIsotonic}

// ErrSingleClass is returned when every label has the same outcome: there is nothing to fit.
var ErrSingleClass = errors.New("every labelled answer has the same outcome (all correct or all wrong): nothing to calibrate")

// Calibrator maps a raw confidence in [0,1] to a calibrated one. Apply is monotone non-decreasing.
type Calibrator interface {
	Apply(p float64) float64
	Method() string
	Params() map[string]any
}

const eps = 1e-6

func clamp(p float64) float64 { return math.Min(1-eps, math.Max(eps, p)) }
func logit(p float64) float64 { p = clamp(p); return math.Log(p / (1 - p)) }
func sigmoid(x float64) float64 {
	if x >= 0 {
		return 1 / (1 + math.Exp(-x))
	}
	e := math.Exp(x)
	return e / (1 + e)
}

func classes(d []Pair) (pos, neg int) {
	for _, x := range d {
		if x.Y == 1 {
			pos++
		} else {
			neg++
		}
	}
	return
}

// softplus(x) = log(1+exp(x)), stable.
func softplus(x float64) float64 {
	if x > 30 {
		return x
	}
	return math.Log1p(math.Exp(x))
}

// ---- temperature scaling (binary, on the logit of the predicted-answer probability)

// Temperature rescales the logit of the confidence by 1/T: p' = sigmoid(logit(p)/T).
type Temperature struct{ T float64 }

// Apply implements Calibrator.
func (c *Temperature) Apply(p float64) float64 { return sigmoid(logit(p) / c.T) }

// Method implements Calibrator.
func (c *Temperature) Method() string { return MethodTemperature }

// Params implements Calibrator.
func (c *Temperature) Params() map[string]any { return map[string]any{"temperature": c.T} }

// FitTemperature minimises the negative log-likelihood of the outcomes over the single parameter
// a = 1/T. The NLL is convex in a, so a golden-section search over [0.01, 100] with a fixed
// iteration count is deterministic and exact to machine precision.
func FitTemperature(d []Pair) (*Temperature, error) {
	if pos, neg := classes(d); pos == 0 || neg == 0 {
		return nil, ErrSingleClass
	}
	z := make([]float64, len(d))
	for i, x := range d {
		z[i] = logit(x.P)
	}
	nll := func(a float64) float64 {
		s := 0.0
		for i, x := range d {
			if x.Y == 1 {
				s += softplus(-a * z[i])
			} else {
				s += softplus(a * z[i])
			}
		}
		return s
	}
	lo, hi := 0.01, 100.0
	const gr = 0.6180339887498949
	x1, x2 := hi-gr*(hi-lo), lo+gr*(hi-lo)
	f1, f2 := nll(x1), nll(x2)
	for i := 0; i < 200; i++ {
		if f1 < f2 {
			hi, x2, f2 = x2, x1, f1
			x1 = hi - gr*(hi-lo)
			f1 = nll(x1)
		} else {
			lo, x1, f1 = x1, x2, f2
			x2 = lo + gr*(hi-lo)
			f2 = nll(x2)
		}
	}
	a := (lo + hi) / 2
	return &Temperature{T: 1 / a}, nil
}

// ---- Platt scaling

// Platt is p' = sigmoid(A*logit(p) + B).
type Platt struct{ A, B float64 }

// Apply implements Calibrator.
func (c *Platt) Apply(p float64) float64 { return sigmoid(c.A*logit(p) + c.B) }

// Method implements Calibrator.
func (c *Platt) Method() string { return MethodPlatt }

// Params implements Calibrator.
func (c *Platt) Params() map[string]any { return map[string]any{"a": c.A, "b": c.B} }

// plattLambda is the ridge weight pulling (A, B) toward the identity (1, 0). It keeps the Hessian
// positive definite and the solution finite on perfectly separable data.
const plattLambda = 1e-3

// FitPlatt fits A and B by Newton's method with a backtracking line search on the regularised
// negative log-likelihood, using Platt's smoothed targets (N+ + 1)/(N+ + 2) and 1/(N- + 2).
func FitPlatt(d []Pair) (*Platt, error) {
	pos, neg := classes(d)
	if pos == 0 || neg == 0 {
		return nil, ErrSingleClass
	}
	tHi := (float64(pos) + 1) / (float64(pos) + 2)
	tLo := 1 / (float64(neg) + 2)
	z := make([]float64, len(d))
	t := make([]float64, len(d))
	for i, x := range d {
		z[i] = logit(x.P)
		if x.Y == 1 {
			t[i] = tHi
		} else {
			t[i] = tLo
		}
	}
	obj := func(a, b float64) float64 {
		s := 0.0
		for i := range d {
			u := a*z[i] + b
			// -[t log s(u) + (1-t) log(1-s(u))] = softplus(u) - t*u  (stable form)
			s += softplus(u) - t[i]*u
		}
		return s + 0.5*plattLambda*((a-1)*(a-1)+b*b)
	}
	a, b := 1.0, 0.0
	f := obj(a, b)
	for it := 0; it < 100; it++ {
		var gA, gB, hAA, hAB, hBB float64
		for i := range d {
			p := sigmoid(a*z[i] + b)
			w := p * (1 - p)
			gA += (p - t[i]) * z[i]
			gB += p - t[i]
			hAA += w * z[i] * z[i]
			hAB += w * z[i]
			hBB += w
		}
		gA += plattLambda * (a - 1)
		gB += plattLambda * b
		hAA += plattLambda
		hBB += plattLambda
		det := hAA*hBB - hAB*hAB
		if det <= 0 || math.IsNaN(det) {
			break
		}
		dA := -(hBB*gA - hAB*gB) / det
		dB := -(-hAB*gA + hAA*gB) / det
		if math.Abs(dA)+math.Abs(dB) < 1e-12 {
			break
		}
		step, moved, converged := 1.0, false, false
		for ls := 0; ls < 40; ls++ {
			na, nb := a+step*dA, b+step*dB
			if nf := obj(na, nb); nf <= f {
				converged = f-nf <= 1e-13*math.Max(1, math.Abs(f))
				a, b, f, moved = na, nb, nf, true
				break
			}
			step /= 2
		}
		if !moved || converged {
			break
		}
	}
	return &Platt{A: a, B: b}, nil
}

// ---- isotonic regression (pool adjacent violators)

// Isotonic is a monotone non-decreasing step fit stored as knots: block centres X (mean raw
// confidence) and block values Y (observed accuracy). Apply interpolates linearly between knots
// and clamps outside them.
type Isotonic struct {
	X, Y []float64
	N    int
}

// Apply implements Calibrator.
func (c *Isotonic) Apply(p float64) float64 {
	n := len(c.X)
	if n == 0 {
		return p
	}
	if p <= c.X[0] {
		return c.Y[0]
	}
	if p >= c.X[n-1] {
		return c.Y[n-1]
	}
	i := sort.SearchFloat64s(c.X, p) // first X >= p
	if c.X[i] == p {
		return c.Y[i]
	}
	x0, x1 := c.X[i-1], c.X[i]
	return c.Y[i-1] + (c.Y[i]-c.Y[i-1])*(p-x0)/(x1-x0)
}

// Method implements Calibrator.
func (c *Isotonic) Method() string { return MethodIsotonic }

// Params implements Calibrator.
func (c *Isotonic) Params() map[string]any {
	return map[string]any{"knots_x": c.X, "knots_y": c.Y, "n_knots": len(c.X)}
}

// FitIsotonic requires at least MinIsotonic labels (data-model: isotonic only with >= 1000 labels).
func FitIsotonic(d []Pair) (*Isotonic, error) {
	if len(d) < MinIsotonic {
		return nil, fmt.Errorf("isotonic needs at least %d labels (have %d): a step function fitted to fewer would memorise noise", MinIsotonic, len(d))
	}
	return FitIsotonicUnchecked(d)
}

// FitIsotonicUnchecked is FitIsotonic without the sample-size floor (maths tests, cross-fit folds).
func FitIsotonicUnchecked(d []Pair) (*Isotonic, error) {
	if pos, neg := classes(d); pos == 0 || neg == 0 {
		return nil, ErrSingleClass
	}
	s := append([]Pair(nil), d...)
	sort.SliceStable(s, func(i, j int) bool { return s[i].P < s[j].P })
	type block struct {
		w          float64 // weight (count)
		sumY, sumX float64
	}
	var bl []block
	for i := 0; i < len(s); {
		j := i
		var b block
		for j < len(s) && s[j].P == s[i].P { // ties are pooled before the PAV pass
			b.w++
			b.sumY += float64(s[j].Y)
			b.sumX += s[j].P
			j++
		}
		bl = append(bl, b)
		i = j
		for len(bl) > 1 {
			a, c := bl[len(bl)-2], bl[len(bl)-1]
			if a.sumY/a.w <= c.sumY/c.w {
				break
			}
			bl = bl[:len(bl)-2]
			bl = append(bl, block{w: a.w + c.w, sumY: a.sumY + c.sumY, sumX: a.sumX + c.sumX})
		}
	}
	out := &Isotonic{N: len(d)}
	for _, b := range bl {
		out.X = append(out.X, b.sumX/b.w)
		out.Y = append(out.Y, b.sumY/b.w)
	}
	return out, nil
}

// ---- generic entry points

// Fit fits the named method.
func Fit(method string, d []Pair) (Calibrator, error) {
	switch method {
	case MethodTemperature:
		return FitTemperature(d)
	case MethodPlatt:
		return FitPlatt(d)
	case MethodIsotonic:
		return FitIsotonic(d)
	}
	return nil, fmt.Errorf("unknown method %q (temperature|platt|isotonic)", method)
}

// ApplyAll recalibrates every pair's confidence.
func ApplyAll(c Calibrator, d []Pair) []Pair {
	out := make([]Pair, len(d))
	for i, x := range d {
		out[i] = Pair{P: c.Apply(x.P), Y: x.Y}
	}
	return out
}

// CrossFit is a deterministic k-fold held-out estimate: fold = index mod k; each fold is
// recalibrated by a fit on the other folds, and the held-out predictions are pooled. It is the
// honest counterpart of the in-sample "after" numbers. ok is false when a training split cannot be
// fitted (one class, or isotonic below its floor).
func CrossFit(d []Pair, method string, k int) (Measurement, bool) {
	if k < 2 || len(d) < k {
		return Measurement{}, false
	}
	var held []Pair
	for f := 0; f < k; f++ {
		var train []Pair
		var test []Pair
		for i, x := range d {
			if i%k == f {
				test = append(test, x)
			} else {
				train = append(train, x)
			}
		}
		var c Calibrator
		var err error
		if method == MethodIsotonic {
			c, err = FitIsotonicUnchecked(train)
		} else {
			c, err = Fit(method, train)
		}
		if err != nil {
			return Measurement{}, false
		}
		held = append(held, ApplyAll(c, test)...)
	}
	return metrics(held), true
}
