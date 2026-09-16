// Package api (server.go): the HTTP/3+mTLS server that serves the node
// routes (routes_cluster.go) through RequireMTLS (middleware_auth.go).
// Not separately named by T058's task text, but required supporting
// infrastructure - the routes and middleware need something real to be
// served through for an end-to-end test, exactly like T050's unnamed
// New(cfg) constructor was required for Join to have a real second node.
package api

import (
	"crypto/tls"
	"net"

	"github.com/gin-gonic/gin"
	"github.com/quic-go/quic-go/http3"

	"github.com/vasic-digital/llmctl/llmctld/internal/raft"
)

// apiALPN identifies this connection as carrying llmctld's cluster HTTP/3
// API traffic - distinct from internal/raft/transport.go's quicRaftALPN,
// so a misdirected connection is rejected at ALPN negotiation rather than
// producing a confusing protocol-decode error deeper in either stack
// (mirroring transport.go's own quicRaftALPN doc comment exactly).
const apiALPN = "llmctld-api/1"

// Server is llmctld's HTTP/3 cluster API server.
type Server struct {
	http3Server *http3.Server
	conn        net.PacketConn
	router      *gin.RouterGroup
	// Addr is the real bound address, valid once Listen returns nil.
	Addr string
}

// NewServer builds a Server backed by node, serving the cluster routes
// through RequireMTLS. tlsConf MUST already carry a client-cert-required
// ClientAuth policy plus a VerifyPeerCertificate callback performing the
// real chain+revocation check (cmd/llmctld/main.go's buildNodeTLSConfig
// uses tls.RequireAnyClientCert + raft.VerifyPeerCertificateAgainstCA -
// see that function's doc comment for why ClientAuth itself is
// deliberately NOT tls.RequireAndVerifyClientCert, Feature 004 Phase 5) -
// NewServer sets its own dedicated ALPN on tlsConf but does not itself
// construct the certificate/CA-pool portion of tlsConf, since that is
// exactly internal/mtls's job and re-deriving it here would duplicate
// logic this project deliberately keeps in one place.
func NewServer(node *raft.Node, tlsConf *tls.Config) *Server {
	tlsConf.NextProtos = []string{apiALPN}

	gin.SetMode(gin.ReleaseMode)
	engine := gin.New()
	group := engine.Group("/")
	group.Use(RequireMTLS())
	RegisterClusterRoutes(group, node)

	return &Server{
		http3Server: &http3.Server{
			TLSConfig: tlsConf,
			Handler:   engine,
		},
		router: group,
	}
}

// Router returns s's underlying mTLS-protected route group, so a caller
// can register additional route sets on the SAME server instance (e.g.
// RegisterReplicationRoutes) alongside the cluster routes NewServer
// already wired - kept as a plain accessor rather than growing NewServer's
// own parameter list, so callers that don't need replication routes (or
// any future additional route set) are unaffected by this change. Safe to
// call at any point before Listen (gin's routing tree is only walked
// during ServeHTTP, so registering more routes before the server starts
// accepting real network traffic never races).
func (s *Server) Router() gin.IRoutes {
	return s.router
}

// Listen binds addr (e.g. "127.0.0.1:0" for an ephemeral test port) and
// serves in the background. s.Addr is the real bound address, valid once
// Listen returns nil.
func (s *Server) Listen(addr string) error {
	udpAddr, err := net.ResolveUDPAddr("udp", addr)
	if err != nil {
		return err
	}
	conn, err := net.ListenUDP("udp", udpAddr)
	if err != nil {
		return err
	}
	s.conn = conn
	s.Addr = conn.LocalAddr().String()

	go s.http3Server.Serve(conn) //nolint:errcheck // surfaced via Close() in tests; a background accept-loop error after Close() is expected shutdown noise, not a caller-actionable failure

	return nil
}

// Close stops the server and releases its socket.
func (s *Server) Close() error {
	if err := s.http3Server.Close(); err != nil {
		return err
	}
	if s.conn != nil {
		return s.conn.Close()
	}
	return nil
}
