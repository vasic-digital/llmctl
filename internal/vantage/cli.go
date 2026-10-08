package vantage

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"strings"
	"time"

	"digital.vasic.containers/pkg/runtime"

	"github.com/vasic-digital/llmctl/internal/vantage/probecore"
)

// Exit codes of `llmctl-decide vantage`.
const (
	ExitOK          = 0
	ExitFailure     = 1
	ExitUsage       = 2
	ExitUnavailable = 3 // rootless containers cannot run here; the reason is on stderr
)

const usage = `usage: llmctl-decide vantage <command> [flags]

The second network location of FR-064/FR-069/FR-073: a tiny rootless container
(booted through the Containers submodule) with its own address.

commands:
  up [--network slirp4netns|bridge] [--image IMG] [--probe-bin FILE] [--host-ip IP]
                  boot the vantage and print its JSON state (idempotent)
  status          print the JSON state and whether it is running
  exec -- ARGV... run ARGV inside the container (container exit code is returned)
  probe --url URL [--cacert FILE] [--method M] [--header Name:Value]... [--body S]
        [--timeout D] [--server-name N] [--expect-status N] [--expect-tls-failure]
                  one HTTP(S) call FROM the vantage; JSON result on stdout;
                  exit 0 when the expectation holds (default: completed with a
                  verified TLS handshake), 1 otherwise
  probe-ports --host-ip IP --ports a,b,c
                  which ports are reachable from inside (JSON); exit 0
  selfcheck       prove the container source address differs from the host loopback
                  (also: vantage --selfcheck)
  down [--all]    remove THIS state dir's container and state; idempotent. Only containers
                  carrying this state dir's owner label are touched; --all also removes every
                  other llmctl vantage container on the host (recovery after a lost state dir)

common flags: --state-dir DIR (default $LLMCTL_STATE_DIR)
exit codes: 0 ok, 1 failure, 2 usage, 3 rootless containers unavailable (see stderr)`

