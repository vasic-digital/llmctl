package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/vasic-digital/llmctl/internal/client"
	"github.com/vasic-digital/llmctl/internal/contract"
	"github.com/vasic-digital/llmctl/internal/keyring"
	"github.com/vasic-digital/llmctl/internal/registry"
)

// `llmctl-decide ask | batch | models` are llmctl's own HTTPS client of the gateway
// (contracts/cli.md, FR-057..FR-063, FR-068, FR-081). Exit codes: 0 ok, 1 backend/readout,
// 2 usage, 4 key, 5 certificate/TLS, 6 not ready/unreachable, 10 abstained.
func init() {
	register("ask", func(a []string, o, e io.Writer) int { return runAsk(a, o, e) })
	register("batch", func(a []string, o, e io.Writer) int { return runBatch(a, o, e) })
	register("models", func(a []string, o, e io.Writer) int { return runModels(a, o, e) })
}

// Test seams (never reachable from the command line).
var (
	askStdin   io.Reader = os.Stdin
	askEnviron           = func() keyring.Environ { return keyring.OSEnviron() }
)

// askClientEnv is the validated environment of the client commands.
type askClientEnv struct {
	env      keyring.Environ
	port     string
	timeout  time.Duration
	limits   contract.Limits
	endpoint string
	cacert   string
}

func askEnvInt(env keyring.Environ, name string, lo, hi int) (int, bool, error) {
	v, ok := env[name]
	if !ok || strings.TrimSpace(v) == "" {
		return 0, false, nil
	}
	n, err := strconv.Atoi(strings.TrimSpace(v))
	if err != nil || n < lo || n > hi {
		return 0, false, fmt.Errorf("%s=%q is not a whole number between %d and %d", name, askShorten(v), lo, hi)
	}
	return n, true, nil
}

func askShorten(s string) string {
	if len(s) > 24 {
		return s[:24] + "..."
	}
	return s
}

// askLoadEnv validates every numeric variable the client reads, up front, so a bad value is a
// clear usage error (exit 2) and never a raw failure later (N-16).
func askLoadEnv(env keyring.Environ) (*askClientEnv, error) {
	ce := &askClientEnv{env: env, port: "8095", timeout: client.DefaultTimeout, limits: contract.DefaultLimits()}
	if n, ok, err := askEnvInt(env, "LLMCTL_DECIDE_PORT", 1, 65535); err != nil {
		return nil, err
	} else if ok {
		ce.port = strconv.Itoa(n)
	}
	if n, ok, err := askEnvInt(env, "LLMCTL_DECIDE_TIMEOUT", 1, 86400); err != nil {
		return nil, err
	} else if ok {
		// the gateway's own end-to-end budget plus a grace, so its error answer wins the race
		ce.timeout = time.Duration(n)*time.Second + 5*time.Second
	}
	if n, ok, err := askEnvInt(env, "LLMCTL_DECIDE_MAX_OPTIONS", 2, contract.HostedMaxOptions); err != nil {
		return nil, err
	} else if ok {
		ce.limits.MaxOptions = n
	}
	if n, ok, err := askEnvInt(env, "LLMCTL_DECIDE_MAX_STATE_CHARS", 1, 1<<30); err != nil {
		return nil, err
	} else if ok {
		ce.limits.MaxStateChars = n
	}
	if n, ok, err := askEnvInt(env, "LLMCTL_DECIDE_MAX_QUESTIONS", 1, 1<<20); err != nil {
		return nil, err
	} else if ok {
		ce.limits.MaxQuestions = n
	}
	if n, ok, err := askEnvInt(env, "LLMCTL_DECIDE_TRUNCATE", 0, 1); err != nil {
		return nil, err
	} else if ok {
		ce.limits.Truncate = n == 1
	}
	ce.endpoint = env["LLMCTL_ENDPOINT"]
	ce.cacert = env["LLMCTL_CACERT"]
	return ce, nil
}

// resolveEndpoint: --endpoint, else LLMCTL_ENDPOINT, else https://127.0.0.1:${LLMCTL_DECIDE_PORT:-8095}.
func (ce *askClientEnv) resolveEndpoint(flagVal string) string {
	switch {
	case flagVal != "":
		return flagVal
	case ce.endpoint != "":
		return ce.endpoint
	}
	return "https://127.0.0.1:" + ce.port
}

