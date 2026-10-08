package registry

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// ConfigFromEnv resolves the registry/port configuration from the environment
// (get is os.Getenv in production, a map lookup in tests).
//
//	LLMCTL_STATE_DIR       state root (default $XDG_STATE_HOME/llmctl, else $HOME/.local/state/llmctl)
//	LLMCTL_PORT_STRATEGY   fixed (default) | dynamic
//	LLMCTL_PORT_RANGE      LO-HI for the dynamic strategy (default: this user's 1000-port block, see DefaultRangeForUID)
//	LLMCTL_CACERT         the llmctl CA certificate that https health probes verify against
//	                       (default $LLMCTL_HOME/cert/ca/ca.crt, $LLMCTL_HOME defaulting to ~/llmctl)
func ConfigFromEnv(get func(string) string) (Config, error) {
	c := Config{Strategy: Fixed}
	c.RangeLo, c.RangeHi = DefaultRangeForUID(currentUID())
	c.CACert = ResolveCA(get)
	switch {
	case get("LLMCTL_STATE_DIR") != "":
		c.StateDir = get("LLMCTL_STATE_DIR")
	case get("XDG_STATE_HOME") != "":
		c.StateDir = filepath.Join(get("XDG_STATE_HOME"), "llmctl")
	case get("HOME") != "":
		c.StateDir = filepath.Join(get("HOME"), ".local", "state", "llmctl")
	default:
		return Config{}, fmt.Errorf("cannot determine the state directory: set LLMCTL_STATE_DIR")
	}
	switch s := get("LLMCTL_PORT_STRATEGY"); s {
	case "", "fixed":
	case "dynamic":
		c.Strategy = Dynamic
	default:
		return Config{}, fmt.Errorf("LLMCTL_PORT_STRATEGY=%q: want fixed or dynamic", s)
	}
	if r := get("LLMCTL_PORT_RANGE"); r != "" {
		lo, hi, err := parseRange(r)
		if err != nil {
			return Config{}, fmt.Errorf("LLMCTL_PORT_RANGE=%q: %v", r, err)
		}
		c.RangeLo, c.RangeHi = lo, hi
	}
	return c, nil
}

// currentUID is the numeric uid the per-user default port block derives from (a variable so tests
// can stand in for other users).
var currentUID = os.Getuid

// Documented default-range layout (G-008). The total span is 20000-31999, kept below the Linux
// ephemeral range (32768-60999) so outgoing connections cannot sit on a block; it is cut into
// PortBlocks blocks of PortBlockSize ports. A uid owns block (uid-1000) mod PortBlocks, so the
// first login uid (1000) keeps the historical 20000-20999 and uids 1000..1011 are collision-free
// by construction. A host with more than PortBlocks users, or with uids that are congruent modulo
// PortBlocks, must give the later users an explicit LLMCTL_PORT_RANGE - the bind test and the
// per-user state still refuse a port that is actually in use, but only disjoint ranges prevent two
// users being handed the same not-yet-listening port.
const (
	PortSpanLo    = 20000
	PortBlockSize = 1000
	PortBlocks    = 12
	PortSpanHi    = PortSpanLo + PortBlockSize*PortBlocks - 1
)

// DefaultRangeForUID returns the default dynamic range (inclusive) of uid.
func DefaultRangeForUID(uid int) (lo, hi int) {
	idx := ((uid-1000)%PortBlocks + PortBlocks) % PortBlocks
	lo = PortSpanLo + idx*PortBlockSize
	return lo, lo + PortBlockSize - 1
}

func parseRange(s string) (int, int, error) {
	a, b, ok := strings.Cut(s, "-")
	if !ok {
		return 0, 0, fmt.Errorf("want LO-HI, e.g. 20000-20999")
	}
	lo, e1 := strconv.Atoi(strings.TrimSpace(a))
	hi, e2 := strconv.Atoi(strings.TrimSpace(b))
	if e1 != nil || e2 != nil {
		return 0, 0, fmt.Errorf("want LO-HI with numeric bounds")
	}
	if lo < 1024 || hi > 65535 || lo > hi {
		return 0, 0, fmt.Errorf("need 1024 <= LO <= HI <= 65535")
	}
	return lo, hi, nil
}

// Dir is the registry directory ($LLMCTL_STATE_DIR/registry).
func (c Config) Dir() string { return filepath.Join(c.StateDir, "registry") }

// ProfileVar is the per-profile override variable, LLMCTL_PORT_<PROFILE>.
func ProfileVar(profile string) string {
	var b strings.Builder
	b.WriteString("LLMCTL_PORT_")
	for _, r := range profile {
		switch {
		case r >= 'a' && r <= 'z':
			b.WriteRune(r - 32)
		case r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
			b.WriteRune(r)
		default:
			b.WriteByte('_')
		}
	}
	return b.String()
}
