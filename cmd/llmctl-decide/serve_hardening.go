package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/vasic-digital/llmctl/internal/gateway"
	"github.com/vasic-digital/llmctl/internal/keyring"
	"github.com/vasic-digital/llmctl/internal/metrics"
)

// keyStaleGrace is how long the last good accepted-key set keeps being served after the key source
// stops yielding a usable set (an unreadable, unsafe or emptied file). After it the gateway FAILS
// CLOSED - no key is accepted - until the source is usable again (review A-13): editing a
// compromised key out of the env file, or making the file unsafe, must not leave the old key valid
// until a restart. The grace only bridges a transient read problem.
const keyStaleGrace = 5 * time.Second

// keyCache serves the accepted keys with a one-second cache so rotation needs no restart without
// re-reading the file per request. Its failure behaviour is the point of this type: a read error
// or an empty set is counted (metric) and reported once per distinct problem on stderr (no secret),
// and past keyStaleGrace the cache stops serving the last good set.
type keyCache struct {
	mu       sync.Mutex
	read     func() ([]keyring.Secret, error)
	now      func() time.Time
	stderr   io.Writer
	reg      *metrics.Registry
	last     []keyring.Secret
	at       time.Time // last refresh attempt
	goodAt   time.Time // last successful refresh
	lastProb string
}

func newKeyCache(initial []keyring.Secret, read func() ([]keyring.Secret, error), now func() time.Time, stderr io.Writer, reg *metrics.Registry) *keyCache {
	t := now()
	return &keyCache{read: read, now: now, stderr: stderr, reg: reg, last: initial, at: time.Time{}, goodAt: t}
}

func (c *keyCache) keys() []keyring.Secret {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	if !c.at.IsZero() && now.Sub(c.at) < time.Second {
		return c.serving(now)
	}
	c.at = now
	ks, err := c.read()
	switch {
	case err == nil && len(ks) > 0:
		c.last, c.goodAt = ks, now
		if c.lastProb != "" {
			c.report("llmctl serve: the access-key source is usable again; accepting keys")
			c.lastProb = ""
		}
	default:
		prob := "the access-key source yielded no usable key"
		if err != nil {
			prob = "the access-key source cannot be used: " + err.Error()
		}
		if c.reg != nil {
			c.reg.Inc(metrics.KeySourceError)
		}
		if prob != c.lastProb {
			c.lastProb = prob
			c.report(fmt.Sprintf("llmctl serve: %s; the previous keys stay valid for %s, then every request is refused until it is fixed (revoke a key with `llmctl key rotate`)",
				prob, keyStaleGrace))
		}
	}
	return c.serving(now)
}

func (c *keyCache) serving(now time.Time) []keyring.Secret {
	if now.Sub(c.goodAt) > keyStaleGrace {
		return nil // fail closed
	}
	return c.last
}

func (c *keyCache) report(msg string) {
	if c.stderr != nil {
		fmt.Fprintln(c.stderr, msg)
	}
}

// removeOwnPidfile deletes the pidfile only if it still names pid: an instance that exits must not
// remove the pidfile another instance has written since (review A-15).
func removeOwnPidfile(path string, pid int) {
	if info, err := gateway.ReadPidfile(path); err == nil && info.PID == pid {
		_ = os.Remove(path)
	}
}

// childEnviron is the environment of the detached gateway: the parent's environment without the
// removed legacy internal-key variable, so a key an operator still exports never lands in the
// gateway's /proc/<pid>/environ (G-040, review A-15).
func childEnviron(environ []string) []string {
	out := make([]string, 0, len(environ))
	for _, kv := range environ {
		if strings.HasPrefix(kv, legacyKeyVar+"=") {
			continue
		}
		out = append(out, kv)
	}
	return out
}

// detachedCmd is the command that re-executes the gateway in the background: own session, output to
// the log file, and an environment that never carries the legacy internal-key variable.
func detachedCmd(exe string, args []string, logf *os.File) *exec.Cmd {
	cmd := exec.Command(exe, args...)
	cmd.Stdout, cmd.Stderr = logf, logf
	cmd.Env = childEnviron(os.Environ())
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	return cmd
}
