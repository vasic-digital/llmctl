package gateway

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func startSleeper(t *testing.T) *exec.Cmd {
	t.Helper()
	c := exec.Command("sleep", "300")
	if err := c.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Process.Kill(); _, _ = c.Process.Wait() })
	return c
}

// startFakeServe runs a stub executable named <name> as `<name> serve`, so its /proc cmdline and
// executable look like the gateway's (the verification is positional and by executable, B-09).
func startFakeServe(t *testing.T, name string) *exec.Cmd {
	t.Helper()
	return startStub(t, cachedStub(t, name), "serve")
}

func TestPidfileRoundTripMode0600(t *testing.T) {
	p := filepath.Join(t.TempDir(), "run", "decide.pid")
	now := time.Unix(1700000000, 0)
	if err := WritePidfile(p, 4242, now); err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(p)
	if err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v %v", st, err)
	}
	info, err := ReadPidfile(p)
	if err != nil || info.PID != 4242 || !info.Start.Equal(now) {
		t.Fatalf("%+v %v", info, err)
	}
	if _, err := ReadPidfile(filepath.Join(t.TempDir(), "none")); !os.IsNotExist(err) {
		t.Fatalf("missing pidfile must be IsNotExist, got %v", err)
	}
	_ = os.WriteFile(p, []byte("garbage"), 0o600)
	if _, err := ReadPidfile(p); err == nil {
		t.Fatal("garbage pidfile")
	}
}

func TestVerifyRefusesLowPids(t *testing.T) {
	for _, pid := range []int{-1, 0, 1} {
		if err := VerifyServeProcess(pid, "llmctl-decide"); err == nil {
			t.Fatalf("pid %d must be refused", pid)
		}
	}
}

func TestVerifyRejectsUnrelatedProcess(t *testing.T) {
	c := startSleeper(t)
	if err := VerifyServeProcess(c.Process.Pid, "llmctl-decide"); err == nil {
		t.Fatal("a sleep process is not the gateway")
	}
}

func TestVerifyAcceptsGatewayShapedCmdline(t *testing.T) {
	c := startFakeServe(t, "llmctl-decide-fake")
	if err := VerifyServeProcess(c.Process.Pid, "llmctl-decide-fake"); err != nil {
		t.Fatalf("%v", err)
	}
	if err := VerifyServeProcess(c.Process.Pid, "other-binary"); err == nil {
		t.Fatal("wrong binary name must be refused")
	}
}

func TestStopNeverSignalsUnverifiedProcess(t *testing.T) {
	c := startSleeper(t)
	pf := filepath.Join(t.TempDir(), "decide.pid")
	_ = WritePidfile(pf, c.Process.Pid, time.Now())
	var signalled []int
	res, err := StopGateway(pf, "llmctl-decide", time.Second, func(pid int, _ syscall.Signal) error {
		signalled = append(signalled, pid)
		return nil
	})
	if err == nil || res != StopRefused {
		t.Fatalf("res=%v err=%v", res, err)
	}
	if len(signalled) != 0 {
		t.Fatal("signalled an unverified process")
	}
	if err := syscall.Kill(c.Process.Pid, 0); err != nil {
		t.Fatal("the unrelated process must still be alive")
	}
}

func TestStopSignalsVerifiedProcessOnly(t *testing.T) {
	c := startFakeServe(t, "llmctl-decide-fake")
	pf := filepath.Join(t.TempDir(), "decide.pid")
	_ = WritePidfile(pf, c.Process.Pid, time.Now())
	var got []int
	var sig syscall.Signal
	res, err := StopGateway(pf, "llmctl-decide-fake", 2*time.Second, func(pid int, s syscall.Signal) error {
		got, sig = append(got, pid), s
		return syscall.Kill(pid, s)
	})
	_, _ = c.Process.Wait()
	if err != nil || res != Stopped {
		t.Fatalf("res=%v err=%v", res, err)
	}
	if len(got) != 1 || got[0] != c.Process.Pid || got[0] <= 1 || sig != syscall.SIGTERM {
		t.Fatalf("signals: %v %v", got, sig)
	}
	if _, err := os.Stat(pf); !os.IsNotExist(err) {
		t.Fatal("pidfile must be removed after a clean stop")
	}
}

func TestStopNeverUsesProcessGroup(t *testing.T) {
	c := startFakeServe(t, "llmctl-decide-fake")
	pf := filepath.Join(t.TempDir(), "decide.pid")
	_ = WritePidfile(pf, c.Process.Pid, time.Now())
	_, _ = StopGateway(pf, "llmctl-decide-fake", time.Second, func(pid int, s syscall.Signal) error {
		if pid <= 1 {
			t.Errorf("pid %d <= 1 would be a process-group / broadcast signal", pid)
			return nil
		}
		return syscall.Kill(pid, s)
	})
	_, _ = c.Process.Wait()
}

