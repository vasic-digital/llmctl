//go:build linux

package gateway

import (
	"fmt"
	"os"
	"syscall"

	"golang.org/x/sys/unix"
)

// procCmdline is the NUL-separated argv of pid (replaceable only inside this package's tests).
var procCmdline = func(pid int) ([]byte, error) { return os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid)) }

// pidfdOpen pins pid with a process descriptor (Linux 5.3+). The syscall numbers come from
// golang.org/x/sys/unix, which has them right for every architecture (review A2-07).
func pidfdOpen(pid int) (int, error) {
	return unix.PidfdOpen(pid, 0)
}

// pidfdSendSignal delivers s through the descriptor, so a recycled pid can never receive it.
func pidfdSendSignal(fd int, s syscall.Signal) error {
	return unix.PidfdSendSignal(fd, s, nil, 0)
}
