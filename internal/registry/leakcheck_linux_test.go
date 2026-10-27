//go:build linux

package registry

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"syscall"
)

// Leak detector for the test run itself (3.3.1 test hygiene). TestMain stamps the
// whole run with a unique marker in the environment; every child, grandchild and
// re-parented orphan inherits it, so a process that is still alive after m.Run()
// and carries the marker is a leak of THIS run, identified from the process's own
// /proc/<pid>/environ (never by name, never by process group). Only processes of
// the current uid are looked at.

const leakMarkerEnv = "LLMCTL_REGISTRY_TEST_RUN"

type leaked struct {
	pid int
	cmd string
}

// leakedProcs lists live processes of this uid, other than the caller, whose
// environment carries marker=<value>. Zombies are not leaks (nothing runs).
func leakedProcs(value string) []leaked {
	want := leakMarkerEnv + "=" + value
	me := os.Getpid()
	ents, err := os.ReadDir("/proc")
	if err != nil {
		return nil
	}
	var out []leaked
	for _, e := range ents {
		pid, err := strconv.Atoi(e.Name())
		if err != nil || pid <= 1 || pid == me {
			continue
		}
		p := "/proc/" + e.Name()
		fi, err := os.Stat(p)
		if err != nil {
			continue
		}
		if st, ok := fi.Sys().(*syscall.Stat_t); !ok || int(st.Uid) != os.Getuid() {
			continue
		}
		env, err := os.ReadFile(p + "/environ")
		if err != nil || !hasEnvEntry(env, want) {
			continue
		}
		stat, err := os.ReadFile(p + "/stat")
		if err != nil {
			continue
		}
		if i := strings.LastIndexByte(string(stat), ')'); i >= 0 && strings.HasPrefix(strings.TrimSpace(string(stat)[i+1:]), "Z") {
			continue
		}
		cmd, _ := os.ReadFile(p + "/cmdline")
		out = append(out, leaked{pid, strings.TrimSpace(strings.ReplaceAll(string(cmd), "\x00", " "))})
	}
	return out
}

func hasEnvEntry(env []byte, want string) bool {
	for _, kv := range strings.Split(string(env), "\x00") {
		if kv == want {
			return true
		}
	}
	return false
}

// reportAndReapLeaks fails the run (returns true) when anything survived, and
// kills the survivors so repeated runs do not accumulate them. pid > 1 is
// guaranteed by leakedProcs; each kill targets one pid, never a group.
func reportAndReapLeaks(value string) bool {
	left := leakedProcs(value)
	for _, l := range left {
		fmt.Fprintf(os.Stderr, "LEAK: test run left pid %d running: %s\n", l.pid, l.cmd)
		_ = syscall.Kill(l.pid, syscall.SIGKILL)
	}
	return len(left) > 0
}
