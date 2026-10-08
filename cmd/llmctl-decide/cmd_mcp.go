package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"

	"github.com/vasic-digital/llmctl/internal/client"
	"github.com/vasic-digital/llmctl/internal/mcpserver"
)

// `llmctl-decide mcp` is the minimal local MCP server (stdio, one tool `decide`; FR-086). It reads
// the same endpoint / CA / key as `ask`. A configuration problem (no key, bad CA) does NOT stop the
// server: every call then returns a tool error that says why, so an agent can never read a failure
// as an answer (fail closed).
func init() {
	register("mcp", func(a []string, o, e io.Writer) int { return runMCP(a, o, e) })
}

// Test seam (never reachable from the command line).
var mcpStdin io.Reader = os.Stdin

// failedAsker answers every call with the configuration error found at start-up.
type failedAsker struct{ err error }

func (f failedAsker) Ask(context.Context, []byte) (*client.Result, error) { return nil, f.err }

func runMCP(args []string, stdout, stderr io.Writer) int {
	var c askCommon
	fs := askNewFlagSet("mcp")
	c.register(fs, false)
	if rc, ok := fs.parse(args, stderr); !ok {
		return rc
	}
	ce, err := askLoadEnv(askEnviron())
	if err != nil {
		fmt.Fprintf(stderr, "llmctl-decide mcp: %v\n", err)
		return 2
	}
	var asker mcpserver.Asker
	var errBuf = &limitedBuf{}
	cl, rc := askNewClient(ce, &c, errBuf, "mcp")
	if cl == nil {
		msg := errBuf.String()
		fmt.Fprint(stderr, msg)
		asker = failedAsker{err: &client.Error{Kind: client.Kind(rc), Msg: "the decision gateway client is not configured: " + trimLine(msg)}}
	} else {
		asker = cl
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	srv := &mcpserver.Server{Asker: asker, Version: "3.1"}
	if err := srv.Serve(ctx, mcpStdin, stdout); err != nil && ctx.Err() == nil {
		fmt.Fprintf(stderr, "llmctl-decide mcp: %v\n", err)
		return 1
	}
	return 0
}

// limitedBuf captures a short stderr message from askNewClient.
type limitedBuf struct{ b []byte }

func (l *limitedBuf) Write(p []byte) (int, error) {
	if len(l.b) < 2048 {
		l.b = append(l.b, p...)
	}
	return len(p), nil
}
func (l *limitedBuf) String() string { return string(l.b) }

func trimLine(s string) string {
	for len(s) > 0 && (s[len(s)-1] == '\n' || s[len(s)-1] == '\r') {
		s = s[:len(s)-1]
	}
	return s
}
