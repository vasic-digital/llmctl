package server

import (
	"fmt"
	"math"
	"os"
	"strconv"
	"time"
)

// Limits are the transport limits of the gateway (contracts/env-vars.md, "Gateway").
// The request-contract limits (options, questions, state budget) are contract.Limits and
// belong to the caller; this struct only bounds connections, time, bodies and queueing.
type Limits struct {
	MaxConns          int           // LLMCTL_DECIDE_MAX_CONNS: global concurrent connections
	MaxConnsPerSource int           // LLMCTL_DECIDE_MAX_CONNS_PER_SOURCE
	Queue             int           // LLMCTL_DECIDE_QUEUE: bounded wait queue for a decision slot (0 = none)
	Concurrency       int           // LLMCTL_DECIDE_CONCURRENCY (additional): simultaneous Backend.Decide calls
	HandshakeTimeout  time.Duration // LLMCTL_DECIDE_HANDSHAKE_TIMEOUT
	ReadDeadline      time.Duration // LLMCTL_DECIDE_READ_DEADLINE: absolute, whole request (headers + body)
	Timeout           time.Duration // LLMCTL_DECIDE_TIMEOUT: end-to-end budget per request (queue wait + Decide)
	DrainGrace        time.Duration // LLMCTL_DECIDE_DRAIN_GRACE
	MaxBody           int64         // LLMCTL_DECIDE_MAX_BODY
	AuthFailLimit     int           // LLMCTL_DECIDE_AUTH_FAIL_LIMIT: failed authentications per window per source
	AuthFailWindow    time.Duration // window of AuthFailLimit (fixed: one minute)
	MaxHeaderBytes    int           // request line + headers cap (fixed: 16 KiB)
	IdleTimeout       time.Duration // LLMCTL_DECIDE_IDLE_TIMEOUT: keep-alive idle time of an authenticated connection

	// Admission (FR-022, review A-01). Connections start unauthenticated; the unauthenticated pool is
	// smaller than MaxConns so that capacity stays reserved for connections that proved the key.
	MaxUnauthConns        int           // LLMCTL_DECIDE_MAX_UNAUTH_CONNS: global unauthenticated connections
	MaxUnauthPerSource    int           // LLMCTL_DECIDE_MAX_UNAUTH_PER_SOURCE: per IPv4 address / IPv6 /64
	MaxUnauthPerAggregate int           // LLMCTL_DECIDE_MAX_UNAUTH_PER_PREFIX: per IPv6 /48 (IPv4: same as per source)
	PreAuthTimeout        time.Duration // LLMCTL_DECIDE_PREAUTH_TIMEOUT: time to authenticate before the connection is closed
}

// DefaultLimits are the documented defaults.
func DefaultLimits() Limits {
	return Limits{
		MaxConns: 64, MaxConnsPerSource: 8, Queue: 64, Concurrency: 4,
		HandshakeTimeout: 3 * time.Second, ReadDeadline: 10 * time.Second, Timeout: 8 * time.Second,
		DrainGrace: 15 * time.Second, MaxBody: 262144, AuthFailLimit: 10,
		AuthFailWindow: time.Minute, MaxHeaderBytes: 16 << 10, IdleTimeout: 60 * time.Second,
		MaxUnauthConns: 32, MaxUnauthPerSource: 8, MaxUnauthPerAggregate: 16, PreAuthTimeout: 3 * time.Second,
	}
}

// Validate reports an unusable Limits value (zero or negative where that is meaningless).
func (l Limits) Validate() error {
	pos := func(name string, ok bool) error {
		if !ok {
			return &LimitError{Var: name, Reason: "must be positive"}
		}
		return nil
	}
	for _, e := range []error{
		pos("MaxConns", l.MaxConns > 0), pos("MaxConnsPerSource", l.MaxConnsPerSource > 0),
		pos("Concurrency", l.Concurrency > 0), pos("HandshakeTimeout", l.HandshakeTimeout > 0),
		pos("ReadDeadline", l.ReadDeadline > 0), pos("Timeout", l.Timeout > 0),
		pos("DrainGrace", l.DrainGrace > 0), pos("MaxBody", l.MaxBody > 0),
		pos("AuthFailLimit", l.AuthFailLimit > 0), pos("AuthFailWindow", l.AuthFailWindow > 0),
		pos("MaxHeaderBytes", l.MaxHeaderBytes > 0), pos("IdleTimeout", l.IdleTimeout > 0),
		pos("MaxUnauthConns", l.MaxUnauthConns > 0), pos("MaxUnauthPerSource", l.MaxUnauthPerSource > 0),
		pos("MaxUnauthPerAggregate", l.MaxUnauthPerAggregate > 0), pos("PreAuthTimeout", l.PreAuthTimeout > 0),
	} {
		if e != nil {
			return e
		}
	}
	if l.Queue < 0 {
		return &LimitError{Var: "Queue", Reason: "must not be negative"}
	}
	if l.MaxConnsPerSource > l.MaxConns {
		return &LimitError{Var: "MaxConnsPerSource", Reason: "must not exceed MaxConns"}
	}
	return nil
}

