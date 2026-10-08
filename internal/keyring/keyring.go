// Package keyring manages the decision layer's single access key
// (spec FR-057..FR-063, FR-087): generation, resolution, persistence,
// rotation and the explicit shell-startup helper.
//
// Resolution order (FR-058): the process environment, then the env file
// (LLMCTL_ENV_FILE or <installation root>/.env), then generate-and-persist
// with mode 0600. The env file is parsed by a safe reader and is never
// sourced; a blank or malformed value is an explicit error (exit code 4),
// never "no key"; an existing key is never overwritten silently; the key never
// appears in String/GoString/Format/JSON/slog output or in error text.
//
// Standard library only.
package keyring

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
	"os"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Variable names (contracts/env-vars.md).
const (
	KeyVar       = "LLMCTL_API_KEY"
	PrevVar      = "LLMCTL_API_KEY_PREVIOUS"
	PrevExpVar   = "LLMCTL_API_KEY_PREVIOUS_EXPIRES"
	EnvFileVar   = "LLMCTL_ENV_FILE"
	redactedText = "<redacted>"
)

// ExitCode is the CLI exit status for every key problem.
const ExitCode = 4

// MaxKeyLen is the longest accepted key. The gateway rejects longer credentials before comparing, so
// a valid key can never be longer than that bound (the length check then reveals nothing about it).
const MaxKeyLen = 512

var keyRE = regexp.MustCompile(`^[A-Za-z0-9_-]{32,512}$`)

// Logger receives info-level lifecycle messages (never key material). It is
// silent by default.
var Logger = slog.New(slog.NewTextHandler(io.Discard, nil))

// ctEqual is the constant-time comparison primitive; a variable so tests can
// count calls and prove there is no early exit.
var ctEqual = subtle.ConstantTimeCompare

// ---------------------------------------------------------------- errors

// Kind classifies a key problem.
type Kind int

const (
	kindGeneric Kind = iota
	kindInvalid
	kindPermissions
	kindPlacement
	kindEnvFile
)

// Error is a key problem (CLI exit code 4). Messages never contain key material.
type Error struct {
	kind Kind
	msg  string
}

// Sentinels for errors.Is. ErrKey matches every key problem.
var (
	ErrKey               = &Error{kind: kindGeneric}
	ErrInvalidKey        = &Error{kind: kindInvalid}
	ErrUnsafePermissions = &Error{kind: kindPermissions}
	ErrUnsafePlacement   = &Error{kind: kindPlacement}
	ErrEnvFile           = &Error{kind: kindEnvFile}
)

func (e *Error) Error() string { return e.msg }

// Is implements errors.Is against the sentinels above.
func (e *Error) Is(target error) bool {
	t, ok := target.(*Error)
	if !ok {
		return false
	}
	if t == ErrKey {
		return true
	}
	return t.msg == "" && t.kind == e.kind
}

func newErr(k Kind, format string, a ...any) *Error {
	return &Error{kind: k, msg: fmt.Sprintf(format, a...)}
}

// IsKeyError reports whether err is (or wraps) a key problem.
func IsKeyError(err error) bool {
	var e *Error
	return errors.As(err, &e)
}

// Environ is the process-environment view the resolver reads (injectable).
type Environ map[string]string

// OSEnviron snapshots the real process environment.
func OSEnviron() Environ {
	out := Environ{}
	for _, kv := range os.Environ() {
		if i := strings.IndexByte(kv, '='); i > 0 {
			out[kv[:i]] = kv[i+1:]
		}
	}
	return out
}

// ---------------------------------------------------------------- secret

// Secret holds a key. Every rendering (fmt verbs, %#v, JSON, text, slog) is
// redacted; only Reveal returns the value.
type Secret struct{ v string }

// NewSecret wraps s without validating it.
func NewSecret(s string) Secret { return Secret{v: s} }

