package server

import (
	"crypto/tls"
	"errors"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

// guardListener wraps the PLAIN TCP listening socket (never a TLS listener: a TLS listener
// handshakes inside Accept and one idle peer stalls every other client). Accept does only
// non-blocking bookkeeping: it takes a global and a per-source slot and, when either bound is
// exhausted, resets the connection at once - before a single TLS byte is processed. The TLS
// handshake of an admitted connection runs lazily in that connection's own goroutine, under
// its own deadline, so a failing or stalled handshake never delays Accept.
type guardListener struct {
	net.Listener
	slots   *slotTable
	cfg     *tls.Config
	hs      time.Duration
	preAuth time.Duration // a connection not authenticated within this long is closed (0 = no timer)
	shed    *atomic.Int64
}

func (l *guardListener) Accept() (net.Conn, error) {
	for {
		c, err := l.Listener.Accept()
		if err != nil {
			return nil, err
		}
		sc := &srvConn{raw: c, cfg: l.cfg, hs: l.hs}
		src, agg := sourceKeys(c.RemoteAddr())
		if l.slots.admitInto(src, agg, sc.abort, func(e *slotEntry) { sc.entry = e }) == nil {
			l.shed.Add(1)
			resetClose(c)
			continue
		}
		if l.preAuth > 0 {
			sc.armPreAuth(l.preAuth)
		}
		return sc, nil
	}
}

// resetClose closes c abortively (RST) so a shed peer sees the refusal immediately.
func resetClose(c net.Conn) {
	if tc, ok := c.(*net.TCPConn); ok {
		_ = tc.SetLinger(0)
	}
	_ = c.Close()
}

// srvConn is an accepted connection that performs its TLS handshake on first use.
// It deliberately is not a *tls.Conn so net/http does not impose its own handshake handling:
// the deadlines net/http sets (ReadHeaderTimeout/ReadTimeout/IdleTimeout) are remembered while
// the handshake runs under HandshakeTimeout and re-applied once it completes.
type srvConn struct {
	raw   net.Conn
	cfg   *tls.Config
	hs    time.Duration
	entry *slotEntry // nil only for connections built outside the guard listener (tests)

	once  sync.Once
	hsErr error

	mu     sync.Mutex
	tc     *tls.Conn
	rd, wd time.Time

	relOnce sync.Once

	authMu sync.Mutex
	authed bool
	timer  *time.Timer
}

// armPreAuth closes the connection abortively when no request on it has authenticated within d.
// This reaps bare TCP connections, stalled or abandoned handshakes, unauthenticated keep-alives
// and probes that were left open: none of them can hold a slot longer than d.
func (c *srvConn) armPreAuth(d time.Duration) {
	c.authMu.Lock()
	defer c.authMu.Unlock()
	if c.authed {
		return
	}
	c.timer = time.AfterFunc(d, c.abort)
}

// markAuthed is called when a request on this connection carried the valid key: the connection
// leaves the unauthenticated pool for the reserved authenticated one and is no longer on a timer.
func (c *srvConn) markAuthed() {
	c.authMu.Lock()
	if c.authed {
		c.authMu.Unlock()
		return
	}
	c.authed = true
	if c.timer != nil {
		c.timer.Stop()
	}
	c.authMu.Unlock()
	if c.entry != nil {
		c.entry.promote()
	}
}

// abort resets the transport (eviction victim or pre-auth timeout) and frees the slot.
func (c *srvConn) abort() {
	if t, ok := c.raw.(*net.TCPConn); ok {
		_ = t.SetLinger(0)
	}
	c.shutdown()
}

func (c *srvConn) releaseSlot() {
	c.relOnce.Do(func() {
		c.authMu.Lock()
		if c.timer != nil {
			c.timer.Stop()
		}
		c.authMu.Unlock()
		if c.entry != nil {
			c.entry.release()
		}
	})
}

func (c *srvConn) handshake() error {
	c.once.Do(func() {
		tc := tls.Server(c.raw, c.cfg)
		_ = c.raw.SetDeadline(time.Now().Add(c.hs))
		if err := tc.Handshake(); err != nil {
			var rhe tls.RecordHeaderError
			if errors.As(err, &rhe) { // plain HTTP, garbage: abortive close, no answer of any kind
				if t, ok := c.raw.(*net.TCPConn); ok {
					_ = t.SetLinger(0)
				}
			}
			c.hsErr = err
			c.shutdown()
			return
		}
		c.mu.Lock()
		_ = c.raw.SetReadDeadline(c.rd)
		_ = c.raw.SetWriteDeadline(c.wd)
		c.tc = tc
		c.mu.Unlock()
	})
	return c.hsErr
}

func (c *srvConn) Read(b []byte) (int, error) {
	if err := c.handshake(); err != nil {
		return 0, err
	}
	return c.tc.Read(b)
}

func (c *srvConn) Write(b []byte) (int, error) {
	if err := c.handshake(); err != nil {
		return 0, err
	}
	return c.tc.Write(b)
}

// shutdown releases the slots and closes the transport abortively (used when the handshake failed).
func (c *srvConn) shutdown() {
	c.releaseSlot()
	_ = c.raw.Close()
}

func (c *srvConn) Close() error {
	c.releaseSlot()
	c.mu.Lock()
	tc := c.tc
	c.mu.Unlock()
	if tc != nil {
		return tc.Close()
	}
	return c.raw.Close()
}

func (c *srvConn) LocalAddr() net.Addr  { return c.raw.LocalAddr() }
func (c *srvConn) RemoteAddr() net.Addr { return c.raw.RemoteAddr() }

func (c *srvConn) SetDeadline(t time.Time) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.rd, c.wd = t, t
	if c.tc != nil {
		return c.raw.SetDeadline(t)
	}
	return nil
}

func (c *srvConn) SetReadDeadline(t time.Time) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.rd = t
	if c.tc != nil {
		return c.raw.SetReadDeadline(t)
	}
	return nil
}

func (c *srvConn) SetWriteDeadline(t time.Time) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.wd = t
	if c.tc != nil {
		return c.raw.SetWriteDeadline(t)
	}
	return nil
}

// tlsVersion names the negotiated protocol for the audit record ("" before the handshake).
func (c *srvConn) tlsVersion() string {
	c.mu.Lock()
	tc := c.tc
	c.mu.Unlock()
	if tc == nil {
		return ""
	}
	switch tc.ConnectionState().Version {
	case tls.VersionTLS12:
		return "TLSv1.2"
	case tls.VersionTLS13:
		return "TLSv1.3"
	}
	return ""
}
