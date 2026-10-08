package registry

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

// OSIdentity proves from the REAL process identity that pid is the program the
// entry was registered for: the pid exists AND its own argv (read from
// /proc/<pid>/cmdline; `ps` where there is no procfs) names token the way a
// launched service names itself:
//
//   - argv[0] is the token or a path whose basename is the token (an engine
//     binary: /opt/x/bin/llama-server ...), or
//   - argv[0] is a script interpreter (python, node, bash, ...) and argv[1] is
//     the script named token, or
//   - any argument equals the token exactly (an explicit marker), or
//   - an argument is a --flag=token / --flag=/path/token form.
//
// It is deliberately NOT a substring match and NOT a basename match on any
// argument: a shell, a launcher, a `tail -f /var/log/llama-server` or a
// `vim ~/llama-server` merely MENTIONS the token and is a carrier, not the
// service (Helix §11.4.196(D)/§11.4.201). pid <= 1, an empty token, a vanished
// process, and a zombie (empty argv) are all "not alive". The check proves the
// process is SOME instance of the program; it cannot tell two instances of the
// same program apart - that is ProcFingerprint's job (start time + argv hash,
// recorded at registration and compared at reconcile).
func OSIdentity(pid int, token string) bool {
	if pid <= 1 || token == "" {
		return false
	}
	args, ok := argvOf(pid)
	if !ok {
		return false
	}
	for i, a := range args {
		if matchToken(a, token, i, args) {
			return true
		}
	}
	return false
}

var interpreters = map[string]bool{
	"python": true, "python3": true, "node": true, "bash": true, "sh": true, "ruby": true, "perl": true, "uv": true,
}

func isInterpreter(arg string) bool {
	b := filepath.Base(arg)
	if interpreters[b] {
		return true
	}
	return strings.HasPrefix(b, "python3.") || strings.HasPrefix(b, "python2.")
}

// matchToken reports whether argument i of args names token (see OSIdentity for the rules).
func matchToken(arg, token string, i int, args []string) bool {
	if arg == token {
		return true // an explicit marker anywhere in argv
	}
	if i == 0 && filepath.Base(arg) == token {
		return true // the program itself
	}
	if i == 1 && len(args) > 1 && isInterpreter(args[0]) && filepath.Base(arg) == token {
		return true // interpreter + script
	}
	if _, v, ok := strings.Cut(arg, "="); ok && strings.HasPrefix(arg, "-") && (v == token || filepath.Base(v) == token) {
		return true
	}
	return false
}

// ProcFingerprint identifies one SPECIFIC process (not merely a program): the kernel boot id and
// the process start time (/proc/<pid>/stat field 22; `ps -o lstart=` without procfs) plus a hash
// of its argv. A pid that the kernel hands to a different process after the original died has a
// different start time, and another instance of the same program has a different start time and
// usually different argv, so a recorded fingerprint that no longer matches proves the registered
// service is gone. "" means the fingerprint cannot be determined (no such process).
func ProcFingerprint(pid int) string {
	if pid <= 1 {
		return ""
	}
	args, ok := argvOf(pid)
	if !ok {
		return ""
	}
	h := sha256.Sum256([]byte(strings.Join(args, "\x00")))
	sum := hex.EncodeToString(h[:8])
	if st, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat"); err == nil {
		// the command name may contain spaces and parentheses: fields restart after the LAST ')'
		s := string(st)
		if i := strings.LastIndexByte(s, ')'); i >= 0 {
			f := strings.Fields(s[i+1:])
			if len(f) > 19 { // f[0] is field 3, so field 22 is f[19]
				boot, _ := os.ReadFile("/proc/sys/kernel/random/boot_id")
				return "proc:" + strings.TrimSpace(string(boot)) + ":" + f[19] + ":" + sum
			}
		}
		return ""
	}
	if _, serr := os.Stat("/proc/self"); serr == nil {
		return "" // procfs exists but this process is not readable
	}
	out, err := exec.Command("ps", "-o", "lstart=", "-p", strconv.Itoa(pid)).Output()
	if err != nil || strings.TrimSpace(string(out)) == "" {
		return ""
	}
	return "ps:" + strings.Join(strings.Fields(string(out)), " ") + ":" + sum
}

// argvOf returns the arguments of pid; ok is false when the process does not
// exist or has no arguments (zombie / kernel thread).
func argvOf(pid int) ([]string, bool) {
	if err := syscall.Kill(pid, 0); err != nil && !errors.Is(err, syscall.EPERM) {
		return nil, false
	}
	if b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/cmdline"); err == nil {
		s := strings.TrimRight(string(b), "\x00")
		if s == "" {
			return nil, false
		}
		return strings.Split(s, "\x00"), true
	} else if _, serr := os.Stat("/proc/self"); serr == nil {
		return nil, false // procfs exists but this pid is not readable/present
	}
	// no procfs (macOS): ask ps for the arguments.
	out, err := exec.Command("ps", "-o", "args=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return nil, false
	}
	f := strings.Fields(string(out))
	return f, len(f) > 0
}