// LimitError is a rejected limit value. It names the variable and the rule; the offending
// value is quoted truncated (limits are not secrets).
type LimitError struct {
	Var    string
	Value  string
	Reason string
}

func (e *LimitError) Error() string {
	if e.Value == "" {
		return fmt.Sprintf("invalid %s: %s", e.Var, e.Reason)
	}
	v := e.Value
	if len(v) > 32 {
		v = v[:32] + "..."
	}
	return fmt.Sprintf("invalid %s=%q: %s", e.Var, v, e.Reason)
}

const maxSeconds = 86400

type intRule struct {
	name string
	min  int64
	set  func(*Limits, int64)
}

type durRule struct {
	name string
	set  func(*Limits, time.Duration)
}

var intRules = []intRule{
	{"LLMCTL_DECIDE_MAX_CONNS", 1, func(l *Limits, v int64) { l.MaxConns = int(v) }},
	{"LLMCTL_DECIDE_MAX_CONNS_PER_SOURCE", 1, func(l *Limits, v int64) { l.MaxConnsPerSource = int(v) }},
	{"LLMCTL_DECIDE_QUEUE", 0, func(l *Limits, v int64) { l.Queue = int(v) }},
	{"LLMCTL_DECIDE_CONCURRENCY", 1, func(l *Limits, v int64) { l.Concurrency = int(v) }},
	{"LLMCTL_DECIDE_MAX_BODY", 1, func(l *Limits, v int64) { l.MaxBody = v }},
	{"LLMCTL_DECIDE_AUTH_FAIL_LIMIT", 1, func(l *Limits, v int64) { l.AuthFailLimit = int(v) }},
	{"LLMCTL_DECIDE_MAX_UNAUTH_CONNS", 1, func(l *Limits, v int64) { l.MaxUnauthConns = int(v) }},
	{"LLMCTL_DECIDE_MAX_UNAUTH_PER_SOURCE", 1, func(l *Limits, v int64) { l.MaxUnauthPerSource = int(v) }},
	{"LLMCTL_DECIDE_MAX_UNAUTH_PER_PREFIX", 1, func(l *Limits, v int64) { l.MaxUnauthPerAggregate = int(v) }},
}

var durRules = []durRule{
	{"LLMCTL_DECIDE_HANDSHAKE_TIMEOUT", func(l *Limits, d time.Duration) { l.HandshakeTimeout = d }},
	{"LLMCTL_DECIDE_READ_DEADLINE", func(l *Limits, d time.Duration) { l.ReadDeadline = d }},
	{"LLMCTL_DECIDE_TIMEOUT", func(l *Limits, d time.Duration) { l.Timeout = d }},
	{"LLMCTL_DECIDE_DRAIN_GRACE", func(l *Limits, d time.Duration) { l.DrainGrace = d }},
	{"LLMCTL_DECIDE_PREAUTH_TIMEOUT", func(l *Limits, d time.Duration) { l.PreAuthTimeout = d }},
	{"LLMCTL_DECIDE_IDLE_TIMEOUT", func(l *Limits, d time.Duration) { l.IdleTimeout = d }},
}

