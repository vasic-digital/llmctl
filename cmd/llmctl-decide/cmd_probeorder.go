package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"strconv"
	"strings"

	"github.com/vasic-digital/llmctl/internal/client"
)

// `llmctl-decide probe-order --questions F [--profile P] [--permute K]` (contracts/cli.md, FR-080):
// re-asks every choice question with its options in K cyclic orders (the rotation of `ask --permute`)
// and prints, per question, the answer-flip rate and the per-position bias, plus an overall summary.
// Costs K gateway calls per request document. Exit codes follow the client contract: 0 measured,
// 1 backend/readout failure, 2 usage (also: nothing to probe), 4 key, 5 certificate/TLS, 6 not
// ready / unreachable. A failed call aborts the run and prints no partial result.
func init() {
	register("probe-order", func(a []string, o, e io.Writer) int { return runProbeOrder(a, o, e) })
}

type probeDocOut struct {
	ID        string                 `json:"id"`
	Calls     int                    `json:"calls"`
	Questions []client.QuestionProbe `json:"questions"`
}

type probeReport struct {
	Profile   string              `json:"profile,omitempty"`
	Calls     int                 `json:"calls"`
	Documents []probeDocOut       `json:"documents"`
	Summary   client.ProbeSummary `json:"summary"`
}

func runProbeOrder(args []string, stdout, stderr io.Writer) int {
	var c askCommon
	var questions, stateFile string
	permute := 0
	fs := askNewFlagSet("probe-order")
	c.register(fs, false)
	fs.StringVar(&c.profile, "profile", "", "decision profile / model id (default: the gateway's default, or the model in the file)")
	fs.StringVar(&c.profile, "model", "", "alias of --profile")
	fs.StringVar(&questions, "questions", "", "request file: one request object, a JSON array of them, or newline-delimited JSON (- = standard input); a bare Typed Question needs --state-file")
	fs.StringVar(&stateFile, "state-file", "", "state text for documents that carry none")
	fs.Func("permute", "option orders per request: 0 = a full cycle (one call per option of the largest question, the default), or 2.."+strconv.Itoa(client.MaxPermute), func(s string) error {
		n, err := strconv.Atoi(strings.TrimSpace(s))
		if err != nil || (n != 0 && (n < 2 || n > client.MaxPermute)) {
			return fmt.Errorf("--permute needs 0 (a full cycle) or a whole number between 2 and %d", client.MaxPermute)
		}
		permute = n
		return nil
	})
	if rc, ok := fs.parse(args, stderr); !ok {
		return rc
	}
	usage := func(format string, a ...any) int {
		fmt.Fprintf(stderr, "llmctl-decide probe-order: "+format+"\n", a...)
		return 2
	}
	set := map[string]bool{}
	fs.Visit(func(fl *flag.Flag) { set[fl.Name] = true })
	if (set["profile"] || set["model"]) && strings.TrimSpace(c.profile) == "" {
		return usage("--model/--profile needs a profile id; an empty value is not the gateway default (omit the flag for that)")
	}
	if questions == "" {
		return usage("--questions FILE is required (requests as one JSON object, a JSON array or newline-delimited JSON; - = standard input)")
	}
	ce, err := askLoadEnv(askEnviron())
	if err != nil {
		return usage("%v", err)
	}
	var raw []byte
	if questions == "-" {
		raw, err = askReadLimited(askStdin)
		if err != nil {
			return usage("cannot read the questions from standard input: %v", err)
		}
	} else if raw, err = askReadFile(questions, "--questions"); err != nil {
		return usage("%v", err)
	}
	docs, err := probeSplitDocs(raw)
	if err != nil {
		return usage("%v", err)
	}
	var state string
	hasState := false
	if stateFile != "" {
		b, err := askReadFile(stateFile, "--state-file")
		if err != nil {
			return usage("%v", err)
		}
		state, hasState = string(b), true
	}
	type job struct {
		id    string
		built *client.Built
	}
	var jobs []job
	probeable := 0
	for i, d := range docs {
		var top map[string]json.RawMessage
		_ = json.Unmarshal(d, &top)
		in := client.Input{Model: c.profile, QuestionFile: d}
		if _, own := top["state"]; !own && hasState {
			in.State, in.HasState = state, true
		}
		built, err := client.Build(in)
		if err != nil {
			msg := err.Error()
			if strings.HasPrefix(msg, "a state is required") {
				msg = "a request without a state needs --state-file"
			}
			return usage("document %d: %s", i+1, msg)
		}
		if _, err := askLocalValidate(built, ce); err != nil {
			return usage("document %d: %v", i+1, err)
		}
		qs, err := client.PermutableQuestions(built.Body)
		if err != nil {
			return usage("document %d: %v", i+1, err)
		}
		for _, q := range qs {
			if q.Permutable {
				probeable++
			}
		}
		id := strconv.Itoa(i + 1)
		var idv json.RawMessage = top["id"]
		var s string
		var num json.Number
		switch {
		case json.Unmarshal(idv, &s) == nil && s != "":
			id = s
		case json.Unmarshal(idv, &num) == nil && num != "":
			id = num.String()
		}
		jobs = append(jobs, job{id: id, built: built})
	}
	if probeable == 0 {
		return usage("nothing to probe: no choice question with at least two options (noul and score questions are not interchangeable)")
	}
	cl, rc := askNewClient(ce, &c, stderr, "probe-order")
	if cl == nil {
		return rc
	}
	rep := &probeReport{Profile: c.profile, Documents: []probeDocOut{}}
	for _, j := range jobs {
		res, err := cl.ProbeOrder(context.Background(), j.built.Body, permute)
		if err != nil {
			return askFail(stderr, "probe-order", err)
		}
		rep.Documents = append(rep.Documents, probeDocOut{ID: j.id, Calls: res.Calls, Questions: res.Questions})
		rep.Calls += res.Calls
		s := &rep.Summary
		s.Questions += res.Summary.Questions
		s.Trials += res.Summary.Trials
		s.Flips += res.Summary.Flips
		if res.Summary.MaxPositionDeviation > s.MaxPositionDeviation {
			s.MaxPositionDeviation = res.Summary.MaxPositionDeviation
		}
	}
	if rep.Summary.Trials > 0 {
		rep.Summary.FlipRate = float64(rep.Summary.Flips) / float64(rep.Summary.Trials)
	}
	if c.asJSON {
		out, _ := json.Marshal(rep)
		fmt.Fprintf(stdout, "%s\n", out)
		return 0
	}
	renderProbe(stdout, rep)
	return 0
}

