//go:build !linux

package gateway

import (
	"errors"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
)

// procCmdline approximates /proc/<pid>/cmdline with `ps -o args= -p <pid>` (macOS and the BSDs have no
// procfs). ps joins argv with single spaces, so the result is split on whitespace: an executable path
// that contains a space cannot be told apart and is therefore NOT recognised as the gateway - the safe
// direction, the stop path then refuses instead of signalling.
var procCmdline = func(pid int) ([]byte, error) {
	out, err := exec.Command("ps", "-o", "args=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return nil, err
	}
	f := strings.Fields(string(out))
	if len(f) == 0 {
		return nil, errors.New("gateway: ps returned no command line")
	}
	return []byte(strings.Join(f, "\x00")), nil
}

// There is no pidfd off Linux. Both wrappers refuse with ENOSYS and issue no syscall of their own:
// StopGateway then re-verifies the process immediately before kill(2) (review A2-07, B2-07).
func pidfdOpen(int) (int, error) { return -1, syscall.ENOSYS }

func pidfdSendSignal(int, syscall.Signal) error { return syscall.ENOSYS }
