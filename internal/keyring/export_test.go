package keyring

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestExportReferenceFormHasNoKey(t *testing.T) {
	for _, sh := range []string{"bash", "zsh", "sh", "fish"} {
		l, err := ExportLine(sh, "/p/my .env", nil)
		if err != nil || contains(l, goodKey) || !contains(l, "LLMCTL_API_KEY") || !contains(l, "'/p/my .env'") {
			t.Errorf("%s: %q %v", sh, l, err)
		}
	}
	l, _ := ExportLine("bash", "/e", nil)
	if !strings.HasPrefix(l, "[ -r '/e' ] && export LLMCTL_API_KEY=") && !strings.HasPrefix(l, "[ -r /e ] && export LLMCTL_API_KEY=") {
		t.Errorf("%q", l)
	}
}

func TestExportFishAndInlineAndBadShell(t *testing.T) {
	s := NewSecret(goodKey)
	if l, _ := ExportLine("fish", "/e", &s); l != `set -gx LLMCTL_API_KEY "`+goodKey+`"` {
		t.Error(l)
	}
	if l, _ := ExportLine("bash", "/e", &s); l != `export LLMCTL_API_KEY="`+goodKey+`"` {
		t.Error(l)
	}
	if _, err := ExportLine("powershell", "/e", nil); err == nil {
		t.Error("bad shell accepted")
	}
	bad := NewSecret("short")
	if _, err := ExportLine("bash", "/e", &bad); err == nil {
		t.Error("bad inline key accepted")
	}
}

func TestInstallBlockIdempotentWithBackup(t *testing.T) {
	d := t.TempDir()
	rc := filepath.Join(d, "rc")
	os.WriteFile(rc, []byte("alias ll=ls\n"), 0o640)
	line, _ := ExportLine("bash", "/e", nil)
	r1, err := InstallExportBlock(rc, line, true)
	if err != nil || !r1.Changed || r1.Backup == "" {
		t.Fatalf("%+v %v", r1, err)
	}
	if b, _ := os.ReadFile(r1.Backup); string(b) != "alias ll=ls\n" {
		t.Errorf("backup %q", b)
	}
	snap, _ := os.ReadFile(rc)
	if !strings.HasPrefix(string(snap), "alias ll=ls\n"+BlockBegin+"\n") {
		t.Errorf("%q", snap)
	}
	if st, _ := os.Stat(rc); st.Mode().Perm() != 0o640 {
		t.Errorf("mode not preserved: %v", st.Mode().Perm())
	}
	r2, err := InstallExportBlock(rc, line, true)
	if err != nil || r2.Changed || r2.Backup != "" {
		t.Fatalf("second: %+v %v", r2, err)
	}
	after, _ := os.ReadFile(rc)
	if string(after) != string(snap) || strings.Count(string(after), BlockBegin) != 1 {
		t.Error("not idempotent")
	}
	baks, _ := filepath.Glob(rc + ".llmctl-bak*")
	if len(baks) != 1 {
		t.Errorf("backups: %v", baks)
	}
	if len(r1.Warnings) == 0 {
		t.Error("0640 is group-readable: expected a readability warning")
	}
}

func TestInstallBlockUpdatesChangedContentAndBacksUpAgain(t *testing.T) {
	d := t.TempDir()
	rc := filepath.Join(d, "rc")
	os.WriteFile(rc, []byte("top\n"), 0o600)
	InstallExportBlock(rc, "line-one", true)
	r, err := InstallExportBlock(rc, "line-two", true)
	if err != nil || !r.Changed || r.Backup == "" {
		t.Fatalf("%+v %v", r, err)
	}
	b, _ := os.ReadFile(rc)
	if contains(string(b), "line-one") || !contains(string(b), "line-two") || strings.Count(string(b), BlockBegin) != 1 {
		t.Errorf("%q", b)
	}
	baks, _ := filepath.Glob(rc + ".llmctl-bak*")
	if len(baks) != 2 {
		t.Errorf("backups: %v", baks)
	}
}

func TestInstallBlockSurroundingTextPreservedWhenReplacing(t *testing.T) {
	d := t.TempDir()
	rc := filepath.Join(d, "rc")
	os.WriteFile(rc, []byte("before\n"+BlockBegin+"\nold\n"+BlockEnd+"\nafter\n"), 0o600)
	InstallExportBlock(rc, "new", true)
	b, _ := os.ReadFile(rc)
	if string(b) != "before\n"+BlockBegin+"\nnew\n"+BlockEnd+"\nafter\n" {
		t.Errorf("%q", b)
	}
}

func TestInstallBlockCreatesMissingFilePrivate(t *testing.T) {
	rc := filepath.Join(t.TempDir(), "sub", "rc")
	r, err := InstallExportBlock(rc, "x", true)
	if err != nil || !r.Changed || r.Backup != "" {
		t.Fatalf("%+v %v", r, err)
	}
	if st, _ := os.Stat(rc); st.Mode().Perm() != 0o600 {
		t.Errorf("mode %v", st.Mode().Perm())
	}
}

func TestInstallBlockWarnsWorldReadable(t *testing.T) {
	rc := filepath.Join(t.TempDir(), "rc")
	os.WriteFile(rc, []byte("a\n"), 0o644)
	os.Chmod(rc, 0o644)
	r, _ := InstallExportBlock(rc, "x", true)
	if len(r.Warnings) == 0 {
		t.Error("no readability warning")
	}
}

func TestInstallFollowsSymlinkedRCToRealFile(t *testing.T) {
	d := t.TempDir()
	real := filepath.Join(d, "real")
	os.WriteFile(real, []byte("a\n"), 0o600)
	link := filepath.Join(d, "rc")
	os.Symlink(real, link)
	if _, err := InstallExportBlock(link, "x", true); err != nil {
		t.Fatal(err)
	}
	if st, _ := os.Lstat(link); st.Mode()&os.ModeSymlink == 0 {
		t.Error("symlink replaced by a regular file")
	}
	if b, _ := os.ReadFile(real); !contains(string(b), BlockBegin) {
		t.Error("real file not updated")
	}
}

func TestNothingModifiedAutomatically(t *testing.T) {
	home := t.TempDir()
	rc := filepath.Join(home, ".bashrc")
	os.WriteFile(rc, []byte("x\n"), 0o600)
	t.Setenv("HOME", home)
	f := newFixture(t)
	f.resolve(Environ{})
	Rotate(f.dir, Environ{}, 0, time.Now())
	if b, _ := os.ReadFile(rc); string(b) != "x\n" {
		t.Fatal("shell startup file modified automatically")
	}
}