// resolveCA: --cacert, else LLMCTL_CACERT, else $LLMCTL_HOME/cert/ca/ca.crt (home default $HOME/llmctl).
func (ce *askClientEnv) resolveCA(flagVal string) string {
	switch {
	case flagVal != "":
		return flagVal
	case ce.cacert != "":
		return ce.cacert
	}
	return registry.ResolveCA(func(k string) string { return ce.env[k] }) // the one shared resolver (G-068)
}

// ---------------------------------------------------------------- flag plumbing

type askFlagSet struct {
	*flag.FlagSet
	name string
}

func askNewFlagSet(name string) *askFlagSet {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	if flagCapture != nil { // `completions` introspects the real flag sets through this hook
		flagCapture(fs)
	}
	return &askFlagSet{FlagSet: fs, name: name}
}

// parse is strict: an unknown flag, a missing value or a stray positional argument is exit 2.
func (f *askFlagSet) parse(args []string, stderr io.Writer) (int, bool) {
	if err := f.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			fmt.Fprintf(stderr, "usage: llmctl-decide %s [flags] (see `llmctl decide help`)\n", f.name)
			return 0, false
		}
		fmt.Fprintf(stderr, "llmctl-decide %s: %v\n", f.name, err)
		return 2, false
	}
	if f.NArg() > 0 {
		fmt.Fprintf(stderr, "llmctl-decide %s: unexpected argument %q\n", f.name, askShorten(f.Arg(0)))
		return 2, false
	}
	return 0, true
}

type askCommon struct {
	endpoint, cacert string
	retries          int
	timeoutSec       float64
	asJSON           bool
	minConf          float64
	minConfSet       bool
	profile          string
	permute          int // --permute K: ask K cyclic option orders and average (0/1 = off)
}

func (c *askCommon) register(fs *askFlagSet, withAsk bool) {
	fs.StringVar(&c.endpoint, "endpoint", "", "gateway URL (default $LLMCTL_ENDPOINT or https://127.0.0.1:${LLMCTL_DECIDE_PORT:-8095})")
	fs.StringVar(&c.cacert, "cacert", "", "CA certificate file (default $LLMCTL_CACERT or $LLMCTL_HOME/cert/ca/ca.crt)")
	fs.IntVar(&c.retries, "retries", client.DefaultRetries, "extra attempts after HTTP 429/503/529")
	fs.Float64Var(&c.timeoutSec, "timeout", 0, "seconds per attempt (default $LLMCTL_DECIDE_TIMEOUT or 30)")
	fs.BoolVar(&c.asJSON, "json", false, "machine-readable output")
	if withAsk {
		fs.StringVar(&c.profile, "profile", "", "decision profile / model id (default: the gateway's default)")
		fs.StringVar(&c.profile, "model", "", "alias of --profile")
		fs.Func("min-confidence", "withhold the answer (exit 10) when any confidence is below X (0..1); a calibrated answer (calibration present) is compared on its CALIBRATED confidence (a probability, chance = 1/n), otherwise on the shaped confidence (chance = 0)", func(s string) error {
			v, err := strconv.ParseFloat(s, 64)
			if err != nil || v < 0 || v > 1 {
				return fmt.Errorf("--min-confidence needs a number between 0 and 1")
			}
			c.minConf, c.minConfSet = v, true
			return nil
		})
		fs.Func("permute", "ask K cyclic orders of every choice question's options and report the order-averaged answer plus the flip rate (K calls)", func(s string) error {
			n, err := strconv.Atoi(strings.TrimSpace(s))
			if err != nil || n < 1 || n > client.MaxPermute {
				return fmt.Errorf("--permute needs a whole number between 1 and %d", client.MaxPermute)
			}
			c.permute = n
			return nil
		})
	}
}