// Reveal returns the key material. Call it only where the value is deliberately
// needed (comparison, writing the env file, `key show --yes-print`).
func (s Secret) Reveal() string { return s.v }

func (s Secret) String() string   { return redactedText }
func (s Secret) GoString() string { return "keyring.Secret{" + redactedText + "}" }
func (s Secret) Format(f fmt.State, _ rune) {
	_, _ = io.WriteString(f, redactedText)
}
func (s Secret) MarshalText() ([]byte, error) { return []byte(redactedText), nil }
func (s Secret) MarshalJSON() ([]byte, error) { return []byte(`"` + redactedText + `"`), nil }
func (s Secret) LogValue() slog.Value         { return slog.StringValue(redactedText) }

// KeyResult is a resolved key. Source is env | file | generated | none.
type KeyResult struct {
	Key    Secret
	Source string
	Path   string
}

func (r KeyResult) String() string {
	return fmt.Sprintf("KeyResult(source=%q, path=%q, key=%s)", r.Source, r.Path, redactedText)
}
func (r KeyResult) GoString() string { return r.String() }
func (r KeyResult) Format(f fmt.State, _ rune) {
	_, _ = io.WriteString(f, r.String())
}
func (r KeyResult) LogValue() slog.Value { return slog.StringValue(r.String()) }

// RotateResult is the outcome of Rotate.
type RotateResult struct {
	Key             Secret
	Path            string
	PreviousExpires int64 // unix seconds; 0 when no overlap key was kept
	EnvShadows      bool
	// GraceSkipped is true when a grace period was requested but the old file key was NOT kept as the
	// previous key because it was not an accepted key (the environment shadowed it).
	GraceSkipped bool
}

func (r RotateResult) String() string {
	return fmt.Sprintf("RotateResult(path=%q, previous_expires=%d, env_shadows=%t, key=%s)",
		r.Path, r.PreviousExpires, r.EnvShadows, redactedText)
}
func (r RotateResult) GoString() string { return r.String() }
func (r RotateResult) Format(f fmt.State, _ rune) {
	_, _ = io.WriteString(f, r.String())
}
func (r RotateResult) LogValue() slog.Value { return slog.StringValue(r.String()) }

// ---------------------------------------------------------------- format

// GenerateKey returns 256 bits from crypto/rand as 43 chars of URL-safe base64.
// There is deliberately no override seam.
func GenerateKey() Secret {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic("keyring: crypto/rand failed: " + err.Error()) // never fall back to weak randomness
	}
	return Secret{v: base64.RawURLEncoding.EncodeToString(b)}
}

// ValidateKey accepts a well-formed key. The error names the origin and the
// rule, never the value.
func ValidateKey(value, origin string) (Secret, error) {
	if strings.TrimSpace(value) == "" {
		return Secret{}, newErr(kindInvalid, "%s from %s is blank; it must match [A-Za-z0-9_-]{32,} (unset it to let llmctl generate one)", KeyVar, origin)
	}
	if !keyRE.MatchString(value) {
		return Secret{}, newErr(kindInvalid, "%s from %s is malformed; it must match [A-Za-z0-9_-]{32,512} (no spaces, quotes or other characters)", KeyVar, origin)
	}
	if why := WeakKey(value); why != "" {
		return Secret{}, newErr(kindInvalid, "%s from %s is too weak: %s; unset it to let llmctl generate a 256-bit key, or use `llmctl key rotate`", KeyVar, origin, why)
	}
	return Secret{v: value}, nil
}

// MinKeyBits is the estimated-entropy floor for an accepted key.
const MinKeyBits = 128

