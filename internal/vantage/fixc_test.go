package vantage

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"digital.vasic.containers/pkg/runtime"
)

// C-07: two state dirs on one host. Down of one must not remove the other's vantage.
func TestC07DownRemovesOnlyItsOwnStateDirsContainers(t *testing.T) {
	f := newFake()
	a := newMgr(t, f)
	b := newMgr(t, f)
	if a.ownerID() == b.ownerID() {
		t.Fatal("two state dirs must have different owner ids")
	}
	sa, err := a.Up(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	sb, err := b.Up(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	// a leaves an untracked straggler of its own (crash between run and save) plus one from b
	f.containers[NamePrefix+"a-orphan"] = runtime.StateRunning
	f.labels[NamePrefix+"a-orphan"] = map[string]string{LabelKey: "1", LabelOwner: a.ownerID()}
	if err := a.Down(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, ok := f.containers[sa.Name]; ok {
		t.Fatal("a's own container survived its Down")
	}
	if _, ok := f.containers[NamePrefix+"a-orphan"]; ok {
		t.Fatal("a's own untracked straggler survived its Down")
	}
	if _, ok := f.containers[sb.Name]; !ok {
		t.Fatal("a's Down removed b's vantage container (another state dir's)")
	}
	if st, _ := b.Status(context.Background()); !st.Up {
		t.Fatal("b's vantage is no longer running")
	}
	// the explicit host-wide recovery sweep does remove it
	if err := a.DownAll(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, ok := f.containers[sb.Name]; ok {
		t.Fatal("DownAll must also remove other owners' vantage containers")
	}
}

// A container carrying the vantage label but a FOREIGN owner (or none at all) is not swept by Down.
func TestC07ForeignOwnerAndUnownedAreLeftAlone(t *testing.T) {
	f := newFake()
	m := newMgr(t, f)
	f.containers[NamePrefix+"other"] = runtime.StateRunning
	f.labels[NamePrefix+"other"] = map[string]string{LabelKey: "1", LabelOwner: "deadbeef0000"}
	f.containers[NamePrefix+"legacy"] = runtime.StateRunning
	f.labels[NamePrefix+"legacy"] = map[string]string{LabelKey: "1"}
	if err := m.Down(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(f.containers) != 2 {
		t.Fatalf("Down swept containers that are not its own: %v", f.containers)
	}
}

// C-15: Down must not RemoveAll a directory it cannot prove is its own.
func TestC15DownDeletesOnlyFilesItWrote(t *testing.T) {
	f := newFake()
	m := newMgr(t, f)
	// a pre-existing, unrelated ~/vantage with precious content and NO state.json
	vd := filepath.Join(m.o.StateDir, "vantage")
	if err := os.MkdirAll(vd, 0o700); err != nil {
		t.Fatal(err)
	}
	precious := filepath.Join(vd, "my-notes.txt")
	if err := os.WriteFile(precious, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := m.Down(context.Background()); err != nil {
		t.Fatal(err)
	}
	if b, err := os.ReadFile(precious); err != nil || string(b) != "keep" {
		t.Fatalf("Down deleted a file it never wrote: %v", err)
	}
	// after a real Up, Down removes what Up wrote and, the directory being its own, the directory
	if _, err := m.Up(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := m.Down(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(vd, "state.json")); !os.IsNotExist(err) {
		t.Fatal("state.json survived Down")
	}
	if _, err := os.Stat(precious); err != nil {
		t.Fatal("the unrelated file was removed by Down")
	}
	if _, err := os.Stat(filepath.Join(vd, "probe")); !os.IsNotExist(err) {
		t.Fatal("the staged probe dir (ours, now empty) must be gone")
	}
}

// C-16: headers and body never appear on the exec argv.
func TestC16ProbeHeadersAndBodyNeverOnArgv(t *testing.T) {
	f := newFake()
	f.execOut["http"] = `{"status":200}`
	m := newMgr(t, f)
	st, err := m.Up(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	f.execCmds = nil
	if _, err := m.Probe(context.Background(), ProbeRequest{URL: "https://x:1/v1", Method: "POST",
		Headers: []string{"Authorization: Bearer s3cr3t-token"}, Body: `{"q":"private-body"}`}); err != nil {
		t.Fatal(err)
	}
	if len(f.execCmds) != 1 {
		t.Fatalf("exec calls: %v", f.execCmds)
	}
	argv := strings.Join(f.execCmds[0], " ")
	for _, leak := range []string{"s3cr3t-token", "Authorization", "private-body"} {
		if strings.Contains(argv, leak) {
			t.Fatalf("%q travelled on the exec argv (visible in ps): %s", leak, argv)
		}
	}
	if !strings.Contains(argv, "--request-file /vantage/req-") {
		t.Fatalf("the request must pass through a request file: %s", argv)
	}
	// the request file was removed after the call and was 0600 while it existed
	ents, _ := os.ReadDir(st.ProbeDir)
	for _, e := range ents {
		if strings.HasPrefix(e.Name(), "req-") {
			t.Fatalf("request file %s left behind (it holds the bearer)", e.Name())
		}
	}
}

func TestC16RequestFileIs0600(t *testing.T) {
	m := newMgr(t, newFake())
	dir := t.TempDir()
	name, err := m.writeRequestFile(&State{ProbeDir: dir}, ProbeRequest{Headers: []string{"A: b"}, Body: "x"})
	if err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(filepath.Join(dir, name))
	if err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("request file mode: %v %v", fi, err)
	}
}

// C2-09: the CLI wiring of `vantage down --all` (a flag read into downAll, then selecting m.DownAll over
// m.Down). The library-level DownAll is covered above; this proves the flag reaches it. Mutation M-G4
// (`down = m.DownAll` replaced by a no-op) survived every earlier test.
func TestC209CLIDownAllRemovesOtherOwnersContainers(t *testing.T) {
	f := newFake()
	pr := probe(t)
	call := func(dir string, args ...string) (int, string, string) {
		var o, e bytes.Buffer
		env := map[string]string{"LLMCTL_STATE_DIR": dir, "LLMCTL_VANTAGE_PROBE": pr}
		c := Run(args, func(k string) string { return env[k] }, f, &o, &e)
		return c, o.String(), e.String()
	}
	dirA, dirB := t.TempDir(), t.TempDir()
	for _, d := range []string{dirA, dirB} {
		if c, o, e := call(d, "up", "--host-ip", "192.168.1.115", "--image", "img-z"); c != ExitOK {
			t.Fatalf("up in %s: %d %s %s", d, c, o, e)
		}
	}
	count := func() int {
		n := 0
		for name := range f.containers {
			if strings.HasPrefix(name, NamePrefix) {
				n++
			}
		}
		return n
	}
	if n := count(); n != 2 {
		t.Fatalf("want 2 vantage containers (one per owner), have %d", n)
	}
	// control: plain `down` in A removes ONLY A's container
	if c, _, e := call(dirA, "down"); c != ExitOK {
		t.Fatalf("down: %d %s", c, e)
	}
	if n := count(); n != 1 {
		t.Fatalf("plain `down` must remove only its own owner's container; %d vantage containers remain", n)
	}
	// B's container is foreign to A: `down --all` from A must sweep it
	if c, _, e := call(dirA, "down", "--all"); c != ExitOK {
		t.Fatalf("down --all: %d %s", c, e)
	}
	if n := count(); n != 0 {
		t.Fatalf("`down --all` did not remove the other owner's vantage container (%d remain): the CLI flag is not wired to DownAll", n)
	}
}
