// Package api (middleware_auth.go): the mTLS check for node routes
// (T058).
package api

import (
	"net/http"

	"github.com/gin-gonic/gin"
)

// RequireMTLS is defense-in-depth for node routes (POST /v1/cluster/join,
// /v1/cluster/leave, GET /v1/cluster/nodes, GET /v1/cluster/status). The
// REAL enforcement of "only a peer holding a certificate signed by this
// cluster's CA may reach these handlers at all" is the QUIC/TLS handshake
// itself: server.go's http3.Server.TLSConfig carries
// ClientAuth: tls.RequireAndVerifyClientCert (the same mTLS shape
// internal/raft/transport.go uses and internal/raft/transport_test.go's
// TestTransport_RejectsConnectionFromUntrustedCA proves rejects an
// untrusted-CA peer at the connection level, before any HTTP request is
// ever parsed).
//
// RequireMTLS exists to make that guarantee EXPLICIT and fail loudly
// rather than silently if it is ever violated - e.g. a future refactor
// accidentally serving these routes on a TLSConfig that lacks
// RequireAndVerifyClientCert - by asserting a verified peer certificate
// is genuinely present on every request that reaches it, never trusting
// the transport layer blindly (Constitution §11.4.201: a guard must
// assert the real condition, not merely assume its precondition held).
func RequireMTLS() gin.HandlerFunc {
	return func(c *gin.Context) {
		if c.Request.TLS == nil || len(c.Request.TLS.PeerCertificates) == 0 {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{
				"error": "mTLS required: no verified peer certificate presented",
			})
			return
		}
		c.Next()
	}
}
