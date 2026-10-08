// Package registry adapts the Containers submodule (digital.vasic.containers)
// to llmctl: dynamic port allocation (pkg/network), the persistent service
// registry (pkg/serviceregistry), health probing (pkg/health) and endpoint/URL
// resolution (pkg/endpoint). It re-implements none of them (Helix §11.4.76);
// what it adds is only what the submodule lacks and llmctl needs: cross-process
// locking, process-identity liveness, an env-driven port strategy, change
// notification for the gateway (see evidence/containers-gaps.md).
package registry

import (
	"context"
	"errors"
	"os"
	"strconv"
	"time"

	"digital.vasic.containers/pkg/endpoint"
	"digital.vasic.containers/pkg/health"
)

// Strategy is the port assignment strategy.
type Strategy string

const (
	// Fixed uses each profile's documented port; a taken port fails loudly.
	Fixed Strategy = "fixed"
	// Dynamic takes a bind-tested free port from the configured range.
	Dynamic Strategy = "dynamic"
)

// Config is the resolved registry/port configuration.
type Config struct {
	StateDir string   // $LLMCTL_STATE_DIR (default ~/.local/state/llmctl)
	Strategy Strategy // LLMCTL_PORT_STRATEGY (default fixed)
	RangeLo  int      // LLMCTL_PORT_RANGE low (inclusive)
	RangeHi  int      // LLMCTL_PORT_RANGE high (inclusive)
	CACert   string   // LLMCTL_CACERT: the CA https health probes verify against ("" = https entries cannot be certified)
}

// Entry is one published service (FR-089).
type Entry struct {
	Name         string            `json:"name"`
	Host         string            `json:"host"`
	Port         int               `json:"port"`
	Protocol     string            `json:"protocol"`
	HealthPath   string            `json:"health_path,omitempty"`
	Labels       map[string]string `json:"labels,omitempty"` // kind, profile, protocol, instance, ...
	PID          int               `json:"pid"`
	Started      time.Time         `json:"started"`
	LoopbackOnly bool              `json:"loopback_only"`
	CmdToken     string            `json:"cmd_token"`
	Healthy      bool              `json:"healthy"`
	// UnhealthySince is the zero time while healthy.
	UnhealthySince time.Time `json:"unhealthy_since,omitzero"`
	// ProcFP identifies the specific process (boot id + start time + argv hash, see ProcFingerprint),
	// recorded at registration; liveness requires it to be unchanged.
	ProcFP string `json:"proc_fp,omitempty"`
	// UnknownSince is the zero time unless an https entry could not be certified (no CA).
	UnknownSince time.Time `json:"unknown_since,omitzero"`
}

// URL is the service's base URL, built by the Containers endpoint package (ResolvedURL):
// scheme from the protocol (https, else http - a "tcp" service has no URL scheme of its own), IPv6
// literals bracketed.
func (e Entry) URL() string {
	host := e.Host
	if e.Protocol == "https" {
		host = "https://" + host
	}
	ep := endpoint.NewEndpoint().WithHost(host).WithPort(strconv.Itoa(e.Port)).Build()
	return ep.ResolvedURL()
}

// Prober is satisfied by *health.DefaultChecker.
type Prober interface {
	Check(ctx context.Context, target health.HealthTarget) *health.HealthResult
}

// ProcessIdentity proves from the REAL process identity that pid is alive and
// is the program the entry was registered for.
type ProcessIdentity func(pid int, token string) bool

var errNotImplemented = errors.New("registry: not implemented")

// Well-known label keys of a published service.
const (
	LabelKind     = "kind"     // decide | gateway | ...
	LabelProfile  = "profile"  // the decision profile an engine serves
	LabelInstance = "instance" // instance number or name ("2", "decide-tiny.2")
	// LabelKeyFile names the 0600 file holding the per-instance internal key the engine expects.
	// The label carries only the PATH; the key never enters the registry.
	LabelKeyFile = "key_file"
)

// KeyFileState reports whether the entry names a key file and whether that file exists.
func (e Entry) KeyFileState() (named, present bool) {
	p := e.Labels[LabelKeyFile]
	if p == "" {
		return false, false
	}
	st, err := os.Stat(p)
	return true, err == nil && st.Mode().IsRegular()
}