// WeakKey applies the documented entropy floor to a well-formed key and returns the reason it fails,
// or "" when it passes (review A-06). Security rests on key entropy - the failed-auth throttle only
// labels and slows guessing, it never refuses a correct guess (FR-022) - so an operator-supplied key
// like 32 copies of one letter must not be accepted. The rule is a deliberate, cheap FLOOR, not a
// proof of randomness; it never rejects a generated key (256 bits of crypto/rand) or a random 128-bit
// hex string:
//
//   - at least 8 distinct characters;
//   - no character used more than max(8, ceil(len/3)) times (a random 128-bit hex string breaks this
//     about once in 200,000 keys; the bound is as tight as that false-reject rate allows);
//   - not a repetition of a shorter block (period <= len/2);
//   - estimated bits >= MinKeyBits, where bits = len * log2(alphabet) and the alphabet is the sum of
//     the character classes present (a-z 26, A-Z 26, 0-9 10, '-' and '_' 2).
func WeakKey(k string) string {
	n := len(k)
	counts := map[rune]int{}
	lower, upper, digit, sym := false, false, false, false
	for _, r := range k {
		counts[r]++
		switch {
		case r >= 'a' && r <= 'z':
			lower = true
		case r >= 'A' && r <= 'Z':
			upper = true
		case r >= '0' && r <= '9':
			digit = true
		default:
			sym = true
		}
	}
	if len(counts) < 8 {
		return fmt.Sprintf("it uses only %d distinct characters (at least 8 are required)", len(counts))
	}
	limit := (n + 2) / 3 // one third of the key, rounded up
	if limit < 8 {
		limit = 8
	}
	for _, c := range counts {
		if c > limit {
			return "one character makes up too much of it"
		}
	}
	if strings.Index((k + k)[1:], k) < n-1 { // k occurs inside k+k before the trivial rotation: periodic
		return "it is a short block repeated"
	}
	alphabet := 0
	for _, c := range []struct {
		present bool
		size    int
	}{{lower, 26}, {upper, 26}, {digit, 10}, {sym, 2}} {
		if c.present {
			alphabet += c.size
		}
	}
	if bits := float64(n) * math.Log2(float64(alphabet)); bits < MinKeyBits {
		return fmt.Sprintf("it carries about %.0f estimated bits (at least %d are required)", bits, MinKeyBits)
	}
	return ""
}

// ---------------------------------------------------------------- resolution

type dirLock struct{ f *os.File }

// lockDir takes an exclusive flock on the env file's directory so two first
// starts produce one key.
func lockDir(path string) (*dirLock, error) {
	dir := dirOf(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, newErr(kindEnvFile, "cannot create directory %s: %s", dir, reason(err))
	}
	f, err := os.Open(dir)
	if err != nil {
		return nil, newErr(kindEnvFile, "cannot open directory %s: %s", dir, reason(err))
	}
	for {
		err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX)
		if err != syscall.EINTR {
			break
		}
	}
	if err != nil {
		f.Close()
		return nil, newErr(kindEnvFile, "cannot lock directory %s: %s", dir, reason(err))
	}
	return &dirLock{f: f}, nil
}

func (l *dirLock) unlock() {
	_ = syscall.Flock(int(l.f.Fd()), syscall.LOCK_UN)
	_ = l.f.Close()
}

// Resolve returns the access key per FR-058. With generate=false it never
// creates anything and reports Source "none" when no key exists.
func Resolve(root string, env Environ, generate bool) (KeyResult, error) {
	path := EnvFilePath(root, env)
	if v, ok := env[KeyVar]; ok {
		k, err := ValidateKey(v, "the process environment")
		if err != nil {
			return KeyResult{}, err
		}
		return KeyResult{Key: k, Source: "env", Path: path}, nil
	}
	values, err := ReadEnvFile(path)
	if err != nil {
		return KeyResult{}, err
	}
	if v, ok := values[KeyVar]; ok {
		k, err := ValidateKey(v, "the env file "+path)
		if err != nil {
			return KeyResult{}, err
		}
		return KeyResult{Key: k, Source: "file", Path: path}, nil
	}
	if !generate {
		return KeyResult{Source: "none", Path: path}, nil
	}
	if err := CheckPlacement(path); err != nil {
		return KeyResult{}, err
	}
	lock, err := lockDir(path)
	if err != nil {
		return KeyResult{}, err
	}
	defer lock.unlock()
	values, err = ReadEnvFile(path) // re-read: another start may have won
	if err != nil {
		return KeyResult{}, err
	}
	if v, ok := values[KeyVar]; ok {
		k, err := ValidateKey(v, "the env file "+path)
		if err != nil {
			return KeyResult{}, err
		}
		return KeyResult{Key: k, Source: "file", Path: path}, nil
	}
	k := GenerateKey()
	if err := WriteEnvValues(path, map[string]string{KeyVar: k.Reveal()}, nil); err != nil {
		return KeyResult{}, err
	}
	Logger.Info("generated a new access key", "path", path)
	return KeyResult{Key: k, Source: "generated", Path: path}, nil
}

