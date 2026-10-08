package contract_test

import (
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"

	"github.com/vasic-digital/llmctl/internal/contract"
)

// body builds a request body. over is key,rawJSON pairs that override or add
// top-level fields; the defaults are a valid noul request. Key order is
// model, state, questions, then the rest sorted.
func body(over ...string) []byte {
	m := map[string]string{
		"state":     `"the printer is on fire"`,
		"questions": `{"q":{"type":"noul","instructions":"Is it urgent?"}}`,
	}
	for i := 0; i+1 < len(over); i += 2 {
		m[over[i]] = over[i+1]
	}
	var keys []string
	for _, k := range []string{"model", "state", "questions"} {
		if _, ok := m[k]; ok {
			keys = append(keys, k)
		}
	}
	var rest []string
	for k := range m {
		if k != "model" && k != "state" && k != "questions" {
			rest = append(rest, k)
		}
	}
	sort.Strings(rest)
	keys = append(keys, rest...)
	var parts []string
	for _, k := range keys {
		parts = append(parts, fmt.Sprintf("%q:%s", k, m[k]))
	}
	return []byte("{" + strings.Join(parts, ",") + "}")
}

func js(s string) string { b, _ := json.Marshal(s); return string(b) }

// choiceQ is a choice question with n options opt0..opt(n-1), in order.
func choiceQ(n int) string {
	var o []string
	for i := 0; i < n; i++ {
		o = append(o, fmt.Sprintf(`"opt%d":"desc %d"`, i, i))
	}
	return `{"type":"choice","instructions":"pick","criteria":{` + strings.Join(o, ",") + `}}`
}

func scoreQ(n int) string {
	var o []string
	for i := 0; i < n; i++ {
		o = append(o, fmt.Sprintf(`"l%d"`, i))
	}
	return `{"type":"score","instructions":"rate","criteria":[` + strings.Join(o, ",") + `]}`
}

func qs(name, q string) string { return `{` + js(name) + `:` + q + `}` }

var (
	tinyBig  = mustProfiles([]string{"decide-tiny", "decide-big"}, "decide-tiny", nil)
	lim      = contract.DefaultLimits()
	bigLimit = func() contract.Limits {
		l := contract.DefaultLimits()
		l.MaxOptions = 255
		l.MaxStateChars = 1_000_000
		return l
	}()
)

func mustProfiles(ids []string, def string, lims map[string]contract.Limits) *contract.Profiles {
	p, err := contract.NewProfiles(ids, def, lims)
	if err != nil {
		panic(err)
	}
	return p
}

func parse(b []byte) (*contract.ParsedRequest, error) {
	return contract.ParseRequest(b, lim, tinyBig)
}

func parseL(b []byte, l contract.Limits) (*contract.ParsedRequest, error) {
	return contract.ParseRequest(b, l, tinyBig)
}

// outcome reduces an error to (status, error_type); (200,"") when nil.
type outcome struct {
	Status int
	Type   string
}

func outcomeOf(err error) outcome {
	if err == nil {
		return outcome{200, ""}
	}
	var ce *contract.ContractError
	if errors.As(err, &ce) {
		return outcome{ce.Status, ce.ErrorType}
	}
	return outcome{-1, err.Error()}
}

func mustParse(t interface{ Fatalf(string, ...any) }, b []byte) *contract.ParsedRequest {
	p, err := parse(b)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	return p
}
