package gateway

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// Internal engine keys (G-040). The key the gateway presents to a decision engine travels in a
// FILE, never in the process environment (an env var is world-readable to the same user through
// /proc/<pid>/environ and is inherited by every child):
//
//	LLMCTL_DECIDE_INTERNAL_KEY_FILE            one key for every engine
//	$LLMCTL_STATE_DIR/keys/<kind>-<profile>.key  one key per profile; kind is "onnx" for the encoder
//	                                           runtime (nli-onnx profiles - the file lib/scheduler.sh
//	                                           creates, 0600) and "llama" for llama-server profiles
//
// The per-profile file wins over the global one. A key file must be a regular file (never a symlink),
// owned by the gateway's user, with no group/other permission bits and 1..4096 bytes; one that is
// present but not acceptable is an ERROR (the instance is unhealthy) - the gateway never falls back
// to a looser source. Files are re-checked on every use, so a rotation is picked up without a
// restart, and an engine answering 401 triggers one re-read and one bounded retry. A key is never
// logged, echoed or placed in an error.
const InternalKeyFileVar = "LLMCTL_DECIDE_INTERNAL_KEY_FILE"

const maxKeyFileBytes = 4096

// ErrNoKey means that no key file is configured or present for the profile (an engine started
// without authentication, which stays supported).
var ErrNoKey = errors.New("gateway: no internal key file configured")

// ReadKeyFile returns the trimmed content of an engine key file after the safety checks above.
// The error names the path and the rule, never the content. A missing file satisfies
// errors.Is(err, os.ErrNotExist).
func ReadKeyFile(path string) (string, error) {
	st, err := os.Lstat(path)
	if err != nil {
		return "", err
	}
	if st.Mode()&os.ModeSymlink != 0 {
		return "", fmt.Errorf("key file %s: a symlink is refused", path)
	}
	// O_NOFOLLOW closes the lstat/open race: the file opened is the file checked.
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return "", fmt.Errorf("key file %s: %w", path, err)
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return "", fmt.Errorf("key file %s: %w", path, err)
	}
	if err := checkKeyInfo(path, fi); err != nil {
		return "", err
	}
	b, err := io.ReadAll(io.LimitReader(f, maxKeyFileBytes+1))
	if err != nil {
		return "", fmt.Errorf("key file %s: %w", path, err)
	}
	key := strings.TrimSpace(string(b))
	if key == "" || len(b) > maxKeyFileBytes {
		return "", fmt.Errorf("key file %s: want 1..%d bytes of key", path, maxKeyFileBytes)
	}
	return key, nil
}

func checkKeyInfo(path string, fi os.FileInfo) error {
	if !fi.Mode().IsRegular() {
		return fmt.Errorf("key file %s: not a regular file", path)
	}
	if fi.Mode().Perm()&^0o600 != 0 {
		return fmt.Errorf("key file %s: mode %04o is looser than 0600", path, fi.Mode().Perm())
	}
	if sys, ok := fi.Sys().(*syscall.Stat_t); ok && int(sys.Uid) != os.Geteuid() {
		return fmt.Errorf("key file %s: owned by another user", path)
	}
	if fi.Size() == 0 || fi.Size() > maxKeyFileBytes {
		return fmt.Errorf("key file %s: want 1..%d bytes of key", path, maxKeyFileBytes)
	}
	return nil
}

// KindForProtocol is the key-file kind of a decision protocol.
func KindForProtocol(protocol string) string {
	if protocol == ProtoNLI {
		return "onnx"
	}
	return "llama"
}

type keyStamp struct {
	mod  time.Time
	size int64
	mode os.FileMode
	ino  uint64
}

type keyCached struct {
	stamp keyStamp
	key   string
}

// KeySource resolves the internal key of a profile from the key files.
type KeySource struct {
	global   string
	stateDir string
	protocol map[string]string // profile -> decision protocol

	mu    sync.Mutex
	cache map[string]keyCached
}

