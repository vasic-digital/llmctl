// Command servetest starts the gateway with a throw-away CA, a generated access key and a
// deterministic uniform-probability backend, for the shell-level transport test
// (tests/test_tls_server.sh). It is test-only: it lives under internal/, writes only into -dir,
// and trusts nothing outside this process.
//
//	servetest -dir <empty dir>     writes <dir>/ca.pem and <dir>/key (0600), prints
//	                               "READY https://127.0.0.1:<port>" on stdout, then serves
//	                               until stdin closes or SIGINT/SIGTERM, then drains.
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
	"path/filepath"
	"syscall"
	"time"

	"github.com/vasic-digital/llmctl/internal/contract"
	"github.com/vasic-digital/llmctl/internal/keyring"
	"github.com/vasic-digital/llmctl/internal/server"
	"github.com/vasic-digital/llmctl/internal/server/internal/testpki"
)

type backend struct{}

func (backend) Ready() bool { return true }

func (backend) Models() []server.ModelInfo {
	return []server.ModelInfo{{ID: "decide-tiny", Aliases: []string{"jev-latest", "llmctl-decide-tiny"},
		Protocol: "letter-logit", Status: "ready", MaxOptions: 20, ScoreLevels: [2]int{2, 10}}}
}

func (backend) Decide(_ context.Context, r *contract.ParsedRequest) ([]contract.NamedAnswer, contract.Usage, error) {
	var out []contract.NamedAnswer
	for _, q := range r.Questions {
		p := make([]float64, len(q.Options))
		for i := range p {
			p[i] = 1 / float64(len(p))
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
	dir := flag.String("dir", "", "empty directory for ca.pem and key")
	flag.Parse()
	if *dir == "" {
		fmt.Fprintln(os.Stderr, "servetest: -dir is required")
		os.Exit(2)
	}
	if err := run(*dir); err != nil {
		fmt.Fprintln(os.Stderr, "servetest:", err)
		os.Exit(1)
	}
}

func run(dir string) error {
	pki, err := testpki.New(testpki.Options{})
	if err != nil {
		return err
	}
	key := keyring.GenerateKey()
	if err := os.WriteFile(filepath.Join(dir, "ca.pem"), pki.CAPEM, 0o644); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, "key"), []byte(key.Reveal()), 0o600); err != nil {
		return err
	}
	profiles, err := contract.NewProfiles([]string{"decide-tiny"}, "", nil)
	if err != nil {
		return err
	}
	srv, err := server.New(server.Config{
		Backend:  backend{},
		TLS:      &tls.Config{Certificates: []tls.Certificate{pki.Cert}},
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
