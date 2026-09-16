// Package raft (transport.go): a hashicorp/raft StreamLayer over QUIC with
// mutual TLS, so node-to-node Raft RPCs (Clarification 11) run over an
// HTTP/3-family transport authenticated by internal/mtls certificates.
//
// Design note (Constitution §11.4.74 extend-don't-reimplement): this does
// NOT reimplement Raft's RPC encoding/framing. hraft.StreamLayer is a small
// interface (net.Listener + Dial) that raft's own battle-tested
// NewNetworkTransport consumes to get msgpack-framed RPCs over ANY
// net.Conn-shaped transport - this file supplies exactly that shape over
// QUIC, nothing more. A QUIC *quic.Stream already implements
// Read/Write/Close/SetDeadline/SetReadDeadline/SetWriteDeadline (verified
// against the real quic-go v0.62.0 source before writing this file, not
// assumed); LocalAddr/RemoteAddr are delegated to the stream's parent
// *quic.Conn (the stream itself has no address concept - a QUIC connection
// does).
package raft

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"net"
	"time"

	hraft "github.com/hashicorp/raft"
	"github.com/quic-go/quic-go"

	"github.com/vasic-digital/llmctl/llmctld/internal/mtls"
)

// quicRaftALPN identifies this connection as carrying raft's own RPC
// framing over QUIC - distinct from any HTTP/3 API traffic (internal/api)
// that may later share a node's QUIC stack, so a misdirected connection is
// rejected at the ALPN negotiation layer rather than producing a confusing
// protocol-decode error deeper in raft's msgpack decoder.
const quicRaftALPN = "llmctld-raft/1"

// VerifyPeerCertificateAgainstCA returns a tls.Config.VerifyPeerCertificate
// callback that delegates to store.Verify - checking the presented peer
// certificate's serial number against store's LIVE revoked-serial set
// FIRST, then verifying the chain against ANY of store's currently-trusted
// CA pools - WITHOUT checking any DNS/IP hostname against a SAN.
//
// Refactored for Feature 004 (mTLS certificate and CA rotation with
// revocation): this closure used to close over a fixed *x509.CertPool
// captured once at tls.Config construction time, with no way for a running
// process to react to a cluster-wide revocation event without a full
// listener rebuild. It now closes over a *mtls.TrustStore instead - since
// Go's crypto/tls re-invokes VerifyPeerCertificate on EVERY real handshake
// (confirmed against the real package source, exactly as this file already
// relied on for its own CA-pool check before this refactor), reading
// store's revoked-serial set / trusted-CA-pool set fresh on every call
// makes an mtls.TrustStore.UpdateRevoked/UpdateTrustedCAs call take effect
// for the very next connection attempt on EVERY node, with zero process
// restart (research.md Decision 2, data-model.md).
//
// Chain-validation behavior is UNCHANGED by this refactor (verified by the
// pre-existing TestTransport_TwoNodesExchangeRealRaftRPCOverLoopback and
// TestTransport_RejectsConnectionFromUntrustedCA continuing to pass
// unmodified): mtls.IssueNodeCert issues certs identified by raft node ID
// (CommonName only, no SAN), while raft peers are dialed by their current
// network address, which is unrelated to - and, in a real cluster, can
// change independently of - that identity. Go's certificate verification
// (since Go 1.15, when CommonName-based hostname fallback was removed)
// REQUIRES a matching SAN for standard verification, so a standard
// tls.Config here would fail every real (non-loopback-lucky) connection
// with "certificate relies on legacy Common Name field" or "doesn't
// contain any IP SANs" - confirmed by actually driving the
// TwoNodesExchangeRealRaftRPCOverLoopback test with the standard
// verification path before writing this function originally: it failed
// with exactly that x509 error. Node identity here is established by the
// CA chain (a node's cert must be signed by the cluster's CA), not by
// DNS/IP naming.
func VerifyPeerCertificateAgainstCA(store *mtls.TrustStore) func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
	return func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
		if err := store.Verify(rawCerts); err != nil {
			return fmt.Errorf("raft: %w", err)
		}
		return nil
	}
}

