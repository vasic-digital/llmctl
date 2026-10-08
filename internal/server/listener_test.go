package server

import (
	"errors"
	"fmt"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// fakeListener hands out pre-built connections; it lets a test drive the real guardListener.Accept
// path with chosen remote addresses (review A3-T1, A3-02).
type fakeListener struct {
	ch   chan net.Conn
	done chan struct{}
	once sync.Once
}

func newFakeListener() *fakeListener {
	return &fakeListener{ch: make(chan net.Conn, 4096), done: make(chan struct{})}
}

func (f *fakeListener) Accept() (net.Conn, error) {
	select {
	case c := <-f.ch:
		return c, nil
	case <-f.done:
		return nil, net.ErrClosed
	}
}
func (f *fakeListener) Close() error   { f.once.Do(func() { close(f.done) }); return nil }
func (f *fakeListener) Addr() net.Addr { return &net.TCPAddr{IP: net.ParseIP("127.0.0.1"), Port: 1} }

type remoteConn struct {
	net.Conn
	remote net.Addr
}

func (r remoteConn) RemoteAddr() net.Addr { return r.remote }

// push queues a connection reporting ip as its peer and returns the CLIENT end of the pipe.
func (f *fakeListener) push(ip string) net.Conn {
	s, c := net.Pipe()
	f.ch <- remoteConn{Conn: s, remote: &net.TCPAddr{IP: net.ParseIP(ip), Port: 40000}}
	return c
}

// peerClosed reports whether the server side of the pipe has been closed (reset).
func peerClosed(c net.Conn) bool {
	_ = c.SetReadDeadline(time.Now().Add(150 * time.Millisecond))
	var b [1]byte
	_, err := c.Read(b[:])
	return err != nil && !errors.Is(err, os.ErrDeadlineExceeded)
}

func testListener(slots *slotTable, fl *fakeListener) (*guardListener, *atomic.Int64) {
	shed := new(atomic.Int64)
	return &guardListener{Listener: fl, slots: slots, shed: shed}, shed
}

// A3-T1: the per-/48 unauthenticated cap must operate through the REAL Accept path. Five sources in
// five different /64 of ONE /48 share maxUnauthAgg=3 slots; if Accept passed the source as its own
// aggregate (mutation N13) every /64 would get a full share and nothing would be evicted.
func TestAcceptEnforcesThePer48AggregateCapAcrossDifferent64s(t *testing.T) {
	fl := newFakeListener()
	l, _ := testListener(newSlotTable(10, 10).withUnauth(10, 2, 3), fl)
	var clients []net.Conn
	for i := 1; i <= 5; i++ {
		clients = append(clients, fl.push(fmt.Sprintf("2001:db8:1:%d::1", i)))
		if _, err := l.Accept(); err != nil {
			t.Fatal(err)
		}
	}
	if got := l.slots.inUse(); got != 3 {
		t.Fatalf("the /48 holds %d connections, want 3 (aggregate cap); the aggregate is not applied by Accept", got)
	}
	for i := 0; i < 2; i++ {
		if !peerClosed(clients[i]) {
			t.Errorf("the oldest connection %d of the /48 was not evicted", i)
		}
	}
	for i := 2; i < 5; i++ {
		if peerClosed(clients[i]) {
			t.Errorf("connection %d of the /48 was evicted but should be live", i)
		}
	}
}

// A3-T1: when the pool is full the victim is ranked by the /48 aggregate first, through Accept:
// a legitimate /48 with one (oldest) connection survives a flood spread over several /64 of another /48.
func TestAcceptVictimRankingUsesTheAggregate(t *testing.T) {
	fl := newFakeListener()
	l, _ := testListener(newSlotTable(4, 4).withUnauth(4, 2, 4), fl)
	legit := fl.push("2001:db8:aaaa::1")
	var attackers []net.Conn
	if _, err := l.Accept(); err != nil {
		t.Fatal(err)
	}
	for i := 1; i <= 3; i++ {
		attackers = append(attackers, fl.push(fmt.Sprintf("2001:db8:bbbb:%d::1", i)))
		if _, err := l.Accept(); err != nil {
			t.Fatal(err)
		}
	}
	newcomer := fl.push("2001:db8:cccc::1")
	if _, err := l.Accept(); err != nil {
		t.Fatal(err)
	}
	if peerClosed(legit) {
		t.Error("the legitimate /48 was evicted although another /48 holds more slots")
	}
	if !peerClosed(attackers[0]) {
		t.Error("the heaviest /48's oldest connection was not the victim")
	}
	if peerClosed(newcomer) {
		t.Error("the newcomer was refused")
	}
}

// A3-02: one Server may run several listeners over ONE slot table (dual stack). The eviction callback
// of an entry admitted by listener A, run by listener B, must not race with A's assignment of the
// entry to its connection. Run under -race.
func TestTwoListenersSharingOneSlotTableAreRaceFree(t *testing.T) {
	slots := newSlotTable(6, 6).withUnauth(2, 2, 2)
	fa, fb := newFakeListener(), newFakeListener()
	la, _ := testListener(slots, fa)
	lb, _ := testListener(slots, fb)
	var wg sync.WaitGroup
	run := func(l *guardListener, fl *fakeListener) {
		defer wg.Done()
		var mine []net.Conn
		for i := 0; i < 400; i++ {
			c := fl.push("192.0.2.77")
			mine = append(mine, c)
			sc, err := l.Accept()
			if err != nil {
				t.Error(err)
				return
			}
			defer sc.Close()
		}
		for _, c := range mine {
			_ = c.Close()
		}
	}
	wg.Add(2)
	go run(la, fa)
	go run(lb, fb)
	wg.Wait()
	if n := slots.inUse(); n != 0 {
		t.Errorf("slots leaked: inUse=%d", n)
	}
}
