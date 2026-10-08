package gateway

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// PidInfo is the content of the gateway pidfile: "<pid> <unix-start>" and, when the writer could
// read its own identity, "<starttime-ticks> <exe-dev>:<exe-inode>". The identity is what defeats pid
// reuse: a recycled pid has another start time, and an imposter another executable.
type PidInfo struct {
	PID   int
	Start time.Time
	// StartTicks is field 22 of /proc/<pid>/stat (clock ticks since boot) of the writer.
	StartTicks uint64
	// ExeDev/ExeIno identify the writer's executable file (device and inode of /proc/<pid>/exe).
	ExeDev, ExeIno uint64
	HasIdentity    bool
}

// WritePidfile writes the pidfile atomically with mode 0600 (directory 0700). When pid is this
// process the start ticks and the executable's device+inode are recorded too.
func WritePidfile(path string, pid int, start time.Time) error {
	info := PidInfo{PID: pid, Start: start}
	if pid == os.Getpid() {
		if ticks, err := procStartTicks(pid); err == nil {
			if dev, ino, err := fileIdentity(fmt.Sprintf("/proc/%d/exe", pid)); err == nil {
				info.StartTicks, info.ExeDev, info.ExeIno, info.HasIdentity = ticks, dev, ino, true
			}
		}
	}
	return writePidInfo(path, info)
}

func writePidInfo(path string, info PidInfo) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".pid-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	line := fmt.Sprintf("%d %d", info.PID, info.Start.Unix())
	if info.HasIdentity {
		line += fmt.Sprintf(" %d %d:%d", info.StartTicks, info.ExeDev, info.ExeIno)
	}
	if _, err := fmt.Fprintln(tmp, line); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// ReadPidfile parses a pidfile (2 fields, or 4 with the identity); a missing file satisfies
// os.IsNotExist.
func ReadPidfile(path string) (PidInfo, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return PidInfo{}, err
	}
	f := strings.Fields(string(b))
	bad := errors.New("gateway: malformed pidfile")
	if len(f) != 2 && len(f) != 4 {
		return PidInfo{}, bad
	}
	pid, e1 := strconv.Atoi(f[0])
	ts, e2 := strconv.ParseInt(f[1], 10, 64)
	if e1 != nil || e2 != nil {
		return PidInfo{}, bad
	}
	info := PidInfo{PID: pid, Start: time.Unix(ts, 0)}
	if len(f) == 4 {
		ticks, e3 := strconv.ParseUint(f[2], 10, 64)
		di := strings.SplitN(f[3], ":", 2)
		if e3 != nil || len(di) != 2 {
			return PidInfo{}, bad
		}
		dev, e4 := strconv.ParseUint(di[0], 10, 64)
		ino, e5 := strconv.ParseUint(di[1], 10, 64)
		if e4 != nil || e5 != nil {
			return PidInfo{}, bad
		}
		info.StartTicks, info.ExeDev, info.ExeIno, info.HasIdentity = ticks, dev, ino, true
	}
	return info, nil
}

// procCmdline (declared per platform in proc_linux.go / proc_other.go) is replaceable inside this
// package's tests.

// procStartTicks is the process start time in clock ticks since boot (/proc/<pid>/stat field 22).
func procStartTicks(pid int) (uint64, error) {
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return 0, err
	}
	i := bytes.LastIndexByte(b, ')') // the command name may contain spaces and parentheses
	if i < 0 {
		return 0, errors.New("gateway: malformed /proc stat")
	}
	f := strings.Fields(string(b[i+1:])) // f[0] is field 3 (state); starttime is field 22 = f[19]
	if len(f) < 20 {
		return 0, errors.New("gateway: malformed /proc stat")
	}
	return strconv.ParseUint(f[19], 10, 64)
}

// fileIdentity is the device and inode of the file a path names (following /proc/<pid>/exe).
func fileIdentity(path string) (dev, ino uint64, err error) {
	var st syscall.Stat_t
	if err := syscall.Stat(path, &st); err != nil {
		return 0, 0, err
	}
	return uint64(st.Dev), uint64(st.Ino), nil
}

