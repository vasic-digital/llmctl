package keyring

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

const (
	goodKey  = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_AB"
	goodKey2 = "ZyXwVuTsRqPoNmLkJiHgFeDcBa9876543210_-ZY"
)

type fixture struct {
	t    *testing.T
	dir  string
	file string
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	d := t.TempDir()
	return &fixture{t: t, dir: d, file: filepath.Join(d, ".env")}
}

func (f *fixture) write(content string, mode os.FileMode) {
	f.t.Helper()
	if err := os.WriteFile(f.file, []byte(content), mode); err != nil {
		f.t.Fatal(err)
	}
	if err := os.Chmod(f.file, mode); err != nil {
		f.t.Fatal(err)
	}
}

func (f *fixture) read() string {
	f.t.Helper()
	b, err := os.ReadFile(f.file)
	if err != nil {
		f.t.Fatal(err)
	}
	return string(b)
}

func (f *fixture) mode() os.FileMode {
	f.t.Helper()
	st, err := os.Lstat(f.file)
	if err != nil {
		f.t.Fatal(err)
	}
	return st.Mode().Perm()
}

func (f *fixture) resolve(env Environ) (KeyResult, error) {
	return Resolve(f.dir, env, true)
}

func mustGit(t *testing.T, dir string, args ...string) {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not installed")
	}
	c := exec.Command("git", args...)
	c.Dir = dir
	c.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null")
	if out, err := c.CombinedOutput(); err != nil {
		t.Fatalf("git %s: %v: %s", strings.Join(args, " "), err, out)
	}
}

func contains(s, sub string) bool { return strings.Contains(s, sub) }