// NewKeySource builds a source for the given profiles. Either path may be empty.
func NewKeySource(specs []ProfileSpec, globalFile, stateDir string) *KeySource {
	k := &KeySource{global: globalFile, stateDir: stateDir, protocol: map[string]string{}, cache: map[string]keyCached{}}
	for _, s := range specs {
		k.protocol[s.ID] = s.Protocol
	}
	return k
}

// ProfileFile is the per-profile key file path ("" without a state dir).
func (k *KeySource) ProfileFile(profile string) string {
	if k.stateDir == "" {
		return ""
	}
	return filepath.Join(k.stateDir, "keys", KindForProtocol(k.protocol[profile])+"-"+profile+".key")
}

// Lookup returns the key for profile: the per-profile file, else the global file. reload bypasses
// the content cache (used after a 401). ErrNoKey when neither file exists; any other error means a
// key file exists but is not acceptable (never a silent fallback to another source).
func (k *KeySource) Lookup(profile string, reload bool) (string, error) {
	for _, p := range []string{k.ProfileFile(profile), k.global} {
		if p == "" {
			continue
		}
		key, err := k.read(p, reload)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return "", err
		}
		return key, nil
	}
	return "", ErrNoKey
}

func (k *KeySource) read(path string, reload bool) (string, error) {
	st, err := os.Lstat(path)
	if err != nil {
		return "", err
	}
	stamp := keyStamp{mod: st.ModTime(), size: st.Size(), mode: st.Mode()}
	if sys, ok := st.Sys().(*syscall.Stat_t); ok {
		stamp.ino = sys.Ino
	}
	k.mu.Lock()
	c, ok := k.cache[path]
	k.mu.Unlock()
	if ok && !reload && c.stamp == stamp {
		return c.key, nil // unchanged since the last full check (mode, size, mtime and inode all match)
	}
	key, err := ReadKeyFile(path)
	k.mu.Lock()
	defer k.mu.Unlock()
	if err != nil {
		delete(k.cache, path)
		return "", err
	}
	k.cache[path] = keyCached{stamp: stamp, key: key}
	return key, nil
}

// profileOf maps an instance label ("decide-nli", "decide-nli.2") to its profile id.
func profileOf(instance string) string {
	p, _, _ := strings.Cut(instance, ".")
	return p
}

// KeyedResolver decorates a Resolver: endpoints that carry no key get the profile's key from the
// key files; an endpoint whose key file exists but is unacceptable is returned UNHEALTHY with no
// key (its engine would reject the call anyway) and reported through OnError (server side only).
type KeyedResolver struct {
	Inner   Resolver
	Keys    *KeySource
	OnError func(profile string, err error)
}

// Resolve implements Resolver.
func (r *KeyedResolver) Resolve(kind, profile string) ([]Endpoint, error) {
	eps, err := r.Inner.Resolve(kind, profile)
	if err != nil || r.Keys == nil {
		return eps, err
	}
	for i := range eps {
		if eps[i].Key != "" {
			continue
		}
		key, kerr := r.Keys.Lookup(profile, false)
		switch {
		case kerr == nil:
			eps[i].Key = key
		case errors.Is(kerr, ErrNoKey):
		default:
			eps[i].Healthy = false
			if r.OnError != nil {
				r.OnError(profile, kerr)
			}
		}
	}
	return eps, nil
}

var engineKeys atomic.Pointer[KeySource]

// SetEngineKeys installs the source that postJSON re-reads after an engine answers 401 (nil
// disables the re-read and the retry). It is process-wide: one gateway process, one key source.
func SetEngineKeys(k *KeySource) { engineKeys.Store(k) }

// refreshedKey re-reads the key of the endpoint's profile after a 401. It returns "" when there is
// nothing newer to try: no key source, no key file, an unacceptable file, or the same key again.
func refreshedKey(ep Endpoint) string {
	ks := engineKeys.Load()
	if ks == nil {
		return ""
	}
	key, err := ks.Lookup(profileOf(ep.Instance), true)
	if err != nil || key == ep.Key {
		return ""
	}
	return key
}
