package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"time"

	"github.com/vasic-digital/llmctl/internal/gateway"
)

func init() { register("smoke", cmdSmoke) }

// cmdSmoke implements `llmctl-decide smoke --url URL [--key-file F] --protocol P [--options N]
// [--expect-choice KEY] [--json]`: one deterministic choice question through the production driver
// of the protocol, against ONE engine (used by `llmctl download` to prove a fresh decision model
// answers). Exit codes: 0 valid typed answer, 1 backend failure, 2 usage, 6 engine unreachable.
func cmdSmoke(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("smoke", flag.ContinueOnError)
	fs.SetOutput(stderr)
	url := fs.String("url", "", "loopback engine base URL")
	keyFile := fs.String("key-file", "", "0600 file holding the engine key (omit for an unauthenticated engine)")
	proto := fs.String("protocol", "", "letter-logit | nli-onnx | systemone-native")
	opts := fs.Int("options", 2, "number of options (2..26)")
	expect := fs.String("expect-choice", "", "the option key the answer must pick (model sanity)")
	asJSON := fs.Bool("json", false, "print the answer as JSON")
	timeout := fs.Duration("timeout", 30*time.Second, "overall deadline")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 0 || *url == "" || *proto == "" {
		fmt.Fprintln(stderr, "usage: llmctl-decide smoke --url URL --protocol letter-logit|nli-onnx|systemone-native [--key-file F] [--options N] [--expect-choice KEY] [--json]")
		return 2
	}
	key := ""
	if *keyFile != "" {
		k, err := gateway.ReadKeyFile(*keyFile)
		if err != nil {
			fmt.Fprintf(stderr, "llmctl-decide smoke: %v\n", err)
			return 2
		}
		key = k
	}
	res, err := gateway.Smoke(context.Background(), gateway.SmokeConfig{
		URL: *url, Key: key, Protocol: *proto, Options: *opts, ExpectChoice: *expect, Timeout: *timeout,
	})
	switch {
	case errors.Is(err, gateway.ErrSmokeUsage):
		fmt.Fprintf(stderr, "llmctl-decide smoke: %v\n", err)
		return 2
	case errors.Is(err, gateway.ErrSmokeUnreachable):
		fmt.Fprintf(stderr, "llmctl-decide smoke: %v\n", err)
		return 6
	case err != nil:
		fmt.Fprintf(stderr, "llmctl-decide smoke: %v\n", err)
		return 1
	}
	if *asJSON {
		// probabilities are emitted in option order, hand-built to keep that order.
		var pb []byte
		pb = append(pb, '{')
		for i, p := range res.Probabilities {
			if i > 0 {
				pb = append(pb, ',')
			}
			k, _ := json.Marshal(p.Key)
			v, _ := json.Marshal(p.Value)
			pb = append(pb, k...)
			pb = append(pb, ':')
			pb = append(pb, v...)
		}
		pb = append(pb, '}')
		head, _ := json.Marshal(res)
		fmt.Fprintf(stdout, "%s,\"probabilities\":%s}\n", head[:len(head)-1], pb)
		return 0
	}
	fmt.Fprintf(stdout, "smoke ok: protocol=%s choice=%s confidence=%.4f\n", res.Protocol, res.Choice, res.Confidence)
	for _, p := range res.Probabilities {
		fmt.Fprintf(stdout, "  %s=%.6f\n", p.Key, p.Value)
	}
	return 0
}
