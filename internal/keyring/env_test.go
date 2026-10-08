package keyring

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func TestParseBasic(t *testing.T) {
	m, err := ParseEnvText("# c\n\nA=1\nexport B=\"two words\"\nC='x'\n  D = 4  \nE=\n")
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{"A": "1", "B": "two words", "C": "x", "D": "4", "E": ""}
	for k, v := range want {
		if got, ok := m[k]; !ok || got != v {
			t.Errorf("%s=%q want %q", k, got, v)
		}
	}
	if len(m) != len(want) {
		t.Errorf("extra: %v", m)
	}
}

func TestParseNeverExecutes(t *testing.T) {
	tmp := t.TempDir()
	marker := filepath.Join(tmp, "pwned")
	for _, v := range []string{"$(touch " + marker + ")", "`touch " + marker + "`", "a$(b)"} {
		_, err := ParseEnvText("X=" + v + "\n")
		if !errors.Is(err, ErrEnvFile) {
			t.Errorf("%q: %v", v, err)
		}
	}
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("something was executed")
	}
	// plain $VAR is data, never expanded
	m, err := ParseEnvText("X=$HOME\n")
	if err != nil || m["X"] != "$HOME" {
		t.Errorf("%v %v", m, err)
	}
}

func TestParseRejectsGarbageWithoutEchoing(t *testing.T) {
	_, err := ParseEnvText("fine=1\noops " + goodKey + "\n")
	if err == nil || contains(err.Error(), goodKey) || !contains(err.Error(), "line 2") {
		t.Fatalf("%v", err)
	}
	for _, bad := range []string{"1BAD=x\n", "BA D=x\n", "=x\n", "-a=1\n"} {
		if _, err := ParseEnvText(bad); !errors.Is(err, ErrEnvFile) {
			t.Errorf("%q accepted", bad)
		}
	}
}

func TestParseRejectsNULAndCR(t *testing.T) {
	for _, bad := range []string{"A=1\x00\n", "A=1\r\n", "A=\r1\n"} {
		if _, err := ParseEnvText(bad); !errors.Is(err, ErrEnvFile) {
			t.Errorf("%q accepted", bad)
		}
	}
}

func TestParseDuplicateLastWins(t *testing.T) {
	m, _ := ParseEnvText("A=1\nA=2\n")
	if m["A"] != "2" {
		t.Fatal(m)
	}
}

func TestWriteCreates0600NoLeftoverTemp(t *testing.T) {
	f := newFixture(t)
	if err := WriteEnvValues(f.file, map[string]string{"LLMCTL_API_KEY": goodKey}, nil); err != nil {
		t.Fatal(err)
	}
	if f.mode() != 0o600 {
		t.Errorf("mode %v", f.mode())
	}
	ents, _ := os.ReadDir(f.dir)
	if len(ents) != 1 || ents[0].Name() != ".env" {
		t.Errorf("leftovers: %v", ents)
	}
}

func TestWriteCreatesMissingParentDirs(t *testing.T) {
	f := newFixture(t)
	p := filepath.Join(f.dir, "a", "b", "x.env")
	if err := WriteEnvValues(p, map[string]string{"A": "1"}, nil); err != nil {
		t.Fatal(err)
	}
}

func TestWriteRejectsUnsafeValuesAndNames(t *testing.T) {
	f := newFixture(t)
	for _, v := range []string{"a\nb", "a\rb", "a\x00b", "`x`", "$(x)"} {
		if err := WriteEnvValues(f.file, map[string]string{"A": v}, nil); !errors.Is(err, ErrEnvFile) {
			t.Errorf("value %q accepted", v)
		}
	}
	if err := WriteEnvValues(f.file, map[string]string{"1bad": "x"}, nil); !errors.Is(err, ErrEnvFile) {
		t.Error("bad name accepted")
	}
	if _, err := os.Stat(f.file); err == nil {
		t.Error("file created despite refusal")
	}
}

func TestWriteIsExclusiveTemp(t *testing.T) {
	// A pre-existing temp-looking file must never be clobbered/followed.
	f := newFixture(t)
	victim := filepath.Join(f.dir, "victim")
	os.WriteFile(victim, []byte("keep"), 0o600)
	os.Symlink(victim, filepath.Join(f.dir, ".env.0.tmp"))
	if err := WriteEnvValues(f.file, map[string]string{"A": "1"}, nil); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(victim); string(b) != "keep" {
		t.Fatal("symlinked temp followed")
	}
}

func TestWriteRefusesToRewriteUnparseableFile(t *testing.T) {
	f := newFixture(t)
	f.write("this is not an env file "+goodKey+"\n", 0o600)
	before := f.read()
	if err := WriteEnvValues(f.file, map[string]string{"A": "1"}, nil); !errors.Is(err, ErrEnvFile) {
		t.Fatalf("%v", err)
	}
	if f.read() != before {
		t.Fatal("file modified")
	}
}

func TestLooseModeTightened(t *testing.T) {
	f := newFixture(t)
	f.write("LLMCTL_API_KEY="+goodKey+"\n", 0o644)
	r, err := f.resolve(Environ{})
	if err != nil || r.Key.Reveal() != goodKey {
		t.Fatalf("%v", err)
	}
	if f.mode() != 0o600 {
		t.Errorf("mode %v", f.mode())
	}
}

