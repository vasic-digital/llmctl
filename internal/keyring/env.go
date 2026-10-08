package keyring

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"unicode/utf8"
)

var nameRE = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// Test seams.
var (
	fchmodFn   = func(f *os.File, m os.FileMode) error { return f.Chmod(m) }
	currentUID = os.Getuid
)

func dirOf(path string) string {
	abs, err := filepath.Abs(path)
	if err != nil {
		abs = path
	}
	return filepath.Dir(abs)
}

// EnvFilePath returns LLMCTL_ENV_FILE (when non-blank) or <root>/.env.
func EnvFilePath(root string, env Environ) string {
	if v, ok := env[EnvFileVar]; ok && strings.TrimSpace(v) != "" {
		abs, err := filepath.Abs(v)
		if err != nil {
			return v
		}
		return abs
	}
	abs, err := filepath.Abs(root)
	if err != nil {
		abs = root
	}
	return filepath.Join(abs, ".env")
}

// ParseEnvText parses KEY=VALUE lines. It never executes or expands anything.
// Comments and blank lines are ignored; an optional `export` prefix and
// matching single/double quotes are supported. Command substitution ($( and
// backtick), NUL and CR are rejected. Errors cite line numbers only - never
// line content (it may be a key).
func ParseEnvText(text string) (map[string]string, error) {
	if strings.ContainsAny(text, "\x00\r") {
		return nil, newErr(kindEnvFile, "env file contains NUL or carriage-return characters")
	}
	out := map[string]string{}
	for i, raw := range strings.Split(text, "\n") {
		n := i + 1
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "export ") {
			line = strings.TrimLeft(line[7:], " \t")
		}
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			return nil, newErr(kindEnvFile, "env file line %d: not a NAME=VALUE assignment", n)
		}
		name := strings.TrimSpace(line[:eq])
		if !nameRE.MatchString(name) {
			return nil, newErr(kindEnvFile, "env file line %d: invalid variable name", n)
		}
		value := strings.TrimSpace(line[eq+1:])
		if strings.Contains(value, "`") || strings.Contains(value, "$(") {
			return nil, newErr(kindEnvFile, "env file line %d: command substitution is not allowed (the file is parsed, never executed)", n)
		}
		if len(value) >= 2 && value[0] == value[len(value)-1] && (value[0] == '"' || value[0] == '\'') {
			value = value[1 : len(value)-1]
		}
		out[name] = value
	}
	return out, nil
}

// openPrivate opens path for reading with O_NOFOLLOW (a symlink is refused, never followed) and
// O_NONBLOCK (a FIFO swapped in cannot hang the reader), then checks the OPENED descriptor: a regular
// file owned by the caller. Every later decision (tighten the mode, read the content) is made on that
// same descriptor, so there is no check-then-use window (review A-12). A missing file is returned as
// an error satisfying errors.Is(err, os.ErrNotExist); everything else is an *Error.
func openPrivate(path string) (*os.File, os.FileInfo, error) {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		switch {
		case errors.Is(err, os.ErrNotExist):
			return nil, nil, err
		case errors.Is(err, syscall.ELOOP):
			return nil, nil, newErr(kindEnvFile, "env file %s is a symlink; refusing to follow it - point LLMCTL_ENV_FILE at the real file", path)
		}
		return nil, nil, newErr(kindEnvFile, "cannot read env file %s: %s", path, reason(err))
	}
	st, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, nil, newErr(kindEnvFile, "cannot stat env file %s: %s", path, reason(err))
	}
	if !st.Mode().IsRegular() {
		f.Close()
		return nil, nil, newErr(kindEnvFile, "env file %s is not a regular file", path)
	}
	if sys, ok := st.Sys().(*syscall.Stat_t); ok && int(sys.Uid) != currentUID() {
		f.Close()
		return nil, nil, newErr(kindEnvFile, "env file %s is owned by another user; refusing to use it", path)
	}
	return f, st, nil
}

// shellQuote mirrors POSIX single-quote quoting for safe words.
func shellQuote(s string) string {
	if s == "" {
		return "''"
	}
	safe := true
	for _, r := range s {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || strings.ContainsRune("@%+=:,./-_", r)) {
			safe = false
			break
		}
	}
	if safe {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'"'"'`) + "'"
}

// tighten makes the already-opened f owner-only (fchmod on the descriptor, never on a path) or
// returns an UnsafePermissions error (FR-059).
func tighten(f *os.File, st os.FileInfo, path string) error {
	if st.Mode().Perm()&0o077 == 0 {
		return nil
	}
	ok := false
	if fchmodFn(f, 0o600) == nil {
		if st2, err := f.Stat(); err == nil && st2.Mode().Perm()&0o077 == 0 {
			ok = true
		}
	}
	if !ok {
		return newErr(kindPermissions, "env file %s is readable by other users and could not be tightened; fix it with: chmod 600 %s", path, shellQuote(path))
	}
	Logger.Info("tightened permissions to 0600", "path", path)
	return nil
}

// EnsurePrivate tightens path to 0600 or returns an UnsafePermissions error (FR-059).
func EnsurePrivate(path string) error {
	f, st, err := openPrivate(path)
	if err != nil {
		return err
	}
	defer f.Close()
	return tighten(f, st, path)
}