// Run executes the subcommand. rt may be nil, in which case the Podman runtime
// of the Containers submodule is used.
func Run(args []string, getenv func(string) string, rt runtime.ContainerRuntime, stdout, stderr io.Writer) int {
	if len(args) == 0 || args[0] == "-h" || args[0] == "--help" {
		fmt.Fprintln(stderr, usage)
		return ExitUsage
	}
	cmd, rest := args[0], args[1:]
	if cmd == "--selfcheck" {
		cmd = "selfcheck"
	}
	fs := flag.NewFlagSet("vantage "+cmd, flag.ContinueOnError)
	fs.SetOutput(stderr)
	stateDir := fs.String("state-dir", getenv("LLMCTL_STATE_DIR"), "state directory")
	network := fs.String("network", NetSlirp, "slirp4netns|bridge")
	image := fs.String("image", "", "local image (default: first available candidate)")
	probeBin := fs.String("probe-bin", "", "static vantage-probe binary")
	hostIP := fs.String("host-ip", "", "host address (default: detected)")
	memory := fs.String("memory", "64m", "container memory limit")
	url := fs.String("url", "", "")
	cacert := fs.String("cacert", "", "")
	method := fs.String("method", "", "")
	body := fs.String("body", "", "")
	timeout := fs.Duration("timeout", 0, "")
	serverName := fs.String("server-name", "", "")
	expectStatus := fs.Int("expect-status", 0, "")
	expectTLSFail := fs.Bool("expect-tls-failure", false, "")
	ports := fs.String("ports", "", "")
	downAll := fs.Bool("all", false, "down: also remove other state dirs' vantage containers")
	var headers headerList
	fs.Var(&headers, "header", "")

	// `exec` takes everything after `--` as argv.
	var execArgv []string
	if cmd == "exec" {
		for i, a := range rest {
			if a == "--" {
				rest, execArgv = rest[:i], rest[i+1:]
				break
			}
		}
	}
	if err := fs.Parse(rest); err != nil {
		return ExitUsage
	}
	if cmd == "exec" && len(execArgv) == 0 {
		execArgv = fs.Args()
	}
	if *stateDir == "" {
		fmt.Fprintln(stderr, "vantage: --state-dir or LLMCTL_STATE_DIR is required")
		return ExitUsage
	}
	if rt == nil {
		rt = runtime.NewPodmanRuntime()
	}
	opts := Options{Runtime: rt, StateDir: *stateDir, Network: *network, ProbeBin: *probeBin, HostIP: *hostIP, Memory: *memory}
	if *image != "" {
		opts.Images = []string{*image}
	}
	m := New(opts)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	enc := func(v any) { _ = json.NewEncoder(stdout).Encode(v) }

	switch cmd {
	case "up":
		st, err := m.Up(ctx)
		if err != nil {
			fmt.Fprintln(stderr, "vantage up:", err)
			if errors.Is(err, ErrUnavailable) {
				return ExitUnavailable
			}
			return ExitFailure
		}
		enc(st)
	case "status":
		s, err := m.Status(ctx)
		if err != nil {
			fmt.Fprintln(stderr, "vantage status:", err)
			return ExitFailure
		}
		enc(s)
	case "down":
		down := m.Down
		if *downAll {
			down = m.DownAll
		}
		if err := down(ctx); err != nil {
			fmt.Fprintln(stderr, "vantage down:", err)
			return ExitFailure
		}
		enc(map[string]any{"down": true})
	case "exec":
		if len(execArgv) == 0 {
			fmt.Fprintln(stderr, "vantage exec: argv required after --")
			return ExitUsage
		}
		r, err := m.Exec(ctx, execArgv)
		if err != nil {
			fmt.Fprintln(stderr, "vantage exec:", err)
			return ExitFailure
		}
		fmt.Fprint(stdout, r.Stdout)
		fmt.Fprint(stderr, r.Stderr)
		return r.ExitCode
	case "probe":
		if *url == "" {
			fmt.Fprintln(stderr, "vantage probe: --url is required")
			return ExitUsage
		}
		res, err := m.Probe(ctx, ProbeRequest{URL: *url, CAFile: *cacert, Method: *method, Headers: headers, Body: *body, Timeout: *timeout, ServerName: *serverName})
		if err != nil {
			fmt.Fprintln(stderr, "vantage probe:", err)
			return ExitFailure
		}
		enc(res)
		if !ProbeMeets(res, *expectStatus, *expectTLSFail) {
			return ExitFailure
		}
	case "probe-ports":
		ps, err := probecore.ParsePorts(*ports)
		if err != nil || *hostIP == "" {
			fmt.Fprintln(stderr, "vantage probe-ports: --host-ip IP and --ports a,b,c are required")
			return ExitUsage
		}
		res, err := m.ProbePorts(ctx, *hostIP, ps)
		if err != nil {
			fmt.Fprintln(stderr, "vantage probe-ports:", err)
			return ExitFailure
		}
		enc(res)
	case "selfcheck":
		res, err := m.SelfCheck(ctx)
		if err != nil {
			fmt.Fprintln(stderr, "vantage selfcheck:", err)
			if len(res.Checks) > 0 {
				enc(res)
			}
			return ExitFailure
		}
		enc(res)
		if !res.OK {
			return ExitFailure
		}
	default:
		fmt.Fprintf(stderr, "vantage: unknown command %q\n%s\n", cmd, usage)
		return ExitUsage
	}
	return ExitOK
}

// ProbeMeets decides the exit code of `probe`.
func ProbeMeets(r probecore.HTTPResult, expectStatus int, expectTLSFailure bool) bool {
	if expectTLSFailure {
		return r.TLS && !r.TLSVerified && r.Status == 0 && r.ErrorClass == "tls_verify"
	}
	if r.Error != "" {
		return false
	}
	if r.TLS && !r.TLSVerified {
		return false
	}
	return expectStatus == 0 || r.Status == expectStatus
}

type headerList []string

func (h *headerList) String() string     { return strings.Join(*h, ",") }
func (h *headerList) Set(v string) error { *h = append(*h, v); return nil }