// quicConn adapts one QUIC stream (plus its parent connection, for the
// address methods net.Conn requires but a bare stream has no concept of)
// to net.Conn, the shape hraft.StreamLayer's Accept/Dial must return.
type quicConn struct {
	conn   *quic.Conn
	stream *quic.Stream
}

func (c *quicConn) Read(p []byte) (int, error)  { return c.stream.Read(p) }
func (c *quicConn) Write(p []byte) (int, error) { return c.stream.Write(p) }
func (c *quicConn) Close() error                { return c.stream.Close() }
func (c *quicConn) LocalAddr() net.Addr         { return c.conn.LocalAddr() }
func (c *quicConn) RemoteAddr() net.Addr        { return c.conn.RemoteAddr() }
func (c *quicConn) SetDeadline(t time.Time) error {
	return c.stream.SetDeadline(t)
}
func (c *quicConn) SetReadDeadline(t time.Time) error {
	return c.stream.SetReadDeadline(t)
}
func (c *quicConn) SetWriteDeadline(t time.Time) error {
	return c.stream.SetWriteDeadline(t)
}

// quicStreamLayer implements hraft.StreamLayer (net.Listener + Dial) over
// QUIC with mutual TLS. Raft's NetworkTransport treats each net.Conn it
// gets from Accept/Dial as a PERSISTENT connection it reads many
// sequential RPCs from (verified against the real raft v1.7.3 source:
// NetworkTransport.handleConn loops on the same net.Conn until EOF/error,
// and the client side pools+reuses connections per peer) - this maps
// naturally onto "one QUIC connection, one stream, reused for many RPCs",
// the same persistent-connection shape a raw TCP net.Conn would have.
type quicStreamLayer struct {
	listener *quic.Listener
	tlsConf  *tls.Config
}

// newQUICStreamLayer binds addr and starts listening for QUIC connections
// authenticated per tlsConf (RequireAndVerifyClientCert - mutual TLS).
func newQUICStreamLayer(addr string, tlsConf *tls.Config) (*quicStreamLayer, error) {
	ln, err := quic.ListenAddr(addr, tlsConf, nil)
	if err != nil {
		return nil, err
	}
	return &quicStreamLayer{listener: ln, tlsConf: tlsConf}, nil
}

func (q *quicStreamLayer) Accept() (net.Conn, error) {
	conn, err := q.listener.Accept(context.Background())
	if err != nil {
		return nil, err
	}
	stream, err := conn.AcceptStream(context.Background())
	if err != nil {
		return nil, err
	}
	return &quicConn{conn: conn, stream: stream}, nil
}

func (q *quicStreamLayer) Close() error { return q.listener.Close() }

func (q *quicStreamLayer) Addr() net.Addr { return q.listener.Addr() }

// Dial opens a new QUIC connection (mutually authenticated per q.tlsConf)
// to address and opens its first stream, returning it as a persistent
// net.Conn for raft's connection pool to reuse across many RPCs.
func (q *quicStreamLayer) Dial(address hraft.ServerAddress, timeout time.Duration) (net.Conn, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	conn, err := quic.DialAddr(ctx, string(address), q.tlsConf, nil)
	if err != nil {
		return nil, err
	}
	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		return nil, err
	}
	return &quicConn{conn: conn, stream: stream}, nil
}

// NewTransport builds a real hraft.NetworkTransport over QUIC+mTLS,
// listening on addr. tlsConf MUST have NextProtos set (quic-go requires an
// explicit ALPN protocol) and ClientAuth: tls.RequireAndVerifyClientCert
// for the mutual-TLS guarantee Clarification 11 requires - callers
// construct it from internal/mtls-issued certificates (see
// transport_test.go's buildNodeTLSConfig for the reference shape).
func NewTransport(addr string, tlsConf *tls.Config, maxPool int, timeout time.Duration) (*hraft.NetworkTransport, error) {
	layer, err := newQUICStreamLayer(addr, tlsConf)
	if err != nil {
		return nil, err
	}
	return hraft.NewNetworkTransport(layer, maxPool, timeout, nil), nil
}
