// Command clienttest runs a REAL gateway (internal/server) for the shell-level client test
// (tests/test_decide_cli.sh). It is test-only: it lives under internal/, writes only below
// -home and -envfile, and trusts nothing outside this process.
//
// The certificate material comes from the production code path (internal/certs.Ensure into
// <home>/cert, so the client finds the CA at its default location $LLMCTL_HOME/cert/ca/ca.crt),
// the access key is written to the -envfile exactly as the gateway would (mode 0600).
//
//	clienttest -home H -envfile F [-mode uniform|slow:MS|readout|notready] [-maxbody N]
//
// It prints "READY https://127.0.0.1:<port>" on stdout, then serves until stdin closes or
// SIGINT/SIGTERM, then drains.
package main

import (
	"context"
	"crypto/tls"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/vasic-digital/llmctl/internal/certs"
	"github.com/vasic-digital/llmctl/internal/contract"
	"github.com/vasic-digital/llmctl/internal/keyring"
	"github.com/vasic-digital/llmctl/internal/server"
)

type backend struct {
	mode  string
	delay time.Duration
}

func (b backend) Ready() bool { return b.mode != "notready" }

func (backend) Models() []server.ModelInfo {
	return []server.ModelInfo{{ID: "decide-tiny", Aliases: []string{"jev-latest", "llmctl-decide-tiny"},
		Protocol: "letter-logit", Status: "ready", MaxOptions: 20, ScoreLevels: [2]int{2, 10}}}
}

func (b backend) Decide(ctx context.Context, r *contract.ParsedRequest) ([]contract.NamedAnswer, contract.Usage, error) {
	switch b.mode {
	case "readout":
		return nil, contract.Usage{}, contract.ReadoutFailedError()
	case "notready":
		ra := 0
		ce, err := contract.TransportError(503, contract.TransportOptions{RetryAfter: &ra})
		if err != nil {
			return nil, contract.Usage{}, err
		}
		return nil, contract.Usage{}, ce
	}
	if b.delay > 0 {
		select {
		case <-time.After(b.delay):
		case <-ctx.Done():
			return nil, contract.Usage{}, ctx.Err()
		}
	}
	var out []contract.NamedAnswer
	for _, q := range r.Questions {
		p := make([]float64, len(q.Options))
		for i := range p {
			p[i] = 1 / float64(len(p))
		}
		if len(p) > 1 && q.Type != contract.TypeNoul { // a mildly peaked, deterministic answer
			p[0] += 0.2
			p[1] -= 0.2
		}
		a, err := contract.BuildAnswer(q, p)
		if err != nil {
			return nil, contract.Usage{}, err
		}
		out = append(out, contract.NamedAnswer{Name: q.Name, Answer: a})
	}
	return out, contract.Usage{InputTokens: 4, OutputTokens: 1}, nil
}

func main() {
	home := flag.String("home", "", "LLMCTL_HOME for the throw-away CA (must exist)")
	envfile := flag.String("envfile", "", "path of the .env file that receives LLMCTL_API_KEY")
	mode := flag.String("mode", "uniform", "uniform | slow:MS | readout | notready")
	maxBody := flag.Int64("maxbody", 32<<20, "request body cap in bytes")
	flag.Parse()
	if *home == "" || *envfile == "" {
		fmt.Fprintln(os.Stderr, "clienttest: -home and -envfile are required")
		os.Exit(2)
	}
	if err := run(*home, *envfile, *mode, *maxBody); err != nil {
		fmt.Fprintln(os.Stderr, "clienttest:", err)
		os.Exit(1)
	}
}

func run(home, envfile, mode string, maxBody int64) error {
	be := backend{mode: mode}
	if ms, ok := strings.CutPrefix(mode, "slow:"); ok {
		n, err := strconv.Atoi(ms)
		if err != nil || n < 0 {
			return fmt.Errorf("bad slow delay %q", ms)
		}
		be = backend{mode: "slow", delay: time.Duration(n) * time.Millisecond}
	}
	info, err := certs.Ensure(certs.Options{Home: home, Hostnames: []string{"localhost"}, Addresses: []string{"127.0.0.1", "::1"}, Env: map[string]string{}})
	if err != nil {
		return err
	}
	chain := info.Chain
	if chain == "" {
		chain = info.LeafCert
	}
	pair, err := tls.LoadX509KeyPair(chain, info.LeafKey)
	if err != nil {
		return err
	}
	key := keyring.GenerateKey()
	if err := keyring.WriteEnvValues(envfile, map[string]string{keyring.KeyVar: key.Reveal()}, nil); err != nil {
		return err
	}
	profiles, err := contract.NewProfiles([]string{"decide-tiny"}, "", nil)
	if err != nil {
		return err
	}
	lim := server.DefaultLimits()
	lim.MaxBody = maxBody
	lim.Timeout = 60 * time.Second
	lim.ReadDeadline = 60 * time.Second
	cl := contract.DefaultLimits()
	cl.MaxStateChars = int(maxBody)
	srv, err := server.New(server.Config{
		Backend: be, Limits: lim, ContractLimits: cl,
		TLS:      &tls.Config{Certificates: []tls.Certificate{pair}},
		Keys:     func() []keyring.Secret { return []keyring.Secret{key} },
		Profiles: profiles,
	})
	if err != nil {
		return err
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	served := make(chan error, 1)
	go func() { served <- srv.Serve(ln) }()
	fmt.Printf("READY https://%s\n", ln.Addr())

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	eof := make(chan struct{})
	go func() { _, _ = io.Copy(io.Discard, os.Stdin); close(eof) }()
	select {
	case <-stop:
	case <-eof:
	case err := <-served:
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return srv.Drain(ctx)
}
