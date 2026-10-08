package registry

import (
	"context"
	"fmt"
	"math/rand"
	"sort"
	"testing"
	"time"
)

// TestRandomSequencesRegistryEqualsLiveSet is SC-015: over 20 random
// start/stop/kill sequences the registry listing equals the set of live
// service processes (after one health interval = one Reconcile).
func TestRandomSequencesRegistryEqualsLiveSet(t *testing.T) {
	for seq := 0; seq < 20; seq++ {
		seq := seq
		t.Run(fmt.Sprintf("seq%02d", seq), func(t *testing.T) {
			rng := rand.New(rand.NewSource(int64(1000 + seq)))
			cfg := testCfg(t)
			cfg.Strategy = Dynamic
			cfg.RangeLo, cfg.RangeHi = freePortBlock(t, 12)
			ports := NewPorts(cfg, noEnv)
			reg := New(cfg)
			running := map[string]*proc{}
			ports4 := map[string]int{}
			names := []string{"s0", "s1", "s2", "s3"}

			start := func(n string) {
				res, err := ports.Allocate(PortRequest{Name: n})
				if err != nil {
					t.Fatalf("allocate %s: %v", n, err)
				}
				tok := "tok-" + n
				p := spawn(t, "listen", fmt.Sprint(res.Port), tok)
				if err := reg.Register(Entry{Name: n, Host: "127.0.0.1", Port: res.Port, Protocol: "http", HealthPath: "/health", PID: p.pid(), CmdToken: tok,
					Labels: map[string]string{"kind": "decision"}, LoopbackOnly: true}); err != nil {
					t.Fatalf("register %s: %v", n, err)
				}
				running[n], ports4[n] = p, res.Port
			}
			for step := 0; step < 14; step++ {
				n := names[rng.Intn(len(names))]
				switch op := rng.Intn(4); {
				case op == 0 || running[n] == nil: // start
					if running[n] == nil || !running[n].alive() {
						start(n)
					}
				case op == 1: // clean stop
					if p := running[n]; p != nil {
						_, _ = reg.Unregister(n)
						_, _ = ports.Release(n)
						p.kill()
						delete(running, n)
					}
				case op == 2: // kill -9, no cleanup
					if p := running[n]; p != nil {
						p.kill()
						delete(running, n)
					}
				case op == 3:
					if _, err := reg.Reconcile(context.Background(), ReconcileOptions{Grace: time.Minute}); err != nil {
						t.Fatal(err)
					}
				}
				// no two live services ever share a port
				seen := map[int]string{}
				for name, p := range running {
					if p.alive() {
						if other, dup := seen[ports4[name]]; dup {
							t.Fatalf("live services %s and %s share port %d", name, other, ports4[name])
						}
						seen[ports4[name]] = name
					}
				}
			}
			// one health interval later:
			if _, err := reg.Reconcile(context.Background(), ReconcileOptions{Grace: time.Minute}); err != nil {
				t.Fatal(err)
			}
			var live []LiveService
			var wantNames []string
			for n, p := range running {
				if p.alive() {
					live = append(live, LiveService{n, p.pid()})
					wantNames = append(wantNames, n)
				}
			}
			sort.Strings(wantNames)
			list, _ := reg.List()
			var gotNames []string
			for _, e := range list {
				gotNames = append(gotNames, e.Name)
			}
			sort.Strings(gotNames)
			if fmt.Sprint(gotNames) != fmt.Sprint(wantNames) {
				t.Fatalf("registry %v != live %v", gotNames, wantNames)
			}
			d, _ := reg.Diff(live)
			if len(d.RegistryOnly)+len(d.LiveOnly)+len(d.PIDMismatch) != 0 {
				t.Fatalf("diff not empty: %+v", d)
			}
		})
	}
}
