package contract

import (
	"errors"
	"strconv"
	"strings"
)

// Error types of the openapi Error body.
const (
	ErrTypeInvalidRequest   = "invalid_request"
	ErrTypeUnauthorized     = "unauthorized"
	ErrTypeUnknownModel     = "unknown_model"
	ErrTypeValidationFailed = "validation_failed"
	ErrTypePayloadTooLarge  = "payload_too_large"
	ErrTypeMethodNotAllowed = "method_not_allowed"
	ErrTypeRateLimited      = "rate_limited"
	ErrTypeOverloaded       = "overloaded"
	ErrTypeNotReady         = "not_ready"
	ErrTypeReadoutFailed    = "readout_failed"
	ErrTypeBackendFailed    = "backend_failed"
)

// ErrorTypes is the closed set of error_type values.
var ErrorTypes = []string{ErrTypeInvalidRequest, ErrTypeUnauthorized, ErrTypeUnknownModel, ErrTypeValidationFailed,
	ErrTypePayloadTooLarge, ErrTypeMethodNotAllowed, ErrTypeRateLimited, ErrTypeOverloaded, ErrTypeNotReady,
	ErrTypeReadoutFailed, ErrTypeBackendFailed}

// StatusInfo describes one row of the openapi STATUS TABLE.
type StatusInfo struct {
	Retryable  bool
	RetryAfter bool   // the response carries a Retry-After header
	Level      string // "contract" (decided here) or "transport" (decided by the gateway; shape built here)
}

var statusTable = map[int]StatusInfo{
	400: {false, false, "contract"},
	401: {false, false, "transport"},
	404: {false, false, "transport"},
	405: {false, false, "transport"},
	413: {false, false, "contract"},
	422: {false, false, "contract"},
	429: {true, true, "transport"},
	500: {false, false, "transport"},
	502: {true, false, "transport"},
	503: {true, true, "transport"},
	529: {true, true, "transport"},
}

// StatusTable returns a copy of the Go mirror of the STATUS TABLE in contracts/openapi.yaml
// (a test parses the yaml and compares).
func StatusTable() map[int]StatusInfo {
	m := make(map[int]StatusInfo, len(statusTable))
	for k, v := range statusTable {
		m[k] = v
	}
	return m
}

// IsTransportLevel reports whether the status is decided by the transport/gateway layer
// (authentication, routing, slots, backend liveness) rather than by this package.
func IsTransportLevel(status int) bool { return statusTable[status].Level == "transport" }

// DefaultRetryAfter is the Retry-After (seconds) used when the caller names none.
const DefaultRetryAfter = 1

// ErrorBody is the openapi Error body.
type ErrorBody struct {
	Message   string `json:"message"`
	ErrorType string `json:"error_type"`
}

// ContractError is a request/response contract violation; it maps 1:1 onto the openapi Error body.
// Its Message is a generic constant: it never carries request content.
type ContractError struct {
	Status    int
	ErrorType string
	Message   string
	Headers   map[string]string
}

// NewError builds a ContractError, refusing an error_type outside the closed set.
func NewError(status int, errorType, message string, headers map[string]string) (*ContractError, error) {
	known := false
	for _, t := range ErrorTypes {
		known = known || t == errorType
	}
	if !known {
		return nil, errors.New("contract: unknown error_type")
	}
	h := map[string]string{}
	for k, v := range headers {
		h[k] = v
	}
	return &ContractError{Status: status, ErrorType: errorType, Message: message, Headers: h}, nil
}

// Error implements error; it is the generic message only.
func (e *ContractError) Error() string { return e.Message }

// Retryable reports whether a client may retry (from the STATUS TABLE; unknown statuses are not).
func (e *ContractError) Retryable() bool { return statusTable[e.Status].Retryable }

// Body is the JSON error body.
func (e *ContractError) Body() ErrorBody {
	return ErrorBody{Message: e.Message, ErrorType: e.ErrorType}
}

func errBadRequest(msg string) *ContractError {
	return &ContractError{Status: 400, ErrorType: ErrTypeInvalidRequest, Message: msg}
}

func errInvalid(msg string) *ContractError {
	return &ContractError{Status: 422, ErrorType: ErrTypeValidationFailed, Message: msg}
}

var transportErrors = map[int][2]string{
	401: {ErrTypeUnauthorized, "Authentication required."},
	404: {ErrTypeInvalidRequest, "Not found."},
	405: {ErrTypeMethodNotAllowed, "Method not allowed."},
	429: {ErrTypeRateLimited, "Too many requests."},
	500: {ErrTypeBackendFailed, "The decision backend is misconfigured."},
	502: {ErrTypeBackendFailed, "The decision backend failed."},
	503: {ErrTypeNotReady, "Service not ready."},
	529: {ErrTypeOverloaded, "Temporarily overloaded."},
}

// TransportOptions tune TransportError.
type TransportOptions struct {
	Allow      string // Allow header for 405 (default "GET, POST")
	RetryAfter *int   // Retry-After seconds for 429/503/529 (default DefaultRetryAfter; negative is refused)
}

// TransportError is the error shape for a transport-level status (see IsTransportLevel):
// 401 carries WWW-Authenticate, 405 Allow, 429/503/529 Retry-After.
func TransportError(status int, opts TransportOptions) (*ContractError, error) {
	te, ok := transportErrors[status]
	if !ok {
		return nil, errors.New("contract: not a transport-level status")
	}
	h := map[string]string{}
	if status == 401 {
		h["WWW-Authenticate"] = `Bearer realm="llmctl"`
	}
	if status == 405 {
		h["Allow"] = "GET, POST"
		if opts.Allow != "" {
			h["Allow"] = opts.Allow
		}
	}
	if statusTable[status].RetryAfter {
		ra := DefaultRetryAfter
		if opts.RetryAfter != nil {
			ra = *opts.RetryAfter
		}
		if ra < 0 {
			return nil, errors.New("contract: Retry-After must be >= 0")
		}
		h["Retry-After"] = strconv.Itoa(ra)
	}
	return &ContractError{Status: status, ErrorType: te[0], Message: te[1], Headers: h}, nil
}

// ReadoutFailedError is the deterministic readout failure: 422, non-retryable (a retry would fail
// the same way). The message is generic; the internal reason belongs in the log, not the body.
func ReadoutFailedError() *ContractError {
	return &ContractError{Status: 422, ErrorType: ErrTypeReadoutFailed, Message: "The model produced no usable answer for this question."}
}

// CheckContentType accepts application/json (parameters such as charset are ignored).
func CheckContentType(value string) error {
	mt, _, _ := strings.Cut(value, ";")
	if strings.ToLower(strings.TrimSpace(mt)) != "application/json" {
		return errBadRequest("Content-Type must be application/json.")
	}
	return nil
}

// CheckBodySize refuses a body above the cap with 413 (the caller measures before reading);
// a negative length is 400.
func CheckBodySize(length, limit int64) error {
	if length < 0 {
		return errBadRequest("Invalid request.")
	}
	if length > limit {
		return &ContractError{Status: 413, ErrorType: ErrTypePayloadTooLarge, Message: "Request body too large."}
	}
	return nil
}
