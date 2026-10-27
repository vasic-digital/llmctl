//go:build linux

package registry

import (
	"os"
	"os/exec"
	"strconv"
	"testing"
	"time"
)

// Control needle for the detector: a process that is known to be running with the
// run marker MUST be seen, and a marker nobody carries MUST see nothing; a blind
// detector would otherwise report "no leaks" forever.
func TestLeakDetectorSeesAKnownProcessAndNothingElse(t *testing.T) {
	cmd := exec.Command("sleep", "30")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cmd.Process.Kill(); _, _ = cmd.Process.Wait() })
	time.Sleep(100 * time.Millisecond)
	found := false
	for _, l := range leakedProcs(os.Getenv(leakMarkerEnv)) {
		if l.pid == cmd.Process.Pid {
			found = true
		}
	}
	if !found {
		t.Fatalf("detector is blind: pid %d (marker inherited) not listed", cmd.Process.Pid)
	}
	if got := leakedProcs("no-such-run-" + strconv.Itoa(os.Getpid())); len(got) != 0 {
		t.Fatalf("detector reports processes for a marker nobody carries: %v", got)
	}
}
