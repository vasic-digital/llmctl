// Command fakebackends is a test-only stand-in for a llama-server and the encoder runtime. It is
// built into a temp directory by tests/test_gateway_endpoints.sh and never shipped. Behaviour is
// scripted by markers in the state text (the prompt carries it):
//
//	LOWMASS  option letters carry too little mass          -> gateway 422 readout_failed
//	KILLME   the connection is closed mid-request           -> gateway 502 backend_failed
//	SLOW     the engine answers after 2s                    -> used to saturate the slots (529)
//	TRUNC    (encoder) premise reported as truncated
//	MISSINGB the top list lacks the option letter B           -> flagged answer with an upper bound
//	CTXOVERFLOW the engine answers HTTP 400 exceed_context_size_error -> gateway 422 validation_failed
//
// GET /_hits (unauthenticated, test-only) answers how many completions / score calls reached the
// engine, so a test can prove a refusal happened BEFORE the engine was contacted.
//
// Both servers require `Authorization: Bearer <key>` (-key); otherwise 401.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"sync/atomic"
	"time"
)

var hits atomic.Int64

func hitsHandler(w http.ResponseWriter, _ *http.Request) { fmt.Fprintf(w, "%d", hits.Load()) }

func main() {
	key := flag.String("key", "", "required bearer key")
	portsFile := flag.String("ports-file", "", "write 'llama=PORT encoder=PORT' here once listening")
	llamaPort := flag.Int("llama-port", 0, "fixed llama port (0 = ephemeral); used by the download-smoke test")
	chatStatus := flag.Int("chat-status", 0, "answer /v1/chat/completions with this HTTP status (0 = a normal answer)")
	flag.Parse()
	failChat = *chatStatus

	llama := listenOn(*llamaPort)
	enc := listen()
	go serve(llama, llamaMux(*key))
	go serve(enc, encMux(*key))
	line := fmt.Sprintf("llama=%d encoder=%d\n", llama.Addr().(*net.TCPAddr).Port, enc.Addr().(*net.TCPAddr).Port)
	if *portsFile != "" {
		_ = os.WriteFile(*portsFile, []byte(line), 0o600)
	}
	select {}
}

// failChat, when non-zero, is the HTTP status every chat completion is answered with.
var failChat int

func listen() net.Listener { return listenOn(0) }

func listenOn(port int) net.Listener {
	l, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	return l
}

func serve(l net.Listener, h http.Handler) { _ = http.Serve(l, h) }

func authed(key string, w http.ResponseWriter, r *http.Request) bool {
	if key != "" && r.Header.Get("Authorization") != "Bearer "+key {
		w.WriteHeader(http.StatusUnauthorized)
		return false
	}
	return true
}

type entry struct {
	Token   string  `json:"token"`
	Logprob float64 `json:"logprob"`
}

