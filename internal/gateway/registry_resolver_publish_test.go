package gateway

import (
	"net"
	"os"
	"os/exec"
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/internal/registry"
)

func TestGatewayEntryShapes(t *testing.T) {
	w := GatewayEntry("0.0.0.0", 8095, 4242, "llmctl-decide")
	if w.Host != "127.0.0.1" || w.LoopbackOnly || w.Protocol != "https" || w.Labels[registry.LabelKind] != KindGateway || w.HealthPath != "/healthz" || w.Port != 8095 {
		t.Fatalf("wildcard bind: %+v", w)
	}
	if e := GatewayEntry("", 8095, 4242, "x"); e.Host != "127.0.0.1" || e.LoopbackOnly {
		t.Fatalf("empty bind is a wildcard: %+v", e)
	}
	l := GatewayEntry("127.0.0.1", 8095, 4242, "x")
	if l.Host != "127.0.0.1" || !l.LoopbackOnly {
		t.Fatalf("loopback bind: %+v", l)
	}
	if e := GatewayEntry("192.168.1.115", 8095, 4242, "x"); e.Host != "192.168.1.115" || e.LoopbackOnly {
		t.Fatalf("specific address: %+v", e)
	}
}

func TestPublishGatewayRegistersAtReadyAndUnregistersOnDrain(t *testing.T) {
	reg := newReg(t)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	port := ln.Addr().(*net.TCPAddr).Port
	unpublish, err := PublishGateway(reg, "0.0.0.0", port, selfToken())
	must(t, err)
	got, ok, err := reg.Get(GatewayEntryName)
	if err != nil || !ok || got.PID != os.Getpid() || got.Port != port || got.Labels[registry.LabelKind] != KindGateway {
		t.Fatalf("not published: %+v %v %v", got, ok, err)
	}
	// it is discoverable by kind
	if es, _ := reg.Resolve(map[string]string{registry.LabelKind: KindGateway}); len(es) != 1 {
		t.Fatalf("resolve by kind: %+v", es)
	}
	unpublish()
	if _, ok, _ := reg.Get(GatewayEntryName); ok {
		t.Fatal("still registered after drain")
	}
	unpublish() // idempotent
}

func TestUnpublishDoesNotEvictASuccessor(t *testing.T) {
	reg := newReg(t)
	unpublish, err := PublishGateway(reg, "127.0.0.1", 18095, selfToken())
	must(t, err)
	// a successor process took the name over (different pid). Register proves that the pid really runs
	// the named program, so the successor is a real helper whose command line carries the token (the
	// shell's $0 argument), not an arbitrary process such as this test's parent.
	succ := exec.Command("sh", "-c", "sleep 60; :", "successor") // the trailing ':' keeps the shell (a bash-as-sh would otherwise exec sleep and drop the marker from argv)
	must(t, succ.Start())
	defer func() { _ = succ.Process.Kill(); _, _ = succ.Process.Wait() }()
	// right after Start the child may still show its parent's command line; wait until the exec
	// has happened (the same wait the shell side does), bounded
	var regErr error
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
		regErr = reg.Register(registry.Entry{Name: GatewayEntryName, Host: "127.0.0.1", Port: 18095, Protocol: "https", PID: succ.Process.Pid, CmdToken: "successor"})
		if regErr == nil {
			break
		}
	}
	must(t, regErr)
	unpublish()
	if cur, ok, _ := reg.Get(GatewayEntryName); !ok || cur.PID != succ.Process.Pid {
		t.Fatalf("the successor's entry was evicted: %+v %v", cur, ok)
	}
}
