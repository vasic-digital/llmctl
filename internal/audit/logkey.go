package audit

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"

	"github.com/vasic-digital/llmctl/internal/placement"
)

// KeyFile is the log key file name inside the decide state directory.
const KeyFile = "log.key"

// KeyBytes is the length of a freshly generated log key.
const KeyBytes = 32

var keyLineRe = regexp.MustCompile(`^[0-9a-f]{32,}$`)

// LogKeyError reports an unusable log key file. Its message never contains key
// material.
type LogKeyError struct{ Reason string }

func (e *LogKeyError) Error() string { return "audit: " + e.Reason }

func keyErr(format string, a ...any) error { return &LogKeyError{Reason: fmt.Sprintf(format, a...)} }

func readKey(path string) ([]byte, error) {
	// O_NOFOLLOW refuses a symlink; O_NONBLOCK keeps a FIFO swapped in from blocking the open forever
	// (the type is verified on the opened descriptor right below, review A-12).
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, keyErr("log key file cannot be read (symlink or unreadable)")
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, keyErr("log key file cannot be read (symlink or unreadable)")
	}
	if !st.Mode().IsRegular() {
		return nil, keyErr("log key is not a regular file")
	}
	if st.Mode().Perm()&0o077 != 0 {
		if err := f.Chmod(0o600); err != nil {
			return nil, keyErr("log key permissions are too open and could not be tightened")
		}
	}
	buf := make([]byte, 4096)
	n, _ := f.Read(buf)
	text := strings.TrimSpace(string(buf[:n]))
	if !keyLineRe.MatchString(text) || len(text)%2 != 0 {
		return nil, keyErr("log key file is blank or malformed")
	}
	key, err := hex.DecodeString(text)
	if err != nil {
		return nil, keyErr("log key file is blank or malformed")
	}
	return key, nil
}

// LoadOrCreateLogKey returns the per-installation log key, creating
// <dir>/log.key (mode 0600, dir 0700) on first use. The key is written to a
// temp file and hard-linked into place, so a reader never sees a half-written
// file and concurrent first starts (goroutines or processes) converge on the
// first writer's key. A blank, malformed, symlinked or non-regular existing file
// is an error (*LogKeyError) and is never overwritten; a file with group/other
// permission bits is tightened to 0600 (refused if that fails).
func LoadOrCreateLogKey(dir string) ([]byte, error) {
	path := filepath.Join(dir, KeyFile)
	_, statErr := os.Lstat(path)
	if statErr != nil && !os.IsNotExist(statErr) {
		return nil, fmt.Errorf("audit: stat log key: %w", statErr)
	}
	if statErr != nil {
		// FR-087: the log key is a secret too. Refuse to CREATE it inside an unignored git work tree
		// (fail-closed shared guard), before anything is created.
		if err := placement.Check(placement.Spec{
			Path: path,
			What: "the log key",
			Fix:  "set LLMCTL_STATE_DIR to a path outside the repository, or add the state directory to .gitignore",
		}); err != nil {
			return nil, keyErr("%s", err.Error())
		}
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("audit: create key directory: %w", err)
	}
	if statErr != nil {
		if err := createKey(dir, path); err != nil {
			return nil, err
		}
	}
	return readKey(path)
}

func createKey(dir, path string) error {
	raw := make([]byte, KeyBytes)
	if _, err := rand.Read(raw); err != nil {
		return fmt.Errorf("audit: generate log key: %w", err)
	}
	var sfx [4]byte
	if _, err := rand.Read(sfx[:]); err != nil {
		return fmt.Errorf("audit: generate log key: %w", err)
	}
	tmp := filepath.Join(dir, fmt.Sprintf(".%s.%d.%s", KeyFile, os.Getpid(), hex.EncodeToString(sfx[:])))
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return fmt.Errorf("audit: create temp log key: %w", err)
	}
	defer os.Remove(tmp)
	_, werr := f.WriteString(hex.EncodeToString(raw) + "\n")
	if werr == nil {
		werr = f.Sync()
	}
	if cerr := f.Close(); werr == nil {
		werr = cerr
	}
	if werr != nil {
		return fmt.Errorf("audit: write temp log key: %w", werr)
	}
	if err := os.Link(tmp, path); err != nil && !os.IsExist(err) {
		return fmt.Errorf("audit: install log key: %w", err)
	}
	return nil // on EEXIST another starter won; its key is read by the caller
}
