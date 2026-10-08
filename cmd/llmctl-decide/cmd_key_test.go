package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func keyRun(t *testing.T, root string, args ...string) (int, string, string) {
	t.Helper()
	t.Setenv("LLMCTL_ROOT", root)
	t.Setenv("LLMCTL_ENV_FILE", "")
	os.Unsetenv("LLMCTL_API_KEY")
	var o, e bytes.Buffer
	rc := run(append([]string{"key"}, args...), &o, &e)
	return rc, o.String(), e.String()
}

func TestKeySubcommandRegistered(t *testing.T) {
	if _, ok := commands["key"]; !ok {
		t.Fatal("key not registered")
	}
}

func TestKeyPathUsesLLMCTLRoot(t *testing.T) {
	root := t.TempDir()
	rc, out, _ := keyRun(t, root, "path")
	if rc != 0 || strings.TrimSpace(out) != filepath.Join(root, ".env") {
		t.Fatalf("rc=%d out=%q", rc, out)
	}
}

func TestKeyExitCodes(t *testing.T) {
	root := t.TempDir()
	if rc, _, _ := keyRun(t, root, "show"); rc != 2 {
		t.Errorf("show w/o flag: %d", rc)
	}
	if rc, _, _ := keyRun(t, root, "show", "--yes-print"); rc != 4 {
		t.Errorf("no key: %d", rc)
	}
	if rc, _, _ := keyRun(t, root, "bogus"); rc != 2 {
		t.Errorf("bogus: %d", rc)
	}
	if rc, out, _ := keyRun(t, root, "rotate"); rc != 0 || strings.Contains(out, "LLMCTL_API_KEY=") {
		t.Errorf("rotate: %d %q", rc, out)
	}
	if st, err := os.Stat(filepath.Join(root, ".env")); err != nil || st.Mode().Perm() != 0o600 {
		t.Errorf("env file: %v %v", st, err)
	}
	t.Setenv("LLMCTL_API_KEY", "short")
	var o, e bytes.Buffer
	if rc := run([]string{"key", "doctor"}, &o, &e); rc != 4 {
		t.Errorf("malformed env key: %d", rc)
	}
}