// Info describes key state without revealing it.
type Info struct {
	Path            string
	FileExists      bool
	Source          string // env | file | none
	FileHasKey      bool
	FileShadowed    bool
	Mode            string // octal permission bits of the env file, "" if absent
	EnvPresent      bool
	PreviousPresent bool
}

// Inspect powers `doctor`; it never generates and never reveals the key.
func Inspect(root string, env Environ) (Info, error) {
	path := EnvFilePath(root, env)
	_, envPresent := env[KeyVar]
	info := Info{Path: path, Source: "none", EnvPresent: envPresent}
	if _, err := os.Lstat(path); err == nil {
		info.FileExists = true
	}
	values, err := ReadEnvFile(path) // tightens loose permissions
	if err != nil {
		return info, err
	}
	if info.FileExists {
		if st, err := os.Lstat(path); err == nil {
			info.Mode = strconv.FormatUint(uint64(st.Mode().Perm()), 8)
		}
	}
	var fileKey Secret
	if v, ok := values[KeyVar]; ok {
		info.FileHasKey = true
		if fileKey, err = ValidateKey(v, "the env file "+path); err != nil {
			return info, err
		}
		info.Source = "file"
	}
	_, info.PreviousPresent = values[PrevVar]
	if envPresent {
		ek, err := ValidateKey(env[KeyVar], "the process environment")
		if err != nil {
			return info, err
		}
		info.Source = "env"
		info.FileShadowed = info.FileHasKey && !KeyMatches(ek.Reveal(), []Secret{fileKey})
	}
	return info, nil
}

// AcceptedKeys lists the keys currently valid: the resolved key plus the
// file's previous key until its expiry. The previous key is read ONLY from the file.
func AcceptedKeys(root string, env Environ, now time.Time) ([]Secret, error) {
	res, err := Resolve(root, env, false)
	if err != nil {
		return nil, err
	}
	var keys []Secret
	if res.Source != "none" {
		keys = append(keys, res.Key)
	}
	// PREVIOUS is an overlap for a FILE-sourced key only (review A2-01/A2-02). When the key comes
	// from the environment the file is not consulted at all: its PREVIOUS was never an accepted key
	// (accepting it would widen the set), and an unusable .env must not take the environment key down.
	if res.Source != "file" {
		return keys, nil
	}
	values, err := ReadEnvFile(res.Path)
	if err != nil {
		return nil, err
	}
	prev, exp := values[PrevVar], values[PrevExpVar]
	if prev != "" && keyRE.MatchString(prev) && WeakKey(prev) == "" && isDigits(exp) {
		if n, err := strconv.ParseInt(exp, 10, 64); err == nil && now.Unix() < n {
			dup := false
			for _, k := range keys {
				if k.Reveal() == prev {
					dup = true
				}
			}
			if !dup {
				keys = append(keys, Secret{v: prev})
			}
		}
	}
	return keys, nil
}

