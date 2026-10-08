package calibrate

import (
	"strings"
	"testing"
)

func TestParseCSVExpectedPredicted(t *testing.T) {
	csv := "id,type,expected,predicted,p_pred,options\n" +
		"a,choice,billing,billing,0.91,3\n" +
		"b,choice,legal,billing,0.55,3\n" +
		"c,noul,true,true,0.80,\n"
	l, err := ParseCSV([]byte(csv))
	if err != nil {
		t.Fatal(err)
	}
	if len(l.Records) != 3 {
		t.Fatalf("records = %d", len(l.Records))
	}
	if !l.Records[0].IsCorrect() || l.Records[1].IsCorrect() || !l.Records[2].IsCorrect() {
		t.Errorf("correctness wrong: %+v", l.Records)
	}
	if l.Records[0].Options != 3 || l.Records[0].P != 0.91 || !l.Records[0].HasP {
		t.Errorf("record 0 = %+v", l.Records[0])
	}
	if got := len(Pairs(l.Records)); got != 3 {
		t.Errorf("pairs = %d", got)
	}
}

func TestParseCSVCorrectColumn(t *testing.T) {
	l, err := ParseCSV([]byte("p_pred,correct\n0.9,1\n0.6,0\n0.7,true\n0.4,False\n"))
	if err != nil {
		t.Fatal(err)
	}
	pr := Pairs(l.Records)
	want := []int{1, 0, 1, 0}
	for i, p := range pr {
		if p.Y != want[i] {
			t.Errorf("pair %d y=%d want %d", i, p.Y, want[i])
		}
	}
	if AccuracyAll(l.Records).BaselineAvailable {
		t.Error("with only a correct column there are no expected labels: the baseline must be reported unavailable, not invented")
	}
}

func TestParseCSVErrorsNameTheLine(t *testing.T) {
	cases := map[string]string{
		"p_pred,correct\n0.9,1\n1.2,0\n":    "line 3",
		"p_pred,correct\n0.9,maybe\n":       "line 2",
		"p_pred,correct\nabc,1\n":           "line 2",
		"id,expected\nx,y\n":                "p_pred",
		"p_pred,id\n0.5,x\n":                "correct",
		"p_pred,correct,correct\n0.5,1,1\n": "duplicate column",
		"p_pred,correct\n0.5\n":             "line 2",
		"":                                  "empty",
		"p_pred,expected,predicted,well_formed\n0.5,a,a,huh\n": "well_formed",
	}
	for in, want := range cases {
		_, err := ParseCSV([]byte(in))
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("ParseCSV(%q) err = %v, want it to mention %q", in, err, want)
		}
	}
}

func TestParseCSVMalformedRowNeedsNoConfidence(t *testing.T) {
	l, err := ParseCSV([]byte("p_pred,expected,predicted,well_formed\n,a,,false\n0.8,a,a,true\n"))
	if err != nil {
		t.Fatal(err)
	}
	if l.Records[0].WellFormed || l.Records[0].IsCorrect() {
		t.Error("a malformed row is wrong")
	}
	if len(Pairs(l.Records)) != 1 {
		t.Error("a malformed row has no confidence and must not enter the calibration pairs")
	}
	if AccuracyAll(l.Records).N != 2 {
		t.Error("a malformed row still counts in accuracy")
	}
}

const goldenJSON = `{"meta":{"x":1},"records":[
 {"id":"q1","type":"choice","expected":"a","predicted":"a","well_formed":true,"variant":"orig","option_count":3,"p_pred":0.9},
 {"id":"q1~p","type":"choice","expected":"a","predicted":"b","well_formed":true,"variant":"perm","option_count":3,"p_pred":0.7},
 {"id":"q2","type":"noul","expected":true,"predicted":true,"well_formed":true,"variant":"orig","p_pred":0.8},
 {"id":"q3","type":"score","expected":3,"predicted":3.0,"well_formed":true,"variant":"orig","scale":5,"p_pred":0.6},
 {"id":"q4","type":"noul","expected":null,"predicted":false,"well_formed":true,"variant":"orig","p_pred":0.5},
 {"id":"q5","type":"noul","expected":false,"predicted":null,"well_formed":false,"variant":"orig","p_pred":null}
]}`

func TestParseGoldenRunnerJSON(t *testing.T) {
	l, err := ParseJSON([]byte(goldenJSON))
	if err != nil {
		t.Fatal(err)
	}
	// the permuted variant and the unlabelled item are not evaluation records
	if len(l.Records) != 4 || l.SkippedVariant != 1 || l.SkippedUnlabelled != 1 {
		t.Fatalf("records=%d variant-skipped=%d unlabelled=%d", len(l.Records), l.SkippedVariant, l.SkippedUnlabelled)
	}
	for _, r := range l.Records[:3] {
		if !r.IsCorrect() {
			t.Errorf("%s should be correct (3 == 3.0 as in Python, true == true)", r.ID)
		}
	}
	if l.Records[2].Options != 5 {
		t.Errorf("scale not read as options: %+v", l.Records[2])
	}
	if l.Records[3].IsCorrect() || l.Records[3].HasP {
		t.Errorf("malformed record must be wrong with no confidence: %+v", l.Records[3])
	}
	if got := len(Pairs(l.Records)); got != 3 {
		t.Errorf("pairs = %d, want 3", got)
	}
}

func TestParseJSONBareArrayAndErrors(t *testing.T) {
	if _, err := ParseJSON([]byte(`[{"id":"a","expected":"x","predicted":"x","well_formed":true,"p_pred":0.5}]`)); err != nil {
		t.Fatal(err)
	}
	for _, in := range []string{`{"records":5}`, `7`, `{"nope":1}`, `[1]`, `{"records":[{"p_pred":2,"expected":"a","predicted":"a","well_formed":true}]}`} {
		if _, err := ParseJSON([]byte(in)); err == nil {
			t.Errorf("ParseJSON(%s) accepted", in)
		}
	}
}

func TestLoadSniffsFormat(t *testing.T) {
	if l, err := Load([]byte(goldenJSON), "x.dat"); err != nil || len(l.Records) != 4 {
		t.Errorf("json by content: %v", err)
	}
	if l, err := Load([]byte("p_pred,correct\n0.9,1\n"), "labels.csv"); err != nil || len(l.Records) != 1 {
		t.Errorf("csv: %v", err)
	}
}