// askNewClient resolves endpoint, CA and key (generate=false) and builds the client.
// The order of failures is: usage (2), key (4), certificate (5).
func askNewClient(ce *askClientEnv, c *askCommon, stderr io.Writer, who string) (*client.Client, int) {
	endpoint := ce.resolveEndpoint(c.endpoint)
	if _, err := client.ParseEndpoint(endpoint); err != nil {
		return nil, askFail(stderr, who, err)
	}
	kr, err := keyring.Resolve(installationRoot(), ce.env, false)
	if err != nil {
		fmt.Fprintf(stderr, "llmctl-decide %s: access key problem: %v\n", who, err)
		return nil, keyring.ExitCode
	}
	if kr.Source == "none" {
		fmt.Fprintf(stderr, "llmctl-decide %s: no access key found: export LLMCTL_API_KEY or store it in %s (the gateway creates it on first start; see `llmctl key doctor`)\n", who, kr.Path)
		return nil, keyring.ExitCode
	}
	timeout := ce.timeout
	if c.timeoutSec > 0 {
		timeout = time.Duration(c.timeoutSec * float64(time.Second))
	}
	cl, err := client.New(client.Config{Endpoint: endpoint, CAFile: ce.resolveCA(c.cacert), Key: kr.Key, Retries: c.retries, Timeout: timeout})
	if err != nil {
		return nil, askFail(stderr, who, err)
	}
	return cl, 0
}

func askFail(stderr io.Writer, who string, err error) int {
	fmt.Fprintf(stderr, "llmctl-decide %s: %v\n", who, err)
	return client.ExitCodeOf(err)
}

func askReadLimited(r io.Reader) ([]byte, error) {
	b, err := io.ReadAll(io.LimitReader(r, client.MaxInputBytes+1))
	if err != nil {
		return nil, err
	}
	if len(b) > client.MaxInputBytes {
		return nil, fmt.Errorf("input larger than %d MiB", client.MaxInputBytes>>20)
	}
	return b, nil
}

func askReadFile(path, what string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("cannot read %s %s: %s", what, path, strings.TrimPrefix(err.Error(), "open "+path+": "))
	}
	defer f.Close()
	b, err := askReadLimited(f)
	if err != nil {
		return nil, fmt.Errorf("cannot read %s %s: %v", what, path, err)
	}
	return b, nil
}

// ---------------------------------------------------------------- ask

type askFlags struct {
	askCommon
	state, stateFile, instructions string
	useStdin                       bool
	qtype                          string
	criteria, criteriaFile         string
	questionFile                   string
	dryRun, explain                bool
}

