//go:build linux

package gateway

import (
	"os"
	"syscall"
	"testing"
)

// The pidfd wrappers work on this kernel: open our own pid, deliver signal 0 through the descriptor.
func TestPidfdRoundTripOnLinux(t *testing.T) {
	fd, err := pidfdOpen(os.Getpid())
	if err != nil {
		t.Skipf("pidfd_open unavailable here (%v); the stop path falls back to re-verification", err)
	}
	defer syscall.Close(fd)
	if err := pidfdSendSignal(fd, 0); err != nil {
		t.Fatalf("pidfd_send_signal(0): %v", err)
	}
	// a pid that cannot exist is refused
	if _, err := pidfdOpen(1 << 30); err == nil {
		t.Fatal("pidfd_open of a non-existent pid must fail")
	}
}
