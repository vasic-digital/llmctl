//go:build !linux

package gateway

import (
	"errors"
	"syscall"
	"testing"
)

// Off Linux there is no pidfd: the wrappers refuse (ENOSYS) and never issue a raw syscall, so the
// stop path verifies the process (ps) and signals with kill(2) only.
func TestPidfdIsUnavailableOffLinux(t *testing.T) {
	if _, err := pidfdOpen(1234); !errors.Is(err, syscall.ENOSYS) {
		t.Fatalf("pidfdOpen = %v, want ENOSYS", err)
	}
	if err := pidfdSendSignal(3, syscall.SIGTERM); !errors.Is(err, syscall.ENOSYS) {
		t.Fatalf("pidfdSendSignal = %v, want ENOSYS", err)
	}
}