// probeSplitDocs splits the questions file into request documents: a JSON array of objects, or
// a stream of JSON values (one object, or newline-delimited objects).
func probeSplitDocs(raw []byte) ([][]byte, error) {
	t := bytes.TrimSpace(bytes.TrimPrefix(raw, []byte("\xef\xbb\xbf")))
	if len(t) == 0 {
		return nil, errors.New("the questions file is empty")
	}
	var vals []json.RawMessage
	if t[0] == '[' {
		if err := json.Unmarshal(t, &vals); err != nil {
			return nil, fmt.Errorf("the questions file is not valid JSON: %v", err)
		}
	} else {
		dec := json.NewDecoder(bytes.NewReader(t))
		for {
			var v json.RawMessage
			if err := dec.Decode(&v); err == io.EOF {
				break
			} else if err != nil {
				return nil, fmt.Errorf("the questions file is not valid JSON: %v", err)
			}
			vals = append(vals, v)
		}
	}
	out := make([][]byte, 0, len(vals))
	for i, v := range vals {
		if tv := bytes.TrimSpace(v); len(tv) == 0 || tv[0] != '{' {
			return nil, fmt.Errorf("document %d of the questions file is not a JSON object", i+1)
		}
		out = append(out, v)
	}
	if len(out) == 0 {
		return nil, errors.New("the questions file contains no request")
	}
	return out, nil
}

func renderProbe(w io.Writer, rep *probeReport) {
	model := rep.Profile
	if model == "" {
		model = "the gateway default"
	}
	fmt.Fprintf(w, "probe-order: %d document(s), %d gateway calls (profile %s)\n", len(rep.Documents), rep.Calls, model)
	for _, d := range rep.Documents {
		fmt.Fprintf(w, "document %s (%d calls)\n", d.ID, d.Calls)
		for _, q := range d.Questions {
			if !q.Permutable {
				fmt.Fprintf(w, "  %s (%s): not permutable - %s\n", q.Name, q.Type, q.Reason)
				continue
			}
			fmt.Fprintf(w, "  %s (choice, %d options): %d orders, answer %q, flip rate %.3f (%d of %d)", q.Name, q.Options, q.Orders, q.Answer, q.FlipRate, q.Flips, q.Orders)
			if q.PartialCycle {
				fmt.Fprint(w, "  [partial cycle: position bias only partly cancelled]")
			}
			fmt.Fprintln(w)
			parts := make([]string, len(q.PositionShare))
			for i, s := range q.PositionShare {
				parts[i] = fmt.Sprintf("%d:%.3f", i+1, s)
			}
			fmt.Fprintf(w, "    answer at listing position %s (uniform = %.3f, max deviation %.3f)\n", strings.Join(parts, " "), q.PositionExpected, q.MaxPositionDeviation)
		}
	}
	s := rep.Summary
	fmt.Fprintf(w, "overall: %d trials over %d question(s), flip rate %.3f (%d flips), max position deviation %.3f\n", s.Trials, s.Questions, s.FlipRate, s.Flips, s.MaxPositionDeviation)
}