// bootTime is the system boot time from /proc/stat btime.
func bootTime() (time.Time, error) {
	b, err := os.ReadFile("/proc/stat")
	if err != nil {
		return time.Time{}, err
	}
	for _, l := range strings.Split(string(b), "\n") {
		if v, ok := strings.CutPrefix(l, "btime "); ok {
			n, err := strconv.ParseInt(strings.TrimSpace(v), 10, 64)
			return time.Unix(n, 0), err
		}
	}
	return time.Time{}, errors.New("gateway: no btime")
}

// errNotGateway marks a live process that is not the gateway.
var errNotGateway = errors.New("process is not the gateway")

// argvOf splits a /proc cmdline.
func argvOf(raw []byte) []string {
	raw = bytes.TrimRight(raw, "\x00")
	if len(raw) == 0 {
		return nil
	}
	var out []string
	for _, a := range bytes.Split(raw, []byte{0}) {
		out = append(out, string(a))
	}
	return out
}

// VerifyServeProcess proves pid is the gateway when the pidfile carries no identity: pid > 1, the
// executable (or, where it cannot be read, argv[0]) is binName, and the subcommand `serve` is
// argv[1] POSITIONALLY. A carrier that merely mentions the words (bash -c "... llmctl-decide serve",
// watch, less) is refused (B-09 / A-02). A pidfile alone is never trusted.
func VerifyServeProcess(pid int, binName string) error {
	return VerifyServeProcessInfo(PidInfo{PID: pid}, binName)
}

// VerifyServeProcessInfo is VerifyServeProcess against everything the pidfile recorded: when it holds
// the writer's identity the process must be that very executable (device+inode of /proc/<pid>/exe)
// with that very start time, which also defeats pid reuse; a legacy pidfile falls back to the name
// check plus "the process did not start after the pidfile was written".
func VerifyServeProcessInfo(info PidInfo, binName string) error {
	pid := info.PID
	if pid <= 1 {
		return fmt.Errorf("refusing pid %d", pid)
	}
	raw, err := procCmdline(pid)
	if err != nil {
		return err
	}
	argv := argvOf(raw)
	if len(argv) < 2 || argv[1] != "serve" {
		return errNotGateway
	}
	if info.HasIdentity {
		if err := VerifyIdentityOnly(info); err != nil {
			return err
		}
		return nil
	}
	named := filepath.Base(argv[0]) == binName
	if exe, err := os.Readlink(fmt.Sprintf("/proc/%d/exe", pid)); err == nil {
		exe = strings.TrimSuffix(exe, " (deleted)")
		named = filepath.Base(exe) == binName // the real executable decides when it can be read
	}
	if !named {
		return errNotGateway
	}
	if !info.Start.IsZero() {
		if ticks, err := procStartTicks(pid); err == nil {
			if boot, err := bootTime(); err == nil {
				started := boot.Add(time.Duration(ticks) * 10 * time.Millisecond) // USER_HZ is 100 on Linux
				if started.After(info.Start.Add(2 * time.Second)) {
					return errors.New("process started after the pidfile was written (pid reused)")
				}
			}
		}
	}
	return nil
}

// VerifyIdentityOnly checks the recorded executable identity and start time against /proc/<pid>.
func VerifyIdentityOnly(info PidInfo) error {
	if !info.HasIdentity {
		return errors.New("pidfile carries no identity")
	}
	dev, ino, err := fileIdentity(fmt.Sprintf("/proc/%d/exe", info.PID))
	if err != nil {
		return err
	}
	if dev != info.ExeDev || ino != info.ExeIno {
		return errors.New("executable differs from the one that wrote the pidfile")
	}
	ticks, err := procStartTicks(info.PID)
	if err != nil {
		return err
	}
	if ticks != info.StartTicks {
		return errors.New("start time differs from the one recorded (pid reused)")
	}
	return nil
}

func alive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

// StopResult is the outcome of StopGateway.
type StopResult int

const (
	// NotRunning: no pidfile, or it named a dead process (a stale pidfile is removed).
	NotRunning StopResult = iota
	// Stopped: the verified gateway exited after SIGTERM.
	Stopped
	// StillRunning: the verified gateway was signalled but did not exit within the grace.
	StillRunning
	// StopRefused: the pidfile named a live process that is not the gateway; nothing was signalled.
	StopRefused
)

