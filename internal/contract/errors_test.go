package contract_test

import (
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"

	"github.com/vasic-digital/llmctl/internal/contract"
)

func TestContentType(t *testing.T) {
	for _, ok := range []string{"application/json", "Application/JSON; charset=utf-8", " application/json ;x=y"} {
		if err := contract.CheckContentType(ok); err != nil {
			t.Errorf("%q: %v", ok, err)
		}
	}
	for _, bad := range []string{"", "text/plain", "application/jsonx", "application/xml", "application/json5"} {
		if got := outcomeOf(contract.CheckContentType(bad)); got != (outcome{400, "invalid_request"}) {
			t.Errorf("%q: %v", bad, got)
		}
	}
}

func TestBodySize(t *testing.T) {
	if err := contract.CheckBodySize(10, 10); err != nil {
		t.Fatal(err)
	}
	if got := outcomeOf(contract.CheckBodySize(11, 10)); got != (outcome{413, "payload_too_large"}) {
		t.Fatal(got)
	}
	if got := outcomeOf(contract.CheckBodySize(-1, 10)); got.Status != 400 {
		t.Fatal(got)
	}
	if err := contract.CheckBodySize(0, 10); err != nil {
		t.Fatal(err)
	}
}

func TestErrorBodyShapeAndValidation(t *testing.T) {
	e, err := contract.NewError(422, "validation_failed", "bad", nil)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(e.Body())
	if string(b) != `{"message":"bad","error_type":"validation_failed"}` {
		t.Fatalf("body %s", b)
	}
	if e.Error() != "bad" {
		t.Fatal(e.Error())
	}
	if _, err := contract.NewError(422, "not_a_type", "x", nil); err == nil {
		t.Fatal("unknown error type must be refused")
	}
	if e.Retryable() {
		t.Fatal("422 is not retryable")
	}
	// the struct literal form works for the server too, and unknown statuses are not retryable
	if (&contract.ContractError{Status: 599}).Retryable() {
		t.Fatal("unknown status must not be retryable")
	}
}

func TestTransportErrors(t *testing.T) {
	e, err := contract.TransportError(401, contract.TransportOptions{})
	if err != nil || e.Headers["WWW-Authenticate"] != `Bearer realm="llmctl"` || e.ErrorType != "unauthorized" || e.Retryable() {
		t.Fatalf("401: %+v %v", e, err)
	}
	e, _ = contract.TransportError(405, contract.TransportOptions{Allow: "GET"})
	if e.Headers["Allow"] != "GET" {
		t.Fatal(e.Headers)
	}
	e, _ = contract.TransportError(405, contract.TransportOptions{})
	if e.Headers["Allow"] != "GET, POST" {
		t.Fatal(e.Headers)
	}
	three := 3
	for _, st := range []int{429, 503, 529} {
		e, err := contract.TransportError(st, contract.TransportOptions{RetryAfter: &three})
		if err != nil || e.Headers["Retry-After"] != "3" || !e.Retryable() {
			t.Errorf("%d: %+v %v", st, e, err)
		}
		d, _ := contract.TransportError(st, contract.TransportOptions{})
		if d.Headers["Retry-After"] != "1" {
			t.Errorf("%d default Retry-After: %v", st, d.Headers)
		}
	}
	e, _ = contract.TransportError(502, contract.TransportOptions{})
	if !e.Retryable() || e.ErrorType != "backend_failed" {
		t.Fatal(e)
	}
	if _, ok := e.Headers["Retry-After"]; ok {
		t.Fatal("502 carries no Retry-After")
	}
	neg := -1
	if _, err := contract.TransportError(429, contract.TransportOptions{RetryAfter: &neg}); err == nil {
		t.Fatal("negative Retry-After refused")
	}
	for _, st := range []int{418, 400, 413, 422, 200} {
		if _, err := contract.TransportError(st, contract.TransportOptions{}); err == nil {
			t.Errorf("%d is not a transport-level status", st)
		}
	}
}

func TestReadoutFailedMapping(t *testing.T) {
	e := contract.ReadoutFailedError()
	if e.Status != 422 || e.ErrorType != "readout_failed" || e.Retryable() {
		t.Fatalf("%+v", e)
	}
}

// statusTableFromOpenAPI extracts the markdown STATUS TABLE rows with plain string handling.
func statusTableFromOpenAPI(t *testing.T) map[int][2]bool {
	raw, err := os.ReadFile("../../specs/009-jev-decision-models/contracts/openapi.yaml")
	if err != nil {
		t.Fatal(err)
	}
	text := string(raw)
	at := strings.Index(text, "STATUS TABLE")
	if at < 0 {
		t.Fatal("no STATUS TABLE in openapi.yaml")
	}
	rows := map[int][2]bool{}
	for _, line := range strings.Split(text[at:], "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "|") || !strings.HasSuffix(line, "|") {
			if len(rows) > 0 {
				break
			}
			continue
		}
		cells := strings.Split(line, "|")
		// "", status, condition, retryable, retry-after, ""
		if len(cells) < 6 {
			continue
		}
		st := strings.TrimSpace(cells[1])
		if len(st) != 3 || st[0] < '0' || st[0] > '9' {
			continue
		}
		n := 0
		for _, c := range st {
			n = n*10 + int(c-'0')
		}
		yn := func(s string) bool {
			s = strings.TrimSpace(s)
			if s != "yes" && s != "no" {
				t.Fatalf("row %d: cell %q is neither yes nor no", n, s)
			}
			return s == "yes"
		}
		rows[n] = [2]bool{yn(cells[len(cells)-3]), yn(cells[len(cells)-2])}
	}
	return rows
}

func TestOpenAPIStatusTableMatchesGo(t *testing.T) {
	rows := statusTableFromOpenAPI(t)
	if len(rows) < 10 {
		t.Fatalf("parsed only %d rows", len(rows))
	}
	table := contract.StatusTable()
	if len(table) != len(rows) {
		t.Fatalf("go table has %d statuses, openapi %d", len(table), len(rows))
	}
	for st, want := range rows {
		got, ok := table[st]
		if !ok {
			t.Errorf("status %d missing from Go table", st)
			continue
		}
		if got.Retryable != want[0] || got.RetryAfter != want[1] {
			t.Errorf("status %d: go retryable=%v retry_after=%v, openapi %v", st, got.Retryable, got.RetryAfter, want)
		}
		if got.Level != "contract" && got.Level != "transport" {
			t.Errorf("status %d: level %q", st, got.Level)
		}
		if (got.Level == "transport") != contract.IsTransportLevel(st) {
			t.Errorf("status %d: IsTransportLevel disagrees", st)
		}
	}
	// every contract-level status is producible by the contract package, every transport one has a shape
	producible := map[int]bool{}
	note := func(err error) {
		var ce *contract.ContractError
		if errors.As(err, &ce) {
			producible[ce.Status] = true
		}
	}
	_, err := parse([]byte("nope"))
	note(err)
	_, err = parse(body("questions", qs("c", choiceQ(1))))
	note(err)
	note(contract.CheckBodySize(2, 1))
	for st, info := range table {
		if info.Level == "transport" {
			e, err := contract.TransportError(st, contract.TransportOptions{})
			if err != nil || e.Status != st {
				t.Errorf("transport %d: %v %v", st, e, err)
			}
		} else if !producible[st] {
			t.Errorf("contract-level status %d not producible", st)
		}
	}
	if len(producible) != 3 || !producible[400] || !producible[413] || !producible[422] {
		t.Errorf("producible = %v", producible)
	}
}
