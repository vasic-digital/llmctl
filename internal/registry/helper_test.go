package registry

import (
	"bufio"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// TestMain re-executes the test binary as a tiny listener / allocator / registrar
// process when its first argument is "__helper", so the integration tests run
// REAL processes with REAL argv (the liveness proof reads /proc/<pid>/cmdline).
func TestMain(m *testing.M) {
	if len(os.Args) > 1 && os.Args[1] == "__helper" {
		helperMain(os.Args[2:])
		return
	}
	os.Exit(m.Run())
}

func helperMain(a []string) {
	switch a[0] {
	case "listen": // listen PORT TOKEN [sick]
		port, _ := strconv.Atoi(a[1])
		ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err != nil {
			fmt.Println("error", err)
			os.Exit(3)
		}
		mux := http.NewServeMux()
		sick := len(a) > 3 && a[3] == "sick"
		mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
			if sick {
				w.WriteHeader(500)
				return
			}
			w.WriteHeader(200)
		})
		fmt.Println("ready")
		_ = http.Serve(ln, mux)
	case "hold": // hold TOKEN : no socket, just a process with that argv
		fmt.Println("ready")
		time.Sleep(10 * time.Minute)
	case "alloc": // alloc STATEDIR NAME GOFILE LO HI
		lo, _ := strconv.Atoi(a[4])
		hi, _ := strconv.Atoi(a[5])
		for {
			if _, err := os.Stat(a[3]); err == nil {
				break
			}
			time.Sleep(time.Millisecond)
		}
		res, err := NewPorts(Config{StateDir: a[1], Strategy: Dynamic, RangeLo: lo, RangeHi: hi}, func(string) string { return "" }).
			Allocate(PortRequest{Name: a[2]})
		if err != nil {
			fmt.Println("error", err)
			os.Exit(1)
		}
		fmt.Println(res.Port)
	case "register": // register STATEDIR NAME PORT GOFILE
		port, _ := strconv.Atoi(a[3])
		for {
			if _, err := os.Stat(a[4]); err == nil {
				break
			}
			time.Sleep(time.Millisecond)
		}
		r := New(Config{StateDir: a[1]})
		err := r.Register(Entry{Name: a[2], Port: port, Protocol: "http", PID: os.Getpid(), CmdToken: "__helper"})
		if err != nil {
			fmt.Println("error", err)
			os.Exit(1)
		}
		fmt.Println("ok")
	}
}

// proc is a spawned helper process.
type proc struct {
	cmd   *exec.Cmd
	token string
	done  chan struct{}
}

func spawn(t *testing.T, args ...string) *proc {
	t.Helper()
	cmd := exec.Command(os.Args[0], append([]string{"__helper"}, args...)...)
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	p := &proc{cmd: cmd, done: make(chan struct{})}
	go func() { _ = cmd.Wait(); close(p.done) }()
	line := make(chan string, 1)
	go func() {
		s, _ := bufio.NewReader(out).ReadString('\n')
		line <- strings.TrimSpace(s)
	}()
	select {
	case l := <-line:
		if l != "ready" {
			t.Fatalf("helper %v said %q", args, l)
		}
	case <-time.After(10 * time.Second):
		t.Fatalf("helper %v never became ready", args)
	}
	t.Cleanup(p.kill)
	return p
}

func (p *proc) pid() int { return p.cmd.Process.Pid }

func (p *proc) kill() {
	_ = syscall.Kill(p.pid(), syscall.SIGKILL)
	select {
	case <-p.done:
	case <-time.After(5 * time.Second):
	}
}

func (p *proc) alive() bool {
	select {
	case <-p.done:
		return false
	default:
		return true
	}
}

// freePort asks the OS for a currently-free loopback port.
func freePort(t *testing.T) int {
	t.Helper()
	// The kernel's pick is free on 127.0.0.1 only; the allocator under test also binds the wildcards and every local
	// interface address (see blockIsFree), so retry until the port passes that same production test.
	for i := 0; i < 50; i++ {
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		port := ln.Addr().(*net.TCPAddr).Port
		ln.Close()
		if bindTest(port) == nil {
			return port
		}
	}
	t.Fatal("no port passed the production bind test in 50 tries")
	return 0
}

func listener(t *testing.T, port int) net.Listener {
	t.Helper()
	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	return ln
}

func noEnv(string) string { return "" }

func envOf(m map[string]string) func(string) string { return func(k string) string { return m[k] } }

// testCfg is a dynamic-capable config on a private state dir and a private range.
func testCfg(t *testing.T) Config {
	t.Helper()
	return Config{StateDir: t.TempDir(), Strategy: Fixed, RangeLo: 34000, RangeHi: 34499}
}