func (r StopResult) String() string {
	return [...]string{"not running", "stopped", "still running", "refused"}[r]
}

// StopGateway signals ONLY the verified gateway process, never a pid <= 1 and never a process
// group: SIGTERM through sig (nil = syscall.Kill) to the single pid, then waits up to grace.
func StopGateway(pidfile, binName string, grace time.Duration, sig func(pid int, s syscall.Signal) error) (StopResult, error) {
	info, err := ReadPidfile(pidfile)
	if os.IsNotExist(err) {
		return NotRunning, nil
	}
	if err != nil {
		return StopRefused, err
	}
	if info.PID <= 1 {
		return StopRefused, fmt.Errorf("pidfile names pid %d; refusing", info.PID)
	}
	if !alive(info.PID) {
		_ = os.Remove(pidfile)
		return NotRunning, nil
	}
	// Pin the process with a pidfd BEFORE verifying: once held, the pid cannot be recycled under us,
	// so what was verified is what is signalled. Where pidfd is unavailable the identity is
	// re-verified immediately before the signal instead.
	pfd, pfdErr := pidfdOpenFn(info.PID)
	if pfdErr == nil {
		defer syscall.Close(pfd)
	}
	if err := VerifyServeProcessInfo(info, binName); err != nil {
		return StopRefused, fmt.Errorf("pid %d is alive but is not the gateway (%v); not signalling it", info.PID, err)
	}
	send := sig
	if send == nil {
		send = func(pid int, s syscall.Signal) error {
			if pfdErr == nil {
				return pidfdSendSignal(pfd, s)
			}
			return syscall.Kill(pid, s)
		}
	}
	if pfdErr != nil { // no pinning: verify again as close to the kill as possible
		if err := VerifyServeProcessInfo(info, binName); err != nil {
			return StopRefused, fmt.Errorf("pid %d changed identity before the signal (%v); not signalling it", info.PID, err)
		}
	}
	if err := send(info.PID, syscall.SIGTERM); err != nil {
		return StopRefused, err
	}
	deadline := time.Now().Add(grace)
	for time.Now().Before(deadline) {
		if !alive(info.PID) || zombie(info.PID) || recycled(info) {
			_ = os.Remove(pidfile)
			return Stopped, nil
		}
		time.Sleep(25 * time.Millisecond)
	}
	return StillRunning, fmt.Errorf("pid %d did not exit within %s", info.PID, grace)
}

// recycled: the pid now belongs to a process that started at another time than the gateway did.
func recycled(info PidInfo) bool {
	if !info.HasIdentity {
		return false
	}
	t, err := procStartTicks(info.PID)
	return err == nil && t != info.StartTicks
}

// pidfdOpenFn is replaceable only inside this package's tests (to exercise the no-pidfd path).
// pidfdOpen and pidfdSendSignal live in proc_linux.go (golang.org/x/sys/unix) and proc_other.go
// (ENOSYS: no pidfd off Linux, so the stop path verifies and uses kill(2) only; review A2-07).
var pidfdOpenFn = pidfdOpen

// zombie: a signalled child of ours that exited but was not yet reaped still answers kill(0).
func zombie(pid int) bool {
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return false
	}
	i := bytes.LastIndexByte(b, ')')
	return i > 0 && i+2 < len(b) && b[i+2] == 'Z'
}

// Status is the verified state of the gateway process.
type Status struct {
	Running bool
	PID     int
	Uptime  time.Duration
	Reason  string
}

// GatewayStatus reads the pidfile and verifies the process; an unverified pid is not "running".
func GatewayStatus(pidfile, binName string) (Status, error) {
	info, err := ReadPidfile(pidfile)
	if os.IsNotExist(err) {
		return Status{Reason: "no pidfile"}, nil
	}
	if err != nil {
		return Status{Reason: "unreadable pidfile"}, err
	}
	if info.PID <= 1 || !alive(info.PID) {
		return Status{PID: info.PID, Reason: "process not alive (stale pidfile)"}, nil
	}
	if err := VerifyServeProcessInfo(info, binName); err != nil {
		return Status{PID: info.PID, Reason: "pid is alive but is not the gateway"}, nil
	}
	return Status{Running: true, PID: info.PID, Uptime: time.Since(info.Start)}, nil
}
