package keyring

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestSecretDirectMethodsRedact(t *testing.T) {
	s := NewSecret(goodKey)
	tx, _ := s.MarshalText()
	js, _ := json.Marshal(s)
	for _, out := range []string{s.String(), s.GoString(), string(tx), string(js), s.LogValue().String()} {
		if contains(out, goodKey) || !contains(out, "redacted") {
			t.Errorf("bad rendering %q", out)
		}
	}
	r := KeyResult{Key: s, Source: "env"}
	rr := RotateResult{Key: s}
	for _, out := range []string{r.String(), r.GoString(), r.LogValue().String(), rr.String(), rr.GoString(), rr.LogValue().String()} {
		if contains(out, goodKey) {
			t.Errorf("leak %q", out)
		}
	}
}

func TestOSEnvironSnapshot(t *testing.T) {
	t.Setenv("LLMCTL_TEST_SNAPSHOT", "a=b")
	if OSEnviron()["LLMCTL_TEST_SNAPSHOT"] != "a=b" {
		t.Fatal("snapshot lost a value containing '='")
	}
}

func TestWriteFailsCleanlyWhenParentIsAFile(t *testing.T) {
	d := t.TempDir()
	blocker := filepath.Join(d, "blocker")
	os.WriteFile(blocker, []byte("x"), 0o600)
	if err := WriteEnvValues(filepath.Join(blocker, ".env"), map[string]string{"A": "1"}, nil); !IsKeyError(err) {
		t.Fatalf("%v", err)
	}
	if _, err := Resolve(d, Environ{"LLMCTL_ENV_FILE": filepath.Join(blocker, ".env")}, true); err == nil {
		t.Fatal("expected failure")
	}
}

func TestInstallBlockBackupNumbering(t *testing.T) {
	rc := filepath.Join(t.TempDir(), "rc")
	os.WriteFile(rc, []byte("a\n"), 0o600)
	for _, l := range []string{"one", "two", "three"} {
		if r, err := InstallExportBlock(rc, l, true); err != nil || !r.Changed {
			t.Fatal(r, err)
		}
	}
	baks, _ := filepath.Glob(rc + ".llmctl-bak*")
	if len(baks) != 3 {
		t.Fatalf("%v", baks)
	}
	if r, _ := InstallExportBlock(rc, "four", false); !r.Changed || r.Backup != "" {
		t.Fatalf("backup=false must not back up: %+v", r)
	}
}
