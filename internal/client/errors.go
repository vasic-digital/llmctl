// Package client is llmctl's own HTTPS client of the decision gateway (spec FR-061, FR-068,
// FR-081; contracts/cli.md). Standard library only apart from the contract and keyring packages.
//
// Hard rules, each pinned by a test (and by a documented mutation check):
//   - TLS verification is ALWAYS on and there is no option, variable or build tag that turns it
//     off; trust is exactly the one CA file named by the caller (never the system pool).
//   - The access key is read only via keyring.Secret.Reveal, sent only as an Authorization
//     header, and never appears on a command line, in an error message or in any output.
//   - Request bodies (state!) travel as data over the connection - never as an argument.
//   - Retries are bounded (Config.Retries) and happen only for 429, 503 and 529.
package client

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"net"
	"net/url"
	"strings"
)

// Kind classifies a failure; its value is the CLI exit code (contracts/cli.md).
type Kind int

// Exit codes. There is deliberately no admission-refused (3) kind: only `scale` and `serve`
// produce it; the client never decides admission.
const (
	KindBackend     Kind = 1 // backend / readout failure, timeout, unexpected response
	KindUsage       Kind = 2 // bad flags, bad input, limit violated
	KindKey         Kind = 4 // access-key problem
	KindTLS         Kind = 5 // certificate / TLS problem
	KindUnreachable Kind = 6 // no decision instance ready / endpoint unreachable
	// Abstained is the exit code of a withheld answer; it is not an error.
	Abstained = 10
)

// Error is a classified client failure. Its message never contains the key.
type Error struct {
	Kind      Kind
	Msg       string
	Status    int    // HTTP status when the failure came from a response, else 0
	ErrorType string // contract error_type when the response carried a known one
}

func (e *Error) Error() string { return e.Msg }

// ExitCode is the process exit status for this failure.
func (e *Error) ExitCode() int { return int(e.Kind) }

func errf(k Kind, msg string) *Error { return &Error{Kind: k, Msg: msg} }

// ExitCodeOf returns the exit code of err (1 for an unclassified error, 0 for nil).
func ExitCodeOf(err error) int {
	if err == nil {
		return 0
	}
	var e *Error
	if errors.As(err, &e) {
		return e.ExitCode()
	}
	return 1
}

// Severity ranks exit codes for batch runs ("the exit code is the highest-severity code seen").
// Key and certificate problems outrank unreachable, which outranks backend failures, which
// outrank usage errors, which outrank an abstention, which outranks success.
func Severity(code int) int {
	switch code {
	case 0:
		return 0
	case Abstained:
		return 1
	case 2:
		return 2
	case 1:
		return 3
	case 3:
		return 4
	case 6:
		return 5
	case 5:
		return 6
	case 4:
		return 7
	}
	return 3
}

// classifyTransport maps a transport failure onto a Kind. TLS findings (unknown authority, name
// mismatch, expired, a server that does not speak TLS) are 5; failing to connect is 6; anything
// else (typically a timeout while waiting for the answer) is 1.
func classifyTransport(err error) *Error {
	var ua x509.UnknownAuthorityError
	var he x509.HostnameError
	var ci x509.CertificateInvalidError
	var cve *tls.CertificateVerificationError
	var rh tls.RecordHeaderError
	var alert tls.AlertError
	switch {
	case errors.As(err, &ua):
		return errf(KindTLS, "the gateway certificate is signed by an authority not trusted by the configured CA file (wrong CA?); trust the right CA with LLMCTL_CACERT or `llmctl cert export`")
	case errors.As(err, &he):
		return errf(KindTLS, "the gateway certificate does not cover the host in the endpoint URL (name mismatch); use an address listed in the certificate or add it with LLMCTL_TLS_SAN and `llmctl cert renew`")
	case errors.As(err, &ci):
		if ci.Reason == x509.Expired {
			return errf(KindTLS, "the gateway certificate is expired or not yet valid; run `llmctl cert renew`")
		}
		return errf(KindTLS, "the gateway certificate is invalid")
	case errors.As(err, &cve), errors.As(err, &rh), errors.As(err, &alert):
		return errf(KindTLS, "TLS certificate verification or handshake failed")
	}
	msg := err.Error()
	if strings.Contains(msg, "TLS handshake timeout") {
		return errf(KindUnreachable, "the gateway did not complete the TLS handshake in time")
	}
	if strings.Contains(msg, "x509:") || strings.Contains(msg, "tls:") || strings.Contains(msg, "server gave HTTP response to HTTPS client") {
		return errf(KindTLS, "TLS handshake failed (is the endpoint really an HTTPS gateway?)")
	}
	var op *net.OpError
	if errors.As(err, &op) && op.Op == "dial" {
		return errf(KindUnreachable, "cannot connect to the gateway ("+dialReason(op)+"); is `llmctl decide serve` running?")
	}
	var ue *url.Error
	if errors.As(err, &ue) && ue.Timeout() {
		return errf(KindBackend, "timed out waiting for the gateway")
	}
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return errf(KindBackend, "timed out waiting for the gateway")
	}
	return errf(KindBackend, "the request to the gateway failed")
}

func dialReason(op *net.OpError) string {
	switch {
	case op.Timeout():
		return "timed out"
	case errors.Is(op.Err, errConnRefused()):
		return "connection refused"
	}
	return "unreachable"
}
