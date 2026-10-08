package keyring

import (
	"bytes"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

type cliRes struct {
	rc       int
	out, err string
}

func runCLI(root string, env Environ, args ...string) cliRes {
	var o, e bytes.Buffer
	rc := Run(args, env, root, &o, &e)
	return cliRes{rc, strings.TrimRight(o.String(), "\n"), e.String()}
}

func TestCLIPathAndDoctorBeforeKey(t *testing.T) {
	f := newFixture(t)
	r := runCLI(f.dir, Environ{}, "path")
	if r.rc != 0 || r.out != f.file {
		t.Fatalf("%+v", r)
	}
	r = runCLI(f.dir, Environ{}, "doctor")
	if r.rc != 0 || !contains(r.out, "none") {
		t.Fatalf("%+v", r)
	}
	if _, err := os.Stat(f.file); err == nil {
		t.Fatal("doctor generated a key")
	}
}

func TestCLIShowNeedsYesPrint(t *testing.T) {
	f := newFixture(t)
	if r := runCLI(f.dir, Environ{}, "show"); r.rc != 2 {
		t.Fatalf("%+v", r)
	}
	if r := runCLI(f.dir, Environ{}, "show", "--yes-print"); r.rc != 4 {
		t.Fatalf("no key => 4: %+v", r)
	}
}

func TestCLIRotateDoctorShowFlow(t *testing.T) {
	f := newFixture(t)
	r := runCLI(f.dir, Environ{}, "rotate")
	if r.rc != 0 || f.mode() != 0o600 {
		t.Fatalf("%+v %v", r, f.mode())
	}
	k1 := regexp.MustCompile(`LLMCTL_API_KEY=(\S+)`).FindStringSubmatch(f.read())[1]
	if contains(r.out+r.err, k1) {
		t.Fatal("rotate printed the key")
	}
	d := runCLI(f.dir, Environ{}, "doctor")
	if d.rc != 0 || contains(d.out+d.err, k1) || !contains(d.out, "file") || !contains(d.out, "600") {
		t.Fatalf("%+v", d)
	}
	s := runCLI(f.dir, Environ{}, "show", "--yes-print")
	if s.rc != 0 || s.out != k1 {
		t.Fatalf("show: %+v", s)
	}
	r2 := runCLI(f.dir, Environ{}, "rotate", "--grace", "600")
	k2 := regexp.MustCompile(`(?m)^LLMCTL_API_KEY=(\S+)`).FindStringSubmatch(f.read())[1]
	if r2.rc != 0 || k2 == k1 || !contains(f.read(), "LLMCTL_API_KEY_PREVIOUS="+k1) || !contains(r2.out, "grace") {
		t.Fatalf("%+v", r2)
	}
	if contains(r2.out+r2.err, k1) || contains(r2.out+r2.err, k2) {
		t.Fatal("rotate --grace printed a key")
	}
	if !contains(r2.out, "update checklist") {
		t.Error("no checklist")
	}
}

func TestCLIDoctorShadowAndMalformed(t *testing.T) {
	f := newFixture(t)
	runCLI(f.dir, Environ{}, "rotate")
	envKey := "E" + goodKey2
	d := runCLI(f.dir, Environ{"LLMCTL_API_KEY": envKey}, "doctor")
	if d.rc != 0 || !contains(d.out, "env") || !contains(d.out, "shadow") || contains(d.out+d.err, envKey) {
		t.Fatalf("%+v", d)
	}
	if d := runCLI(f.dir, Environ{"LLMCTL_API_KEY": "short"}, "doctor"); d.rc != 4 {
		t.Fatalf("%+v", d)
	}
	if d := runCLI(f.dir, Environ{"LLMCTL_API_KEY": ""}, "show", "--yes-print"); d.rc != 4 {
		t.Fatalf("blank env: %+v", d)
	}
	os.Chmod(f.file, 0o644)
	if d := runCLI(f.dir, Environ{}, "doctor"); d.rc != 0 || f.mode() != 0o600 {
		t.Fatalf("%+v %v", d, f.mode())
	}
}

func TestCLIRotateWarnsWhenEnvShadows(t *testing.T) {
	f := newFixture(t)
	r := runCLI(f.dir, Environ{"LLMCTL_API_KEY": goodKey}, "rotate")
	if r.rc != 0 || !contains(r.out, "warning") || contains(r.out, goodKey) {
		t.Fatalf("%+v", r)
	}
}

func TestCLIEnvFileOverride(t *testing.T) {
	f := newFixture(t)
	ovr := filepath.Join(f.dir, "elsewhere", "my.env")
	env := Environ{"LLMCTL_ENV_FILE": ovr}
	if r := runCLI(f.dir, env, "path"); r.out != ovr {
		t.Fatal(r)
	}
	if r := runCLI(f.dir, env, "rotate"); r.rc != 0 {
		t.Fatal(r)
	}
	if _, err := os.Stat(ovr); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(f.file); err == nil {
		t.Fatal("default touched")
	}
}

func TestCLIExport(t *testing.T) {
	f := newFixture(t)
	runCLI(f.dir, Environ{}, "rotate")
	rc := filepath.Join(f.dir, "fakerc")
	os.WriteFile(rc, []byte("alias ll=ls\n"), 0o600)
	if r := runCLI(f.dir, Environ{}, "export"); r.rc != 2 {
		t.Fatalf("no --file: %+v", r)
	}
	if b, _ := os.ReadFile(rc); string(b) != "alias ll=ls\n" {
		t.Fatal("touched")
	}
	r := runCLI(f.dir, Environ{}, "export", "--file", rc)
	key := regexp.MustCompile(`(?m)^LLMCTL_API_KEY=(\S+)`).FindStringSubmatch(f.read())[1]
	if r.rc != 0 || !contains(r.out, "export LLMCTL_API_KEY=") || contains(r.out, key) || !contains(r.out, "written") {
		t.Fatalf("%+v", r)
	}
	snap, _ := os.ReadFile(rc)
	r = runCLI(f.dir, Environ{}, "export", "--file", rc)
	after, _ := os.ReadFile(rc)
	if r.rc != 0 || string(snap) != string(after) || !contains(r.out, "no change") {
		t.Fatalf("%+v", r)
	}
	rc2 := filepath.Join(f.dir, "fakerc2")
	if r := runCLI(f.dir, Environ{}, "export", "--file", rc2, "--inline"); r.rc != 2 {
		t.Fatalf("%+v", r)
	}
	if _, err := os.Stat(rc2); err == nil {
		t.Fatal("inline refusal wrote file")
	}
	if r := runCLI(f.dir, Environ{}, "export", "--file", rc2, "--inline", "--yes-print"); r.rc != 0 {
		t.Fatalf("%+v", r)
	}
	if b, _ := os.ReadFile(rc2); !contains(string(b), `export LLMCTL_API_KEY="`+key+`"`) {
		t.Fatal("inline form missing key")
	}
	empty := newFixture(t)
	if r := runCLI(empty.dir, Environ{}, "export", "--file", rc2, "--inline", "--yes-print"); r.rc != 4 {
		t.Fatalf("no key inline: %+v", r)
	}
	if r := runCLI(f.dir, Environ{}, "export", "--file", rc2, "--shell", "tcsh"); r.rc != 2 {
		t.Fatalf("bad shell: %+v", r)
	}
}

func TestCLIPlacementGuard(t *testing.T) {
	f := newFixture(t)
	mustGit(t, f.dir, "init", "-q")
	r := runCLI(f.dir, Environ{}, "rotate")
	if r.rc != 4 || !contains(r.err, f.file) || !contains(r.err, ".gitignore") {
		t.Fatalf("%+v", r)
	}
	if _, err := os.Stat(f.file); err == nil {
		t.Fatal("created")
	}
	if d := runCLI(f.dir, Environ{}, "doctor"); d.rc != 4 {
		t.Fatalf("doctor in unignored repo: %+v", d)
	}
	os.WriteFile(filepath.Join(f.dir, ".gitignore"), []byte(".env\n"), 0o644)
	if r := runCLI(f.dir, Environ{}, "rotate"); r.rc != 0 || f.mode() != 0o600 {
		t.Fatalf("%+v", r)
	}
}

func TestCLIUsage(t *testing.T) {
	f := newFixture(t)
	for _, args := range [][]string{{}, {"frobnicate"}, {"rotate", "--grace", "-5"}, {"rotate", "--grace", "x"}, {"show", "--nope"}, {"path", "extra"}} {
		if r := runCLI(f.dir, Environ{}, args...); r.rc != 2 {
			t.Errorf("%v => %d", args, r.rc)
		}
	}
	if r := runCLI(f.dir, Environ{}, "--root", f.dir, "path"); r.rc != 0 || r.out != f.file {
		t.Errorf("--root: %+v", r)
	}
	other := t.TempDir()
	if r := runCLI(f.dir, Environ{}, "--root", other, "path"); r.out != filepath.Join(other, ".env") {
		t.Errorf("--root override: %+v", r)
	}
}