func isDigits(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// Rotate explicitly replaces the stored key. With graceSeconds > 0 the old key
// is kept as LLMCTL_API_KEY_PREVIOUS (+ expiry) in the file only.
func Rotate(root string, env Environ, graceSeconds int, now time.Time) (RotateResult, error) {
	if graceSeconds < 0 {
		return RotateResult{}, newErr(kindGeneric, "grace period must be a non-negative whole number of seconds")
	}
	path := EnvFilePath(root, env)
	if err := CheckPlacement(path); err != nil {
		return RotateResult{}, err
	}
	lock, err := lockDir(path)
	if err != nil {
		return RotateResult{}, err
	}
	defer lock.unlock()
	values, err := ReadEnvFile(path)
	if err != nil {
		return RotateResult{}, err
	}
	old, hadOld := values[KeyVar]
	if hadOld && !keyRE.MatchString(old) {
		// A malformed old value is refused (never silently replaced). A WELL-FORMED but weak one is not:
		// rotating is exactly how an operator replaces a key the entropy floor now refuses, so the
		// remedy named in that refusal must work.
		if _, err := ValidateKey(old, "the env file "+path); err != nil {
			return RotateResult{}, err
		}
	}
	nk := GenerateKey()
	updates := map[string]string{KeyVar: nk.Reveal()}
	var remove []string
	var expires int64
	// Only a key the gateway ACCEPTS may be kept as the previous key (review A-03). When the
	// environment holds a different LLMCTL_API_KEY it shadows the file key; the file key was never
	// accepted, so re-arming it as an overlap key would WIDEN the accepted set (and may be exactly the
	// key the operator is rotating away from).
	effective := old
	if ev, ok := env[KeyVar]; ok {
		effective = ev
	}
	accepted := hadOld && old != "" && old == effective && WeakKey(old) == "" // a weak key was never accepted
	graceSkipped := graceSeconds > 0 && hadOld && old != "" && !accepted
	if graceSeconds > 0 && accepted {
		expires = now.Unix() + int64(graceSeconds)
		updates[PrevVar] = old
		updates[PrevExpVar] = strconv.FormatInt(expires, 10)
	} else {
		remove = []string{PrevVar, PrevExpVar}
	}
	if err := WriteEnvValues(path, updates, remove); err != nil {
		return RotateResult{}, err
	}
	Logger.Info("rotated the access key", "path", path)
	_, shadows := env[KeyVar]
	return RotateResult{Key: nk, Path: path, PreviousExpires: expires, EnvShadows: shadows, GraceSkipped: graceSkipped}, nil
}

// digestKey is the per-process random HMAC key of the comparison digests, so neither side of a
// comparison is attacker-influenced input to the constant-time primitive and a precomputed digest
// table is useless.
var digestKey = func() []byte {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic("keyring: crypto/rand failed: " + err.Error())
	}
	return b
}()

func digest(s string) []byte {
	m := hmac.New(sha256.New, digestKey)
	_, _ = io.WriteString(m, s)
	return m.Sum(nil)
}

// KeyMatches compares candidate against EVERY accepted key in constant time per comparison, with
// no early exit. Both sides are first reduced to fixed-length (32 byte) HMAC-SHA-256 digests, so
// subtle.ConstantTimeCompare never sees two lengths and its length short-cut cannot leak the length
// of an accepted key (review A-07).
func KeyMatches(candidate string, accepted []Secret) bool {
	if candidate == "" {
		return false
	}
	cand := digest(candidate)
	ok := 0
	for _, k := range accepted {
		ok |= ctEqual(cand, digest(k.Reveal()))
	}
	return ok == 1
}

// reason extracts a short, path-free description of err.
func reason(err error) string {
	var pe *os.PathError
	if errors.As(err, &pe) {
		err = pe.Err
	}
	var le *os.LinkError
	if errors.As(err, &le) {
		err = le.Err
	}
	var errno syscall.Errno
	if errors.As(err, &errno) {
		return strings.ToLower(errno.Error())
	}
	return err.Error()
}