func llamaMux(key string) http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) { _, _ = io.WriteString(w, `{"status":"ok"}`) })
	m.HandleFunc("/_hits", hitsHandler)
	m.HandleFunc("/v1/chat/completions", func(w http.ResponseWriter, r *http.Request) {
		if !authed(key, w, r) {
			return
		}
		hits.Add(1)
		if failChat != 0 {
			w.WriteHeader(failChat)
			return
		}
		var body struct {
			Messages []struct{ Content string } `json:"messages"`
		}
		b, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(b, &body)
		prompt := ""
		if len(body.Messages) > 0 {
			prompt = body.Messages[0].Content
		}
		switch {
		case strings.Contains(prompt, "CTXOVERFLOW"):
			w.WriteHeader(http.StatusBadRequest)
			_, _ = io.WriteString(w, `{"error":{"code":400,"message":"request (3030 tokens) exceeds the available context size (1024 tokens), try increasing it","type":"exceed_context_size_error","n_prompt_tokens":3030,"n_ctx":1024}}`)
			return
		case strings.Contains(prompt, "KILLME"):
			if hj, ok := w.(http.Hijacker); ok {
				c, _, _ := hj.Hijack()
				_ = c.Close()
			}
			return
		case strings.Contains(prompt, "SLOW"):
			time.Sleep(2 * time.Second)
		}
		top := []entry{{" the", -0.5}}
		if strings.Contains(prompt, "MISSINGB") {
			top = []entry{{" A", -0.3}, {"\n", -1.6}}
		} else if strings.Contains(prompt, "LOWMASS") {
			top = append(top, entry{" A", -1.6}, entry{" B", -1.7})
		} else {
			top = append(top, entry{" A", -0.1})
			for c := 'B'; c <= 'Z'; c++ {
				top = append(top, entry{" " + string(c), -3.0})
			}
		}
		out, _ := json.Marshal(map[string]any{"choices": []any{map[string]any{
			"message": map[string]any{"role": "assistant", "content": "A"}, "logprobs": map[string]any{"top_logprobs": []any{top}}}}})
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(out)
	})
	// POST /v1/systemone: the native decision endpoint (b11379 wire shape). Every choice question is
	// answered with its FIRST criteria key at 0.9 (the remaining mass split evenly); like the real engine
	// the response `model` echoes a local FILE PATH, which the gateway must never pass on.
	m.HandleFunc("/v1/systemone", func(w http.ResponseWriter, r *http.Request) {
		if !authed(key, w, r) {
			return
		}
		hits.Add(1)
		var body struct {
			Questions map[string]struct {
				Type     string          `json:"type"`
				Criteria json.RawMessage `json:"criteria"`
			} `json:"questions"`
		}
		b, _ := io.ReadAll(r.Body)
		if json.Unmarshal(b, &body) != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		answers := map[string]any{}
		for name, q := range body.Questions {
			if q.Type != "choice" {
				w.WriteHeader(http.StatusNotImplemented)
				return
			}
			// criteria is a JSON object: keep the key ORDER (a map would lose it)
			dec := json.NewDecoder(strings.NewReader(string(q.Criteria)))
			_, _ = dec.Token()
			var keys []string
			for dec.More() {
				kt, _ := dec.Token()
				keys = append(keys, kt.(string))
				var skip json.RawMessage
				_ = dec.Decode(&skip)
			}
			if len(keys) < 2 {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			probs := map[string]float64{}
			rest := 0.1 / float64(len(keys)-1)
			for i, k := range keys {
				if i == 0 {
					probs[k] = 0.9
				} else {
					probs[k] = rest
				}
			}
			answers[name] = map[string]any{"type": "choice", "choice": keys[0], "probabilities": probs, "confidence": 0.8}
		}
		out, _ := json.Marshal(map[string]any{"model": "/models/fake-native.gguf", "answers": answers,
			"usage": map[string]any{"input_tokens": 12, "output_tokens": 0}})
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(out)
	})
	return m
}

func encMux(key string) http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("/_hits", hitsHandler)
	m.HandleFunc("/v1/score", func(w http.ResponseWriter, r *http.Request) {
		if !authed(key, w, r) {
			return
		}
		hits.Add(1)
		var in struct {
			Pairs []struct{ Premise, Hypothesis string } `json:"pairs"`
		}
		b, _ := io.ReadAll(r.Body)
		if json.Unmarshal(b, &in) != nil || len(in.Pairs) == 0 {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		// the real runtime contract (contracts/encoder-runtime.md): labels in id2label order - here
		// deliberately PERMUTED so a client that assumes a column fails - and one full softmax row per
		// pair. Pair 0 entails strongly, the others weakly.
		labels := []string{"contradiction", "neutral", "entailment"}
		source := "config:onnx/config.json"
		rows := make([][]float64, len(in.Pairs))
		trunc := make([]bool, len(in.Pairs))
		for i, p := range in.Pairs {
			rows[i] = []float64{0.4, 0.3, 0.3}
			if i == 0 {
				rows[i] = []float64{0.1, 0.2, 0.7}
			}
			trunc[i] = strings.Contains(p.Premise, "TRUNC")
			if strings.Contains(p.Premise, "GENERICLABELS") { // a runtime whose id2label only holds LABEL_n
				labels, source = []string{"LABEL_0", "LABEL_1", "LABEL_2"}, "generic-config:onnx/config.json (LABEL_n names)"
			}
		}
		out, _ := json.Marshal(map[string]any{"labels": labels, "label_source": source, "scores": rows, "truncated": trunc, "model": "fake-nli", "max_tokens": 512})
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(out)
	})
	return m
}