// readPrivateText opens path once, checks and tightens it on that descriptor, and reads it from the
// same descriptor. A missing file satisfies errors.Is(err, os.ErrNotExist).
func readPrivateText(path string) (string, error) {
	f, st, err := openPrivate(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	if err := tighten(f, st, path); err != nil {
		return "", err
	}
	b, err := io.ReadAll(io.LimitReader(f, maxEnvFileBytes+1))
	if err != nil {
		return "", newErr(kindEnvFile, "cannot read env file %s: %s", path, reason(err))
	}
	if len(b) > maxEnvFileBytes {
		return "", newErr(kindEnvFile, "env file %s is unreasonably large", path)
	}
	if !utf8.Valid(b) {
		return "", newErr(kindEnvFile, "env file %s is not valid UTF-8", path)
	}
	return string(b), nil
}

const maxEnvFileBytes = 1 << 20

// ReadEnvFile reads and parses path (tightening its mode first). A missing
// file yields an empty map.
func ReadEnvFile(path string) (map[string]string, error) {
	text, err := readPrivateText(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return map[string]string{}, nil
		}
		return nil, err
	}
	return ParseEnvText(text)
}

func rewriteLines(existing string, updates map[string]string, remove []string) string {
	rm := map[string]bool{}
	for _, r := range remove {
		rm[r] = true
	}
	pending := map[string]string{}
	for k, v := range updates {
		pending[k] = v
	}
	var out []string
	for _, raw := range strings.Split(existing, "\n") {
		stripped := strings.TrimSpace(raw)
		name := ""
		if stripped != "" && !strings.HasPrefix(stripped, "#") && strings.Contains(stripped, "=") {
			body := stripped
			if strings.HasPrefix(body, "export ") {
				body = strings.TrimLeft(body[7:], " \t")
			}
			name = strings.TrimSpace(body[:strings.IndexByte(body, '=')])
		}
		if name != "" && rm[name] {
			continue
		}
		if v, ok := pending[name]; ok && name != "" {
			out = append(out, name+"="+v)
			delete(pending, name)
			continue
		}
		out = append(out, raw)
	}
	for len(out) > 0 && out[len(out)-1] == "" {
		out = out[:len(out)-1]
	}
	names := make([]string, 0, len(pending))
	for k := range pending {
		names = append(names, k)
	}
	sort.Strings(names)
	for _, k := range names {
		out = append(out, k+"="+pending[k])
	}
	return strings.Join(out, "\n") + "\n"
}

func validateUpdates(updates map[string]string) error {
	for name, value := range updates {
		if !nameRE.MatchString(name) {
			return newErr(kindEnvFile, "invalid variable name")
		}
		if strings.ContainsAny(value, "\n\r\x00`") || strings.Contains(value, "$(") {
			return newErr(kindEnvFile, "refusing to write an unsafe value for %s", name)
		}
	}
	return nil
}

// WriteEnvValues atomically merges updates into the env file: a temp file in
// the same directory created with O_EXCL (mode 0600), fsync, rename, directory
// fsync. Other lines are preserved. It does NOT run the placement guard;
// callers that create or rotate keys do.
func WriteEnvValues(path string, updates map[string]string, remove []string) error {
	if err := validateUpdates(updates); err != nil {
		return err
	}
	dir := dirOf(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return newErr(kindEnvFile, "cannot create directory %s: %s", dir, reason(err))
	}
	existing := "# llmctl environment (owner-only; parsed, never sourced)\n"
	if text, err := readPrivateText(path); err == nil {
		if _, perr := ParseEnvText(text); perr != nil { // refuse to rewrite a file we cannot parse
			return perr
		}
		existing = text
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	text := rewriteLines(existing, updates, remove)
	var f *os.File
	var tmp string
	base := filepath.Base(path)
	for i := 0; i < 100; i++ {
		var rb [6]byte
		_, _ = rand.Read(rb[:])
		cand := filepath.Join(dir, "."+base+"."+hex.EncodeToString(rb[:])+".tmp")
		fh, err := os.OpenFile(cand, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o600)
		if err != nil {
			if errors.Is(err, os.ErrExist) {
				continue
			}
			return newErr(kindEnvFile, "cannot create a temporary file next to the env file: %s", reason(err))
		}
		f, tmp = fh, cand
		break
	}
	if f == nil {
		return newErr(kindEnvFile, "could not create a temporary file next to the env file")
	}
	cleanup := func(err error) error {
		_ = os.Remove(tmp)
		return newErr(kindEnvFile, "cannot write env file %s: %s", path, reason(err))
	}
	if err := f.Chmod(0o600); err != nil {
		f.Close()
		return cleanup(err)
	}
	if _, err := f.WriteString(text); err != nil {
		f.Close()
		return cleanup(err)
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return cleanup(err)
	}
	if err := f.Close(); err != nil {
		return cleanup(err)
	}
	if err := os.Rename(tmp, path); err != nil {
		return cleanup(err)
	}
	if d, err := os.Open(dir); err == nil {
		_ = d.Sync()
		_ = d.Close()
	}
	return nil
}

// SetKey persists key; it refuses to replace an existing key unless overwrite.
func SetKey(path, key string, overwrite bool) error {
	if _, err := ValidateKey(key, "argument"); err != nil {
		return err
	}
	values, err := ReadEnvFile(path)
	if err != nil {
		return err
	}
	if _, ok := values[KeyVar]; ok && !overwrite {
		return newErr(kindGeneric, "%s already exists in %s; use an explicit rotate to replace it", KeyVar, path)
	}
	return WriteEnvValues(path, map[string]string{KeyVar: key}, nil)
}
