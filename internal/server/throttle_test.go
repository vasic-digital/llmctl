package server

import (
	"fmt"
	"testing"
	"time"
)

type fakeClock struct{ t time.Time }

func (f *fakeClock) now() time.Time { return f.t }

func TestThrottleCountsOnlyFailuresAndTripsAfterLimit(t *testing.T) {
	clk := &fakeClock{t: time.Unix(1000, 0)}
	th := newAuthThrottle(3, time.Minute, 100, clk.now)
	for i := 1; i <= 3; i++ {
		if throttled, _, _ := th.fail("a"); throttled {
			t.Fatalf("failure %d within the limit must not throttle", i)
		}
	}
	throttled, ra, _ := th.fail("a")
	if !throttled {
		t.Fatal("4th failure must throttle")
	}
	if ra < 1 || ra > 60 {
		t.Fatalf("retry-after out of range: %d", ra)
	}
	if throttled, _, _ := th.fail("b"); throttled {
		t.Fatal("another source has its own counter")
	}
}

func TestThrottleWindowResets(t *testing.T) {
	clk := &fakeClock{t: time.Unix(1000, 0)}
	th := newAuthThrottle(1, time.Minute, 100, clk.now)
	th.fail("a")
	if throttled, _, _ := th.fail("a"); !throttled {
		t.Fatal("must throttle in window")
	}
	clk.t = clk.t.Add(61 * time.Second)
	if throttled, _, _ := th.fail("a"); throttled {
		t.Fatal("window elapsed: counter must restart")
	}
}

func TestThrottleRetryAfterShrinksWithTime(t *testing.T) {
	clk := &fakeClock{t: time.Unix(1000, 0)}
	th := newAuthThrottle(1, time.Minute, 100, clk.now)
	th.fail("a")
	_, ra1, _ := th.fail("a")
	clk.t = clk.t.Add(30 * time.Second)
	_, ra2, _ := th.fail("a")
	if !(ra2 < ra1) {
		t.Fatalf("retry-after must shrink: %d then %d", ra1, ra2)
	}
}

func TestThrottleTableIsBoundedAndTimeEvicted(t *testing.T) {
	clk := &fakeClock{t: time.Unix(1000, 0)}
	th := newAuthThrottle(5, time.Minute, 50, clk.now)
	for i := 0; i < 5000; i++ {
		th.fail(fmt.Sprintf("src-%d", i))
		if n := th.size(); n > 50 {
			t.Fatalf("table grew to %d (> cap 50)", n)
		}
	}
	// expired entries are swept rather than evicting live ones
	clk.t = clk.t.Add(2 * time.Minute)
	th.fail("fresh")
	if th.size() != 1 {
		t.Fatalf("expired entries must be swept, size=%d", th.size())
	}
}

func TestThrottleConcurrent(t *testing.T) {
	th := newAuthThrottle(10, time.Minute, 64, time.Now)
	done := make(chan struct{})
	for g := 0; g < 8; g++ {
		go func(g int) {
			for i := 0; i < 500; i++ {
				th.fail(fmt.Sprintf("s%d", (g*i)%97))
			}
			done <- struct{}{}
		}(g)
	}
	for g := 0; g < 8; g++ {
		<-done
	}
	if th.size() > 64 {
		t.Fatalf("size %d > cap", th.size())
	}
}