// FromLookup builds Limits from DefaultLimits overridden by every LLMCTL_DECIDE_* limit variable
// get reports as set. A set-but-invalid value (blank, non-numeric, negative, zero where
// meaningless, overflowing, "3s", "NaN"...) is an error naming the variable; nothing panics.
// Durations are numeric seconds (fractions allowed).
func FromLookup(get func(string) (string, bool)) (Limits, error) {
	l := DefaultLimits()
	perSourceSet := false
	set := map[string]bool{}
	for _, r := range intRules {
		s, ok := get(r.name)
		if !ok {
			continue
		}
		v, err := strconv.ParseInt(s, 10, 64)
		if err != nil {
			return Limits{}, &LimitError{Var: r.name, Value: s, Reason: "must be a whole number"}
		}
		if v < r.min {
			return Limits{}, &LimitError{Var: r.name, Value: s, Reason: fmt.Sprintf("must be at least %d", r.min)}
		}
		if v > math.MaxInt32 {
			return Limits{}, &LimitError{Var: r.name, Value: s, Reason: "is too large"}
		}
		r.set(&l, v)
		set[r.name] = true
		if r.name == "LLMCTL_DECIDE_MAX_CONNS_PER_SOURCE" {
			perSourceSet = true
		}
	}
	for _, r := range durRules {
		s, ok := get(r.name)
		if !ok {
			continue
		}
		f, err := strconv.ParseFloat(s, 64)
		if err != nil || math.IsNaN(f) || math.IsInf(f, 0) {
			return Limits{}, &LimitError{Var: r.name, Value: s, Reason: "must be a number of seconds"}
		}
		if f <= 0 || f > maxSeconds {
			return Limits{}, &LimitError{Var: r.name, Value: s, Reason: fmt.Sprintf("must be above 0 and at most %d seconds", maxSeconds)}
		}
		r.set(&l, time.Duration(f*float64(time.Second)))
	}
	if l.MaxConnsPerSource > l.MaxConns {
		if perSourceSet {
			return Limits{}, &LimitError{Var: "LLMCTL_DECIDE_MAX_CONNS_PER_SOURCE", Reason: "must not exceed LLMCTL_DECIDE_MAX_CONNS"}
		}
		l.MaxConnsPerSource = l.MaxConns // default per-source clamps to a smaller explicit global cap
	}
	// Unauthenticated budgets must nest inside the connection budgets. An explicit value that
	// breaks the nesting is refused by name; a default that no longer fits (a smaller explicit
	// MAX_CONNS) is clamped, like the per-source default.
	nest := func(name string, v *int, hi int, hiName string) error {
		if *v <= hi {
			return nil
		}
		if set[name] {
			return &LimitError{Var: name, Reason: "must not exceed " + hiName}
		}
		*v = hi
		return nil
	}
	for _, e := range []error{
		nest("LLMCTL_DECIDE_MAX_UNAUTH_CONNS", &l.MaxUnauthConns, l.MaxConns, "LLMCTL_DECIDE_MAX_CONNS"),
		nest("LLMCTL_DECIDE_MAX_UNAUTH_PER_SOURCE", &l.MaxUnauthPerSource, l.MaxConnsPerSource, "LLMCTL_DECIDE_MAX_CONNS_PER_SOURCE"),
		nest("LLMCTL_DECIDE_MAX_UNAUTH_PER_SOURCE", &l.MaxUnauthPerSource, l.MaxUnauthConns, "LLMCTL_DECIDE_MAX_UNAUTH_CONNS"),
		nest("LLMCTL_DECIDE_MAX_UNAUTH_PER_PREFIX", &l.MaxUnauthPerAggregate, l.MaxUnauthConns, "LLMCTL_DECIDE_MAX_UNAUTH_CONNS"),
	} {
		if e != nil {
			return Limits{}, e
		}
	}
	if l.MaxUnauthPerAggregate < l.MaxUnauthPerSource {
		if set["LLMCTL_DECIDE_MAX_UNAUTH_PER_PREFIX"] {
			return Limits{}, &LimitError{Var: "LLMCTL_DECIDE_MAX_UNAUTH_PER_PREFIX", Reason: "must be at least LLMCTL_DECIDE_MAX_UNAUTH_PER_SOURCE"}
		}
		l.MaxUnauthPerAggregate = l.MaxUnauthPerSource
	}
	return l, l.Validate()
}

// FromEnv is FromLookup over a map (for example keyring.Environ).
func FromEnv(env map[string]string) (Limits, error) {
	return FromLookup(func(k string) (string, bool) { v, ok := env[k]; return v, ok })
}

// FromOSEnv is FromLookup over the real process environment.
func FromOSEnv() (Limits, error) { return FromLookup(os.LookupEnv) }