func runAsk(args []string, stdout, stderr io.Writer) int {
	var f askFlags
	fs := askNewFlagSet("ask")
	f.register(fs, true)
	fs.StringVar(&f.state, "state", "", "state text (visible in process listings; prefer --state-file or --stdin)")
	fs.StringVar(&f.stateFile, "state-file", "", "read the state from FILE (any size)")
	fs.BoolVar(&f.useStdin, "stdin", false, "read the state from standard input")
	fs.StringVar(&f.instructions, "instructions", "", "the question to answer")
	fs.StringVar(&f.qtype, "type", "", "noul | choice | score")
	fs.StringVar(&f.criteria, "criteria", "", "criteria JSON (choice: {\"opt\":\"desc\"}; score: [\"lvl0\",...]; noul: {\"true\":..,\"false\":..})")
	fs.StringVar(&f.criteriaFile, "criteria-file", "", "read the criteria JSON from FILE")
	fs.StringVar(&f.questionFile, "question-file", "", "a Typed Question JSON object (or a full request) instead of --type/--instructions/--criteria")
	fs.BoolVar(&f.dryRun, "dry-run", false, "validate and print what would be sent; no network, no key needed")
	fs.BoolVar(&f.explain, "explain", false, "print the rendered prompt, the letter map and the per-option probabilities (to stderr)")
	if rc, ok := fs.parse(args, stderr); !ok {
		return rc
	}
	ce, err := askLoadEnv(askEnviron())
	if err != nil {
		fmt.Fprintf(stderr, "llmctl-decide ask: %v\n", err)
		return 2
	}
	built, rc := askBuild(&f, fs, ce, stderr)
	if built == nil {
		return rc
	}
	if f.dryRun || f.explain {
		parsed, err := askLocalValidate(built, ce)
		if err != nil {
			fmt.Fprintf(stderr, "llmctl-decide ask: %v\n", err)
			return 2
		}
		if f.explain {
			askExplainPrompts(stderr, parsed)
		}
		if f.dryRun {
			return askDryRun(stdout, ce, &f.askCommon, built)
		}
	}
	cl, rc := askNewClient(ce, &f.askCommon, stderr, "ask")
	if cl == nil {
		return rc
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	res, perm, err := askOnce(ctx, cl, built.Body, &f.askCommon)
	if err != nil {
		return askFail(stderr, "ask", err)
	}
	out, abst, rc := askFinish(res, built.Model, &f.askCommon, perm)
	if rc == 1 {
		fmt.Fprintln(stderr, "llmctl-decide ask: the gateway answered with a malformed result")
		return 1
	}
	if f.explain {
		askExplainProbs(stderr, res.Body)
	}
	if !f.asJSON && askIsTerminal(stdout) {
		var pretty bytes.Buffer
		if json.Indent(&pretty, out, "", "  ") == nil {
			out = pretty.Bytes()
		}
	}
	stdout.Write(append(out, '\n'))
	if abst {
		fmt.Fprintf(stderr, "llmctl-decide ask: answer withheld: confidence below --min-confidence %g\n", f.minConf)
		return client.Abstained
	}
	return 0
}

// askOnce is one gateway call, or the K permuted calls of --permute.
func askOnce(ctx context.Context, cl *client.Client, body []byte, c *askCommon) (*client.Result, *client.PermuteStats, error) {
	if c.permute > 1 {
		return cl.AskPermuted(ctx, body, c.permute)
	}
	res, err := cl.Ask(ctx, body)
	return res, nil, err
}

// askFinish annotates a response with evidence (and the abstention verdict).
func askFinish(res *client.Result, requested string, c *askCommon, perm *client.PermuteStats) (out []byte, abstained bool, rc int) {
	a := client.Annotation{Port: res.Port, Latency: float64(res.Latency) / float64(time.Millisecond), Truncated: res.Truncated, Mode: res.Mode, Instance: res.Instance}
	if perm != nil && perm.K > 1 {
		a.Permute = perm
	}
	if fl, err := client.AnyFlagged(res.Body); err == nil {
		a.Flagged = fl
	}
	if cal, err := client.AnyCalibrated(res.Body); err == nil {
		a.Calibrated = cal
	}
	model, _, err := client.Answers(res.Body)
	if err != nil {
		return nil, false, 1
	}
	a.Profile = model
	if a.Profile == "" {
		a.Profile = requested
	}
	if c.minConfSet {
		min, err := client.MinConfidence(res.Body)
		if err != nil {
			return nil, false, 1
		}
		abstained = min < c.minConf
		a.Abstained = &abstained
	}
	out, err = client.Annotate(res.Body, a)
	if err != nil {
		return nil, false, 1
	}
	return out, abstained, 0
}

func askBuild(f *askFlags, fs *askFlagSet, ce *askClientEnv, stderr io.Writer) (*client.Built, int) {
	usage := func(format string, a ...any) (*client.Built, int) {
		fmt.Fprintf(stderr, "llmctl-decide ask: "+format+"\n", a...)
		return nil, 2
	}
	set := map[string]bool{}
	fs.Visit(func(fl *flag.Flag) { set[fl.Name] = true })
	sources := 0
	for _, n := range []string{"state", "state-file", "stdin"} {
		if set[n] {
			sources++
		}
	}
	if sources > 1 {
		return usage("give the state once: --state, --state-file or --stdin")
	}
	if set["criteria"] && set["criteria-file"] {
		return usage("give the criteria once: --criteria or --criteria-file")
	}
	if set["question-file"] && (set["type"] || set["instructions"] || set["criteria"] || set["criteria-file"]) {
		return usage("--question-file replaces --type, --instructions and --criteria")
	}
	if (set["model"] || set["profile"]) && strings.TrimSpace(f.profile) == "" {
		return usage("--model/--profile needs a profile id; an empty value is not the gateway default (omit the flag for that)")
	}
	in := client.Input{Model: f.profile}
	switch {
	case set["state"]:
		in.State, in.HasState = f.state, true
	case set["state-file"]:
		b, err := askReadFile(f.stateFile, "--state-file")
		if err != nil {
			return usage("%v", err)
		}
		in.State, in.HasState = string(b), true
	case set["stdin"]:
		b, err := askReadLimited(askStdin)
		if err != nil {
			return usage("cannot read the state from standard input: %v", err)
		}
		in.State, in.HasState = string(b), true
	}
	if set["question-file"] {
		b, err := askReadFile(f.questionFile, "--question-file")
		if err != nil {
			return usage("%v", err)
		}
		in.QuestionFile = b
	} else {
		in.Type, in.Instructions = f.qtype, f.instructions
		crit := f.criteria
		if set["criteria-file"] {
			b, err := askReadFile(f.criteriaFile, "--criteria-file")
			if err != nil {
				return usage("%v", err)
			}
			crit = string(b)
		}
		if strings.TrimSpace(crit) != "" {
			in.Criteria = json.RawMessage(crit)
		}
	}
	built, err := client.Build(in)
	if err != nil {
		return usage("%v", err)
	}
	return built, 0
}

var askProfileIDRE = regexp.MustCompile(`^[a-z0-9-]+$`)

// askLocalValidate parses the request with the contract package under the client's view of the
// limits (environment); used by --dry-run and --explain only - a real call is validated by the
// gateway, whose limits are authoritative.
func askLocalValidate(b *client.Built, ce *askClientEnv) (*contract.ParsedRequest, error) {
	id := "local"
	if askProfileIDRE.MatchString(b.Model) {
		id = b.Model
	}
	profiles, err := contract.NewProfiles([]string{id}, id, nil)
	if err != nil {
		return nil, err
	}
	req, err := contract.ParseRequest(b.Local, ce.limits, profiles)
	if err != nil {
		var ce2 *contract.ContractError
		if errors.As(err, &ce2) {
			return nil, fmt.Errorf("invalid request (%s): %s", ce2.ErrorType, ce2.Message)
		}
		return nil, err
	}
	return req, nil
}

func askDryRun(w io.Writer, ce *askClientEnv, c *askCommon, b *client.Built) int {
	endpoint := ce.resolveEndpoint(c.endpoint)
	model := b.Model
	if model == "" {
		model = "(gateway default)"
	}
	if c.asJSON {
		doc := map[string]any{"dry_run": true, "endpoint": endpoint, "path": "/v1/systemone", "model": model,
			"questions": b.Questions, "state_bytes": b.StateBytes, "body_bytes": len(b.Body)}
		out, _ := json.Marshal(doc)
		fmt.Fprintf(w, "%s\n", out)
		return 0
	}
	fmt.Fprintf(w, "dry-run: would POST %s/v1/systemone\n  model: %s\n  questions: %d\n  state: %d bytes\n  body: %d bytes\n  nothing was sent\n",
		strings.TrimRight(endpoint, "/"), model, b.Questions, b.StateBytes, len(b.Body))
	return 0
}

func askExplainPrompts(w io.Writer, req *contract.ParsedRequest) {
	for _, q := range req.Questions {
		prompt, err := contract.RenderPrompt(q, req.StateText)
		fmt.Fprintf(w, "== question %q (%s) ==\n", q.Name, q.Type)
		if err != nil {
			fmt.Fprintf(w, "cannot render a letter prompt: %v\n", err)
			continue
		}
		fmt.Fprintln(w, "-- rendered prompt (decoder profiles; encoder profiles pair state with each option instead) --")
		fmt.Fprintln(w, prompt)
		fmt.Fprintln(w, "-- letter map --")
		for _, o := range q.Options {
			fmt.Fprintf(w, "%s -> %s\n", o.Letter, o.Key)
		}
	}
}

func askExplainProbs(w io.Writer, body []byte) {
	_, as, err := client.Answers(body)
	if err != nil {
		return
	}
	fmt.Fprintln(w, "-- per-option probabilities --")
	names := make([]string, 0, len(as))
	for n := range as {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		a := as[n]
		if a.Type == contract.TypeNoul && a.Noul != nil {
			fmt.Fprintf(w, "%s: p(yes)=%g p(no)=%g\n", n, *a.Noul, 1-*a.Noul)
			continue
		}
		fmt.Fprintf(w, "%s: %v confidence=%g", n, a.Probabilities, client.AnswerConfidence(a))
		if a.ConfidenceRaw != nil {
			fmt.Fprintf(w, " confidence_raw=%g", *a.ConfidenceRaw)
		}
		if a.Calibrated() {
			var cm struct {
				Method string `json:"method"`
				N      int    `json:"n"`
			}
			if json.Unmarshal(a.Calibration, &cm) == nil {
				fmt.Fprintf(w, " calibrated(%s, n=%d)", cm.Method, cm.N)
			}
		} else if len(a.Calibration) > 0 {
			fmt.Fprintf(w, " calibration=%s", a.Calibration)
		}
		fmt.Fprintln(w)
	}
}

// ---------------------------------------------------------------- batch

func runBatch(args []string, stdout, stderr io.Writer) int {
	var c askCommon
	var in, out string
	fs := askNewFlagSet("batch")
	c.register(fs, true)
	fs.StringVar(&in, "in", "-", "newline-delimited JSON input file (- = standard input)")
	fs.StringVar(&out, "out", "-", "newline-delimited JSON output file (- = standard output)")
	if rc, ok := fs.parse(args, stderr); !ok {
		return rc
	}
	ce, err := askLoadEnv(askEnviron())
	if err != nil {
		fmt.Fprintf(stderr, "llmctl-decide batch: %v\n", err)
		return 2
	}
	cl, rc := askNewClient(ce, &c, stderr, "batch")
	if cl == nil {
		return rc
	}
	var r io.Reader = askStdin
	if in != "-" {
		f, err := os.Open(in)
		if err != nil {
			fmt.Fprintf(stderr, "llmctl-decide batch: cannot read --in %s\n", in)
			return 2
		}
		defer f.Close()
		r = f
	}
	var w io.Writer = stdout
	if out != "-" {
		f, err := os.OpenFile(out, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
		if err != nil {
			fmt.Fprintf(stderr, "llmctl-decide batch: cannot write --out %s\n", out)
			return 2
		}
		defer f.Close()
		w = f
	}
	bw := bufio.NewWriter(w)
	defer bw.Flush()
	br := bufio.NewReaderSize(r, 1<<20)
	worst := 0
	note := func(code int) {
		if client.Severity(code) > client.Severity(worst) {
			worst = code
		}
	}
	lineNo := 0
	for {
		line, rerr := askReadLine(br)
		if len(bytes.TrimSpace(line)) > 0 {
			lineNo++
			code := askBatchLine(bw, cl, line, &c, ce)
			note(code)
			bw.Flush()
		}
		if rerr != nil {
			if rerr != io.EOF {
				fmt.Fprintf(stderr, "llmctl-decide batch: read error after %d lines\n", lineNo)
				note(2)
			}
			break
		}
	}
	return worst
}

// askReadLine reads one line of any length (up to MaxInputBytes) without bufio.Scanner's token cap.
func askReadLine(br *bufio.Reader) ([]byte, error) {
	var buf []byte
	for {
		chunk, isPrefix, err := br.ReadLine()
		buf = append(buf, chunk...)
		if len(buf) > client.MaxInputBytes {
			return nil, io.ErrShortBuffer
		}
		if err != nil || !isPrefix {
			return buf, err
		}
	}
}

type askBatchLineDoc struct {
	ID        json.RawMessage `json:"id"`
	Model     json.RawMessage `json:"model"`
	State     json.RawMessage `json:"state"`
	Questions json.RawMessage `json:"questions"`
}

func askBatchErrLine(w io.Writer, id json.RawMessage, code int, msg string) {
	if len(id) == 0 {
		id = json.RawMessage("null")
	}
	m, _ := json.Marshal(msg)
	fmt.Fprintf(w, `{"id":%s,"error":{"exit_code":%d,"message":%s}}`+"\n", id, code, m)
}

func askBatchLine(w io.Writer, cl *client.Client, line []byte, c *askCommon, ce *askClientEnv) int {
	var d askBatchLineDoc
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(line, &raw); err != nil || raw == nil {
		askBatchErrLine(w, nil, 2, "the line is not a JSON object")
		return 2
	}
	if err := json.Unmarshal(line, &d); err != nil {
		// a field of the wrong JSON type (for example "model":5) is reported, never papered over
		askBatchErrLine(w, raw["id"], 2, "a field of the batch line has the wrong type (model must be a string, state text/object/array, questions an object)")
		return 2
	}
	for k := range raw {
		if k != "id" && k != "model" && k != "state" && k != "questions" {
			askBatchErrLine(w, d.ID, 2, "unknown field in the batch line")
			return 2
		}
	}
	if d.Questions == nil || d.State == nil {
		askBatchErrLine(w, d.ID, 2, "a batch line needs \"state\" and \"questions\"")
		return 2
	}
	model := ""
	if d.Model != nil {
		if bytes.Equal(bytes.TrimSpace(d.Model), []byte("null")) || json.Unmarshal(d.Model, &model) != nil {
			askBatchErrLine(w, d.ID, 2, `"model" in the batch line must be a string (a profile id)`)
			return 2
		}
		if model == "" { // an explicit empty model must not silently become the default profile (B2-09)
			askBatchErrLine(w, d.ID, 2, `"model" in the batch line must not be empty (omit it for the default profile)`)
			return 2
		}
	}
	if t := bytes.TrimSpace(d.Questions); len(t) == 0 || t[0] != '{' {
		askBatchErrLine(w, d.ID, 2, `"questions" in the batch line must be an object`)
		return 2
	}
	if t := bytes.TrimSpace(d.State); len(t) == 0 || (t[0] != '"' && t[0] != '{' && t[0] != '[') {
		askBatchErrLine(w, d.ID, 2, `"state" in the batch line must be text, an object or an array`)
		return 2
	}
	req, _ := json.Marshal(map[string]json.RawMessage{"state": d.State, "questions": d.Questions})
	if model == "" {
		model = c.profile
	}
	if model != "" {
		mj, _ := json.Marshal(model)
		req, _ = json.Marshal(map[string]json.RawMessage{"model": mj, "state": d.State, "questions": d.Questions})
	}
	res, perm, err := askOnce(context.Background(), cl, req, c)
	if err != nil {
		code := client.ExitCodeOf(err)
		askBatchErrLine(w, d.ID, code, err.Error())
		return code
	}
	body, abst, rc := askFinish(res, model, c, perm)
	if rc == 1 {
		askBatchErrLine(w, d.ID, 1, "the gateway answered with a malformed result")
		return 1
	}
	id := d.ID
	if len(id) == 0 {
		id = json.RawMessage("null")
	}
	fmt.Fprintf(w, `{"id":%s,"result":%s}`+"\n", id, body)
	if abst {
		return client.Abstained
	}
	return 0
}

// ---------------------------------------------------------------- models

func runModels(args []string, stdout, stderr io.Writer) int {
	var c askCommon
	fs := askNewFlagSet("models")
	c.register(fs, false)
	if rc, ok := fs.parse(args, stderr); !ok {
		return rc
	}
	ce, err := askLoadEnv(askEnviron())
	if err != nil {
		fmt.Fprintf(stderr, "llmctl-decide models: %v\n", err)
		return 2
	}
	cl, rc := askNewClient(ce, &c, stderr, "models")
	if cl == nil {
		return rc
	}
	res, err := cl.Models(context.Background())
	if err != nil {
		return askFail(stderr, "models", err)
	}
	if c.asJSON {
		stdout.Write(append(bytes.TrimSpace(res.Body), '\n'))
		return 0
	}
	var doc struct {
		Data []struct {
			ID       string   `json:"id"`
			Aliases  []string `json:"aliases"`
			Protocol string   `json:"protocol"`
			Status   string   `json:"status"`
			Hash     string   `json:"template_hash"`
			Cal      *struct {
				Applied bool   `json:"applied"`
				Reason  string `json:"reason"`
				Method  string `json:"method"`
			} `json:"calibration"`
		} `json:"data"`
	}
	if json.Unmarshal(res.Body, &doc) != nil {
		fmt.Fprintln(stderr, "llmctl-decide models: the gateway answered with a malformed result")
		return 1
	}
	fmt.Fprintf(stdout, "%-24s %-8s %-16s %-26s %-14s %s\n", "model", "status", "protocol", "calibration", "template", "aliases")
	for _, m := range doc.Data {
		cal, tmpl := "-", "-"
		switch {
		case m.Cal != nil && m.Cal.Applied:
			cal = "applied"
			if m.Cal.Method != "" {
				cal += " (" + m.Cal.Method + ")"
			}
		case m.Cal != nil:
			cal = "not applied"
			if m.Cal.Reason != "" {
				cal += " (" + m.Cal.Reason + ")"
			}
		}
		if len(m.Hash) >= 12 {
			tmpl = m.Hash[:12]
		}
		fmt.Fprintf(stdout, "%-24s %-8s %-16s %-26s %-14s %s\n", m.ID, m.Status, m.Protocol, cal, tmpl, strings.Join(m.Aliases, ","))
	}
	return 0
}

// askIsTerminal reports whether w is an interactive terminal (pretty-print only there).
func askIsTerminal(w io.Writer) bool {
	f, ok := w.(*os.File)
	if !ok {
		return false
	}
	st, err := f.Stat()
	return err == nil && st.Mode()&os.ModeCharDevice != 0
}
