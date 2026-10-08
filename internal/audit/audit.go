// Package audit builds structured request-log records and writes them as JSON
// lines (FR-079).
//
// The record builder takes a FIXED set of already-derived scalars (Fields); it
// has no member that could carry state text, question text, option text or key
// material, so none can leak through it. The decision state is represented only
// by an HMAC-SHA256 keyed with the separate per-installation log key (see
// LoadOrCreateLogKey), never the access key, so rotating the access key does not
// break correlation.
//
// Closed vocabularies collapse anything unexpected to a safe constant ("other",
// "OTHER", "invalid") so a hostile client cannot inject text into the log.
// Standard library only.
package audit

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/netip"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode"
	"unicode/utf8"
)

// MinKeyBytes is the minimum accepted HMAC key length.
const MinKeyBytes = 16

// MaxPathRunes caps the logged request path.
const MaxPathRunes = 256

var (
	methods     = map[string]bool{"GET": true, "POST": true, "PUT": true, "DELETE": true, "HEAD": true, "OPTIONS": true, "PATCH": true}
	authResults = map[string]bool{"ok": true, "missing": true, "wrong": true, "throttled": true, "none": true}
	tlsVersions = map[string]bool{"TLSv1.2": true, "TLSv1.3": true}
	reqIDRe     = regexp.MustCompile(`^[0-9a-f]{16}$`)
	profileRe   = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,63}$`)
	hex64Re     = regexp.MustCompile(`^[0-9a-f]{64}$`)
)

// ErrShortKey is returned by StateHash for a key shorter than MinKeyBytes.
var ErrShortKey = errors.New("audit: log key must be at least 16 bytes")

// StateHash returns the lowercase-hex HMAC-SHA256 of state keyed with key. It is
// the only representation of a decision state that may appear in a record.
func StateHash(key []byte, state string) (string, error) {
	if len(key) < MinKeyBytes {
		return "", ErrShortKey
	}
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(state))
	return hex.EncodeToString(mac.Sum(nil)), nil
}

// Str returns a pointer to s, for the optional Profile and StateHash fields.
func Str(s string) *string { return &s }

// Fields is the complete, fixed input of NewRecord. There is deliberately no
// member for state, key, question or option text. Optional members are pointers;
// nil means "not applicable" and is logged as JSON null.
type Fields struct {
	RequestID  string    // 16 lowercase hex chars, else "invalid"
	Method     string    // HTTP method from a fixed set, else "OTHER"
	Path       string    // query/fragment stripped, control chars replaced, capped at 256 runes
	Status     int       // 100..599, else 0
	Millis     float64   // duration in ms; non-finite/negative -> 0; rounded to 3 places
	Bytes      int64     // response size; negative -> 0
	AuthResult string    // ok|missing|wrong|throttled|none, else "other"
	ClientIP   string    // textual IP, canonicalised, else "invalid"
	Profile    *string   // profile id; unusable -> "other"
	TLSVersion string    // TLSv1.2|TLSv1.3, else "other"
	StateHash  *string   // 64 lowercase hex (from StateHash); anything else -> "invalid"
	Now        time.Time // zero means time.Now()
}

// Record is one sanitised log entry. Struct fields are declared in alphabetical
// JSON-key order so encoding is canonical (sorted keys), matching the prototype.
type Record struct {
	Auth      string  `json:"auth"`
	Bytes     int64   `json:"bytes"`
	ClientIP  string  `json:"client_ip"`
	Method    string  `json:"method"`
	MS        float64 `json:"ms"`
	Path      string  `json:"path"`
	Profile   *string `json:"profile"`
	RequestID string  `json:"request_id"`
	StateHash *string `json:"state_hash"`
	Status    int     `json:"status"`
	TLS       string  `json:"tls"`
	TS        string  `json:"ts"`
}

func cleanPath(p string) string {
	if i := strings.IndexByte(p, '?'); i >= 0 {
		p = p[:i]
	}
	if i := strings.IndexByte(p, '#'); i >= 0 {
		p = p[:i]
	}
	var b strings.Builder
	n := 0
	for i := 0; i < len(p) && n < MaxPathRunes; n++ {
		r, w := utf8.DecodeRuneInString(p[i:])
		if (r == utf8.RuneError && w <= 1) || !unicode.IsPrint(r) {
			r = '?'
		}
		b.WriteRune(r)
		i += w
	}
	return b.String()
}

func num(v float64, digits int) float64 {
	if math.IsNaN(v) || math.IsInf(v, 0) || v < 0 {
		return 0
	}
	if digits >= 0 {
		p := math.Pow10(digits)
		return math.Round(v*p) / p
	}
	return v
}

func canonicalIP(s string) string {
	a, err := netip.ParseAddr(s)
	if err != nil || a.Zone() != "" {
		return "invalid"
	}
	return a.String()
}

// NewRecord sanitises f into a Record. Every closed-vocabulary member collapses to
// a safe constant when unexpected, so the result never carries caller-controlled
// free text other than the (sanitised, capped) path.
func NewRecord(f Fields) Record {
	now := f.Now
	if now.IsZero() {
		now = time.Now()
	}
	r := Record{
		TS:        now.UTC().Format("2006-01-02T15:04:05Z"),
		RequestID: "invalid",
		Method:    "OTHER",
		Path:      cleanPath(f.Path),
		MS:        num(f.Millis, 3),
		Auth:      "other",
		ClientIP:  canonicalIP(f.ClientIP),
		TLS:       "other",
	}
	if reqIDRe.MatchString(f.RequestID) {
		r.RequestID = f.RequestID
	}
	if methods[f.Method] {
		r.Method = f.Method
	}
	if f.Status >= 100 && f.Status <= 599 {
		r.Status = f.Status
	}
	if f.Bytes > 0 {
		r.Bytes = f.Bytes
	}
	if authResults[f.AuthResult] {
		r.Auth = f.AuthResult
	}
	if tlsVersions[f.TLSVersion] {
		r.TLS = f.TLSVersion
	}
	if f.Profile != nil {
		p := "other"
		if profileRe.MatchString(*f.Profile) {
			p = *f.Profile
		}
		r.Profile = &p
	}
	if f.StateHash != nil {
		h := "invalid"
		if hex64Re.MatchString(*f.StateHash) {
			h = *f.StateHash
		}
		r.StateHash = &h
	}
	return r
}

// ToJSONLine renders r as one JSON object on one line: keys sorted, compact,
// ASCII only (every non-ASCII rune and control character is \u-escaped), no
// trailing newline.
func ToJSONLine(r Record) string { return asciiJSON(r) }

// asciiJSON encodes v as compact single-line JSON with every non-ASCII rune \u-escaped.
func asciiJSON(v any) string {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		// Records hold only strings, ints, bools and finite floats; unreachable.
		return `{"error":"encode"}`
	}
	raw := bytes.TrimRight(buf.Bytes(), "\n")
	var out strings.Builder
	out.Grow(len(raw))
	for _, c := range string(raw) {
		switch {
		case c < 0x80:
			out.WriteRune(c)
		case c >= 0x10000:
			c -= 0x10000
			fmt.Fprintf(&out, `\u%04x\u%04x`, 0xd800+(c>>10), 0xdc00+(c&0x3ff))
		default:
			fmt.Fprintf(&out, `\u%04x`, c)
		}
	}
	return out.String()
}

// Sink appends records as JSON lines to a file created with mode 0600. It is safe
// for concurrent use and rotation-safe: if the path is renamed or removed (e.g.
// by logrotate) the next Write reopens it.
type Sink struct {
	mu     sync.Mutex
	path   string
	f      *os.File
	closed bool
}

// NewSink opens (creating if needed, parents 0700) path for append with mode 0600.
// A pre-existing looser file is tightened to 0600; a symlink is refused.
func NewSink(path string) (*Sink, error) {
	s := &Sink{path: path}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("audit: create log directory: %w", err)
	}
	if err := s.open(); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Sink) open() error {
	f, err := os.OpenFile(s.path, os.O_WRONLY|os.O_APPEND|os.O_CREATE|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return fmt.Errorf("audit: open log: %w", err)
	}
	if err := f.Chmod(0o600); err != nil {
		f.Close()
		return fmt.Errorf("audit: cannot restrict log permissions: %w", err)
	}
	s.f = f
	return nil
}

// Write appends r as one line. The line is emitted with a single write call on an
// O_APPEND descriptor, under a mutex, so concurrent lines never interleave.
func (s *Sink) Write(r Record) error { return s.WriteLine(ToJSONLine(r)) }

// WriteLine appends one already-rendered record line (it must contain no newline).
func (s *Sink) WriteLine(l string) error {
	line := append([]byte(l), '\n')
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return errors.New("audit: sink closed")
	}
	if s.rotated() {
		s.f.Close()
		if err := s.open(); err != nil {
			return err
		}
	}
	if _, err := s.f.Write(line); err != nil {
		return fmt.Errorf("audit: write log: %w", err)
	}
	return nil
}

// rotated reports whether the path no longer names the file we hold open.
func (s *Sink) rotated() bool {
	cur, err := os.Lstat(s.path)
	if err != nil {
		return true
	}
	mine, err := s.f.Stat()
	if err != nil {
		return true
	}
	return !os.SameFile(cur, mine)
}

// Close closes the file. It is idempotent.
func (s *Sink) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil
	}
	s.closed = true
	return s.f.Close()
}