func TestLooseModeRefusedWhenCannotTighten(t *testing.T) {
	f := newFixture(t)
	f.write("LLMCTL_API_KEY="+goodKey+"\n", 0o644)
	old := fchmodFn
	fchmodFn = func(*os.File, os.FileMode) error { return os.ErrPermission }
	defer func() { fchmodFn = old }()
	_, err := f.resolve(Environ{})
	if !errors.Is(err, ErrUnsafePermissions) || !contains(err.Error(), "chmod 600") || contains(err.Error(), goodKey) {
		t.Fatalf("%v", err)
	}
}

func TestLooseModeChmodSilentlyIneffectiveStillRefused(t *testing.T) {
	f := newFixture(t)
	f.write("LLMCTL_API_KEY="+goodKey+"\n", 0o644)
	old := fchmodFn
	fchmodFn = func(*os.File, os.FileMode) error { return nil } // lies
	defer func() { fchmodFn = old }()
	if _, err := f.resolve(Environ{}); !errors.Is(err, ErrUnsafePermissions) {
		t.Fatalf("%v", err)
	}
}

func TestSymlinkRefused(t *testing.T) {
	f := newFixture(t)
	target := filepath.Join(f.dir, "real.env")
	os.WriteFile(target, []byte("LLMCTL_API_KEY="+goodKey+"\n"), 0o600)
	os.Symlink(target, f.file)
	_, err := f.resolve(Environ{})
	if !errors.Is(err, ErrEnvFile) || !contains(err.Error(), "symlink") {
		t.Fatalf("%v", err)
	}
}

func TestNonRegularRefused(t *testing.T) {
	f := newFixture(t)
	os.Mkdir(f.file, 0o700)
	if _, err := f.resolve(Environ{}); !errors.Is(err, ErrEnvFile) {
		t.Fatalf("%v", err)
	}
}

func TestForeignOwnerRefused(t *testing.T) {
	f := newFixture(t)
	f.write("LLMCTL_API_KEY="+goodKey+"\n", 0o600)
	old := currentUID
	currentUID = func() int { return os.Getuid() + 1 }
	defer func() { currentUID = old }()
	_, err := f.resolve(Environ{})
	if !errors.Is(err, ErrEnvFile) || !contains(err.Error(), "another user") {
		t.Fatalf("%v", err)
	}
	// sanity: real uid matches the file owner
	st, _ := os.Lstat(f.file)
	if int(st.Sys().(*syscall.Stat_t).Uid) != os.Getuid() {
		t.Skip("unexpected owner")
	}
}

func TestUpdatePreservesOtherLinesAndReplacesKey(t *testing.T) {
	f := newFixture(t)
	f.write("# hello\nA=1\nexport LLMCTL_API_KEY="+goodKey+"\nB=2\n", 0o600)
	if err := WriteEnvValues(f.file, map[string]string{"LLMCTL_API_KEY": goodKey2, "NEW": "n"}, nil); err != nil {
		t.Fatal(err)
	}
	want := "# hello\nA=1\nLLMCTL_API_KEY=" + goodKey2 + "\nB=2\nNEW=n\n"
	if f.read() != want {
		t.Fatalf("got %q", f.read())
	}
}

func TestRemoveNames(t *testing.T) {
	f := newFixture(t)
	f.write("A=1\nB=2\nC=3\n", 0o600)
	if err := WriteEnvValues(f.file, nil, []string{"B", "ZZ"}); err != nil {
		t.Fatal(err)
	}
	if f.read() != "A=1\nC=3\n" {
		t.Fatalf("%q", f.read())
	}
}

func TestReadMissingIsEmpty(t *testing.T) {
	m, err := ReadEnvFile(filepath.Join(t.TempDir(), "none"))
	if err != nil || len(m) != 0 {
		t.Fatal(m, err)
	}
}

func TestReadInvalidUTF8(t *testing.T) {
	f := newFixture(t)
	f.write("A=\xff\xfe\n", 0o600)
	if _, err := ReadEnvFile(f.file); !errors.Is(err, ErrEnvFile) {
		t.Fatalf("%v", err)
	}
}

func TestUnreadableDirectoryIsEnvFileError(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("root")
	}
	f := newFixture(t)
	sub := filepath.Join(f.dir, "locked")
	os.Mkdir(sub, 0o700)
	p := filepath.Join(sub, ".env")
	os.WriteFile(p, []byte("A=1\n"), 0o600)
	os.Chmod(sub, 0)
	defer os.Chmod(sub, 0o700)
	if _, err := ReadEnvFile(p); !errors.Is(err, ErrEnvFile) {
		t.Fatalf("%v", err)
	}
}

func TestEnvFilePathDefault(t *testing.T) {
	if got := EnvFilePath("/some/root", Environ{}); got != "/some/root/.env" {
		t.Fatal(got)
	}
	if got := EnvFilePath("/r", Environ{"LLMCTL_ENV_FILE": "/x/y.env"}); got != "/x/y.env" {
		t.Fatal(got)
	}
}

func TestWriteNoTrailingNoisy(t *testing.T) {
	f := newFixture(t)
	if err := WriteEnvValues(f.file, map[string]string{"A": "1"}, nil); err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(f.read(), "A=1\n") || !strings.HasPrefix(f.read(), "# llmctl environment") {
		t.Fatalf("%q", f.read())
	}
}