func TestStopStalePidfileAndAbsent(t *testing.T) {
	pf := filepath.Join(t.TempDir(), "decide.pid")
	res, err := StopGateway(pf, "llmctl-decide", time.Second, nil)
	if err != nil || res != NotRunning {
		t.Fatalf("absent: %v %v", res, err)
	}
	// a pidfile naming a dead process is stale: removed, not an error, nothing signalled
	c := exec.Command("true")
	_ = c.Run()
	_ = WritePidfile(pf, c.Process.Pid, time.Now())
	res, err = StopGateway(pf, "llmctl-decide", time.Second, func(int, syscall.Signal) error { t.Fatal("signalled"); return nil })
	if err != nil || res != NotRunning {
		t.Fatalf("stale: %v %v", res, err)
	}
	if _, err := os.Stat(pf); !os.IsNotExist(err) {
		t.Fatal("stale pidfile should be cleaned")
	}
}

func TestStatusReportsVerifiedState(t *testing.T) {
	pf := filepath.Join(t.TempDir(), "decide.pid")
	st, _ := GatewayStatus(pf, "llmctl-decide")
	if st.Running {
		t.Fatal("absent")
	}
	sl := startSleeper(t)
	_ = WritePidfile(pf, sl.Process.Pid, time.Now())
	st, _ = GatewayStatus(pf, "llmctl-decide")
	if st.Running || !strings.Contains(st.Reason, "not the gateway") {
		t.Fatalf("unverified pid must not be reported running: %+v", st)
	}
	g := startFakeServe(t, "llmctl-decide-fake")
	gi := infoFor(t, g.Process.Pid, cachedStub(t, "llmctl-decide-fake"))
	gi.Start = time.Now().Add(-time.Minute)
	_ = writePidInfo(pf, gi)
	st, _ = GatewayStatus(pf, "llmctl-decide-fake")
	if !st.Running || st.PID != g.Process.Pid || st.Uptime < time.Minute {
		t.Fatalf("%+v", st)
	}
}

// The pid <= 1 refusal must not depend on what pid 1 happens to be: even a gateway-shaped command
// line at pid 1 (or 0) is refused before /proc is consulted.
func TestVerifyRefusesLowPidsEvenWithGatewayShapedCmdline(t *testing.T) {
	old := procCmdline
	defer func() { procCmdline = old }()
	procCmdline = func(int) ([]byte, error) { return []byte("llmctl-decide\x00serve\x00"), nil }
	for _, pid := range []int{-5, 0, 1} {
		if err := VerifyServeProcess(pid, "llmctl-decide"); err == nil {
			t.Fatalf("pid %d must be refused regardless of its cmdline", pid)
		}
	}
	if err := VerifyServeProcess(2, "llmctl-decide"); err != nil {
		t.Fatalf("a gateway-shaped cmdline at pid 2 is accepted: %v", err)
	}
}

// A2-07 / B2-07: pidfd access goes through golang.org/x/sys/unix in a linux-only file. A raw
// syscall.Syscall with a hard-coded number is wrong on mips* and, without a build constraint, calls an
// unrelated BSD syscall on macOS. No file of this package that lacks a linux constraint may issue a
// raw syscall or carry a syscall number.
func TestNoRawSyscallOutsideLinuxOnlyFiles(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil || len(files) == 0 {
		t.Fatalf("glob: %v", err)
	}
	checked := 0
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		src := string(b)
		linuxOnly := strings.HasSuffix(f, "_linux.go") || strings.Contains(src, "//go:build linux")
		checked++
		if linuxOnly {
			if strings.Contains(src, "syscall.Syscall") {
				t.Errorf("%s: raw syscall.Syscall; use golang.org/x/sys/unix", f)
			}
			continue
		}
		for _, bad := range []string{"syscall.Syscall", "sysPidfd", "= 434", "= 424"} {
			if strings.Contains(src, bad) {
				t.Errorf("%s: contains %q but has no linux build constraint", f, bad)
			}
		}
	}
	if checked < 3 {
		t.Fatalf("the scan saw only %d files; the instrument is blind", checked)
	}
	// control needle: the pidfd implementation file for linux must exist and be found by the scan
	if _, err := os.Stat("proc_linux.go"); err != nil {
		t.Fatalf("proc_linux.go missing: %v", err)
	}
}
