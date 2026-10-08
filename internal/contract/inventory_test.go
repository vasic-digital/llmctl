package contract_test

import (
	"encoding/csv"
	"os"
	"strconv"
	"strings"
	"testing"

	"github.com/vasic-digital/llmctl/internal/contract"
)

const inventoryPath = "../../specs/009-jev-decision-models/contracts/endpoint-inventory.tsv"

func parseOutcomes(bs ...[]byte) func() []outcome {
	return func() []outcome {
		var out []outcome
		for _, b := range bs {
			_, err := parse(b)
			out = append(out, outcomeOf(err))
		}
		return out
	}
}

func ct(vals ...string) func() []outcome {
	return func() []outcome {
		var out []outcome
		for _, v := range vals {
			out = append(out, outcomeOf(contract.CheckContentType(v)))
		}
		return out
	}
}

func repeat(s string, n int) string { return strings.Repeat(s, n) }

// inventoryCases are the rows decided by pure contract logic; each returns one outcome per sub-scenario.
var inventoryCases = map[string]func() []outcome{
	"EP-001": parseOutcomes(body()),
	"EP-002": parseOutcomes(body("questions", qs("c", choiceQ(2)))),
	"EP-003": parseOutcomes(body("questions", qs("c", choiceQ(20)))),
	"EP-004": parseOutcomes(body("questions", qs("s", scoreQ(2))), body("questions", qs("s", scoreQ(10)))),
	"EP-005": parseOutcomes(body("questions", `{"a":{"type":"noul"},"b":`+choiceQ(3)+`,"c":{"type":"score","criteria":["a","b"]}}`)),
	"EP-006": parseOutcomes(body("state", `"t"`), body("state", `{"o":1}`), body("state", `[1]`)),
	"EP-007": parseOutcomes(body("model", `"jev-latest"`)),
	"EP-008": parseOutcomes(body("state", js(repeat("x", 9000)))),
	"EP-008b": func() []outcome {
		l := contract.DefaultLimits()
		l.Truncate = true
		_, err := parseL(body("state", js(repeat("x", 9000))), l)
		return []outcome{outcomeOf(err)}
	},
	"EP-011": parseOutcomes([]byte("<<not json>>")),
	"EP-012": parseOutcomes([]byte("[]"), []byte(`"s"`), []byte("3")),
	"EP-013": ct("", "text/plain"),
	"EP-014": func() []outcome { return []outcome{outcomeOf(contract.CheckBodySize(262145, 262144))} },
	"EP-015": parseOutcomes(body("questions", qs("c", choiceQ(1))), body("questions", qs("c", choiceQ(21))),
		body("questions", qs("s", `{"type":"score","criteria":["a"]}`)), body("questions", qs("s", scoreQ(11)))),
	"EP-015b": func() []outcome {
		_, err := parseL(body("questions", qs("c", choiceQ(256))), bigLimit)
		return []outcome{outcomeOf(err)}
	},
	"EP-016": parseOutcomes(body("model", `"nonexistent"`)),
	"EP-017": parseOutcomes(body("state", js(repeat("x", 4000)), "questions", qs("q", `{"type":"noul","instructions":"`+repeat("i", 5000)+`"}`))),
	"EP-018": parseOutcomes(body("extra", "1"), body("questions", qs("q", `{"type":"noul","zzz":1}`))),
}

// inventorySkipped lists rows that cannot be decided by pure contract logic, each with its reason (never silent).
var inventorySkipped = map[string]string{
	"EP-009": "authentication is a transport/keyring concern", "EP-010": "authentication is a transport/keyring concern",
	"EP-016b": "needs live instance registry", "EP-019": "needs live per-source auth throttle",
	"EP-020": "needs live slot/queue state", "EP-021": "needs live drain state",
	"EP-022": "needs a live backend readout (the pure part is internal/readout and TestReadoutFailedMapping)",
	"EP-023": "needs a live backend process", "EP-024": "needs a live socket",
	"EP-025": "method routing is transport", "EP-026": "needs live sockets",
	"EP-030": "needs live listing", "EP-031": "transport", "EP-032": "transport", "EP-033": "transport",
	"EP-034": "needs live registry", "EP-040": "transport", "EP-041": "transport", "EP-045": "transport",
	"EP-046": "transport", "EP-050": "needs live metrics endpoint", "EP-051": "transport", "EP-052": "transport",
	"EP-060": "routing is transport", "EP-061": "transport", "EP-070": "needs live TLS socket", "EP-071": "needs a second network location",
}

func readInventory(t *testing.T) []map[string]string {
	t.Helper()
	f, err := os.Open(inventoryPath)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	r := csv.NewReader(f)
	r.Comma = '\t'
	r.LazyQuotes = true
	r.FieldsPerRecord = -1
	recs, err := r.ReadAll()
	if err != nil {
		t.Fatal(err)
	}
	head := recs[0]
	var rows []map[string]string
	for _, rec := range recs[1:] {
		m := map[string]string{}
		for i, h := range head {
			if i < len(rec) {
				m[h] = rec[i]
			}
		}
		rows = append(rows, m)
	}
	return rows
}

func TestInventoryEveryRowDecidedOrSkippedWithReason(t *testing.T) {
	rows := readInventory(t)
	ids := map[string]bool{}
	for _, r := range rows {
		ids[r["case_id"]] = true
		_, decided := inventoryCases[r["case_id"]]
		_, skipped := inventorySkipped[r["case_id"]]
		if !decided && !skipped {
			t.Errorf("inventory row %s has neither a contract case nor a skip reason", r["case_id"])
		}
		if decided && skipped {
			t.Errorf("%s is both decided and skipped", r["case_id"])
		}
	}
	if len(ids) < 40 {
		t.Fatalf("only %d inventory rows read", len(ids))
	}
	for id := range inventoryCases {
		if !ids[id] {
			t.Errorf("stale case id %s", id)
		}
	}
	for id, reason := range inventorySkipped {
		if !ids[id] {
			t.Errorf("stale skip id %s", id)
		}
		if strings.TrimSpace(reason) == "" {
			t.Errorf("skip %s has no reason", id)
		}
	}
}

func TestInventoryRows(t *testing.T) {
	decided := 0
	for _, r := range readInventory(t) {
		id := r["case_id"]
		t.Run(id, func(t *testing.T) {
			if reason, ok := inventorySkipped[id]; ok {
				t.Skipf("%s: %s", id, reason)
			}
			status, err := strconv.Atoi(r["expected_status"])
			if err != nil {
				t.Fatalf("expected_status %q", r["expected_status"])
			}
			want := outcome{status, ""}
			if r["expected_error_type"] != "-" {
				want.Type = r["expected_error_type"]
			}
			outs := inventoryCases[id]()
			if len(outs) == 0 {
				t.Fatal("no outcomes")
			}
			for i, got := range outs {
				if got != want {
					t.Errorf("sub-scenario %d (%s): got %v want %v", i, r["scenario"], got, want)
				}
			}
			decided++
		})
	}
	if decided < 15 {
		t.Fatalf("only %d rows decided", decided)
	}
}
