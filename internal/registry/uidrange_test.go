package registry

import (
	"fmt"
	"testing"
)

// G-008: every user gets a disjoint default block, derived deterministically from the uid.
func TestDefaultRangeForUIDIsDeterministicAndBlockSized(t *testing.T) {
	lo, hi := DefaultRangeForUID(1000)
	if lo != 20000 || hi != 20999 {
		t.Fatalf("uid 1000 must keep the historical default 20000-20999, got %d-%d", lo, hi)
	}
	for _, uid := range []int{0, 1, 999, 1000, 1001, 4242, 65534, 524288, 1 << 30} {
		a, b := DefaultRangeForUID(uid)
		c, d := DefaultRangeForUID(uid)
		if a != c || b != d {
			t.Fatalf("uid %d: not deterministic", uid)
		}
		if b-a+1 != PortBlockSize {
			t.Fatalf("uid %d: block %d-%d is not %d ports", uid, a, b, PortBlockSize)
		}
		if a < PortSpanLo || b > PortSpanHi {
			t.Fatalf("uid %d: block %d-%d leaves the documented span %d-%d", uid, a, b, PortSpanLo, PortSpanHi)
		}
	}
}

func TestDefaultRangesAreDisjointForConsecutiveUIDs(t *testing.T) {
	seen := map[int]int{} // block start -> uid
	for uid := 1000; uid < 1000+PortBlocks; uid++ {
		lo, hi := DefaultRangeForUID(uid)
		for p := lo; p <= hi; p++ {
			if other, dup := seen[p]; dup {
				t.Fatalf("uid %d and %d both own port %d", uid, other, p)
			}
			seen[p] = uid
		}
	}
	if len(seen) != PortBlocks*PortBlockSize {
		t.Fatalf("got %d distinct ports, want %d", len(seen), PortBlocks*PortBlockSize)
	}
}

// the span must stay below the kernel's ephemeral range so outgoing connections cannot sit on a block
func TestPortSpanBelowEphemeralRange(t *testing.T) {
	if PortSpanHi >= 32768 {
		t.Fatalf("span %d-%d overlaps the Linux ephemeral range 32768-60999", PortSpanLo, PortSpanHi)
	}
}

func TestConfigDefaultsFollowTheUID(t *testing.T) {
	old := currentUID
	defer func() { currentUID = old }()
	got := map[int]string{}
	for _, uid := range []int{1000, 1001, 1002} {
		currentUID = func() int { return uid }
		c, err := ConfigFromEnv(envOf(map[string]string{"LLMCTL_STATE_DIR": "/s"}))
		if err != nil {
			t.Fatal(err)
		}
		got[uid] = fmt.Sprintf("%d-%d", c.RangeLo, c.RangeHi)
	}
	if got[1000] != "20000-20999" || got[1001] != "21000-21999" || got[1002] != "22000-22999" {
		t.Fatalf("unexpected per-uid defaults: %v", got)
	}
}

func TestExplicitRangeOverridesTheUIDDefault(t *testing.T) {
	old := currentUID
	defer func() { currentUID = old }()
	currentUID = func() int { return 1003 }
	c, err := ConfigFromEnv(envOf(map[string]string{"LLMCTL_STATE_DIR": "/s", "LLMCTL_PORT_RANGE": "40000-40009"}))
	if err != nil || c.RangeLo != 40000 || c.RangeHi != 40009 {
		t.Fatalf("%+v %v", c, err)
	}
}

// Two users with separate state directories (nothing shared) can never be handed the same port.
func TestTwoUsersNeverCollideEvenWithoutSharedState(t *testing.T) {
	old := currentUID
	defer func() { currentUID = old }()
	alloc := func(uid int) map[int]bool {
		currentUID = func() int { return uid }
		cfg, err := ConfigFromEnv(envOf(map[string]string{"LLMCTL_STATE_DIR": t.TempDir(), "LLMCTL_PORT_STRATEGY": "dynamic"}))
		if err != nil {
			t.Fatal(err)
		}
		p := NewPorts(cfg, noEnv)
		out := map[int]bool{}
		for i := 0; i < 20; i++ {
			r, err := p.Allocate(PortRequest{Name: fmt.Sprintf("svc%d", i)})
			if err != nil {
				t.Fatalf("uid %d: %v", uid, err)
			}
			out[r.Port] = true
		}
		return out
	}
	a, b := alloc(1000), alloc(1001)
	for p := range a {
		if b[p] {
			t.Fatalf("port %d allocated to both users", p)
		}
	}
}
