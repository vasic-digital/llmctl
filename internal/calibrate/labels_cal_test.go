package calibrate

import (
	"errors"
	"strings"
	"testing"
)

// Rows collected from a CALIBRATED gateway carry a `calibration` object; fitting a new calibration on
// their `confidence` would calibrate an already-calibrated value. The loader refuses such input unless
// a raw source exists in the row (p_pred = the winner's own probability, or confidence_raw) or the
// caller states --assume-uncalibrated.

func TestCSVCalibratedConfidenceOnlyIsRefused(t *testing.T) {
	in := "confidence,correct,calibration\n0.9,1,temperature\n0.6,0,temperature\n"
	_, err := ParseCSV([]byte(in))
	if err == nil || !errors.Is(err, ErrCalibratedLabels) {
		t.Fatalf("want ErrCalibratedLabels, got %v", err)
	}
	for _, want := range []string{"calibrat", "confidence_raw", "--assume-uncalibrated"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("message lacks %q: %v", want, err)
		}
	}
	l, err := ParseCSVOpts([]byte(in), Options{AssumeUncalibrated: true})
	if err != nil || len(l.Records) != 2 || l.Records[0].P != 0.9 {
		t.Fatalf("--assume-uncalibrated reads the confidence as is: %v %+v", err, l)
	}
	if l.CalibratedRows != 2 || l.AssumedUncalibrated != true {
		t.Fatalf("the assumption is recorded: %+v", l)
	}
}

func TestCSVConfidenceRawIsPreferredAndAcceptsCalibratedRows(t *testing.T) {
	in := "confidence,confidence_raw,correct,calibration\n0.9,0.55,1,temperature\n0.6,0.51,0,temperature\n"
	l, err := ParseCSV([]byte(in))
	if err != nil {
		t.Fatal(err)
	}
	if l.Records[0].P != 0.55 || l.Records[1].P != 0.51 {
		t.Fatalf("the raw column feeds p_pred, never the calibrated confidence: %+v", l.Records)
	}
	if l.CalibratedRows != 2 || l.RawFromCalibrated != 2 {
		t.Fatalf("counts %+v", l)
	}
}

func TestCSVExplicitPPredWinsOverConfidenceAndNeedsNoFlag(t *testing.T) {
	in := "p_pred,confidence,correct,calibration\n0.7,0.9,1,temperature\n"
	l, err := ParseCSV([]byte(in))
	if err != nil || l.Records[0].P != 0.7 {
		t.Fatalf("p_pred is the raw winner probability: %v %+v", err, l)
	}
}

func TestCSVUncalibratedConfidenceStillWorks(t *testing.T) {
	l, err := ParseCSV([]byte("confidence,correct\n0.9,1\n"))
	if err != nil || l.Records[0].P != 0.9 || l.CalibratedRows != 0 {
		t.Fatalf("%v %+v", err, l)
	}
	// an EMPTY calibration cell is not a calibration
	l, err = ParseCSV([]byte("confidence,correct,calibration\n0.9,1,\n"))
	if err != nil || l.CalibratedRows != 0 {
		t.Fatalf("%v %+v", err, l)
	}
}

const jsonCal = `{"records":[
 {"id":"a","type":"choice","expected":"x","predicted":"x","confidence":0.9,"confidence_raw":0.5,"p_pred":0.7,"calibration":{"method":"temperature","n":240,"profile_id":"p"}},
 {"id":"b","type":"choice","expected":"x","predicted":"y","confidence":0.8,"confidence_raw":0.4,"p_pred":0.6,"calibration":{"method":"temperature","n":240,"profile_id":"p"}}]}`

func TestJSONCalibratedRowsWithRawSourceAreAccepted(t *testing.T) {
	l, err := ParseJSON([]byte(jsonCal))
	if err != nil {
		t.Fatal(err)
	}
	if l.Records[0].P != 0.7 || l.CalibratedRows != 2 || l.RawFromCalibrated != 2 {
		t.Fatalf("p_pred (raw winner probability) is used: %+v", l)
	}
	// without p_pred the raw confidence is the source
	noP := strings.ReplaceAll(jsonCal, `"p_pred":0.7,`, ``)
	noP = strings.ReplaceAll(noP, `"p_pred":0.6,`, ``)
	l, err = ParseJSON([]byte(noP))
	if err != nil || l.Records[0].P != 0.5 {
		t.Fatalf("confidence_raw is read when p_pred is absent: %v %+v", err, l)
	}
}

func TestJSONCalibratedWithoutAnyRawSourceIsRefused(t *testing.T) {
	in := `{"records":[{"id":"a","type":"choice","expected":"x","predicted":"x","confidence":0.9,"calibration":{"method":"platt","n":300,"profile_id":"p"}}]}`
	if _, err := ParseJSON([]byte(in)); !errors.Is(err, ErrCalibratedLabels) {
		t.Fatalf("want ErrCalibratedLabels, got %v", err)
	}
	l, err := ParseJSONOpts([]byte(in), Options{AssumeUncalibrated: true})
	if err != nil || l.Records[0].P != 0.9 || !l.AssumedUncalibrated {
		t.Fatalf("%v %+v", err, l)
	}
	// "mixed" (a permuted run whose calls disagreed) counts as carrying a calibration
	mixed := strings.Replace(in, `{"method":"platt","n":300,"profile_id":"p"}`, `"mixed"`, 1)
	if _, err := ParseJSON([]byte(mixed)); !errors.Is(err, ErrCalibratedLabels) {
		t.Fatalf("mixed: %v", err)
	}
	// a JSON file with no confidence at all and a calibration object has nothing to double-calibrate
	none := `{"records":[{"id":"a","type":"choice","expected":"x","predicted":"x","calibration":{"method":"platt","n":300,"profile_id":"p"}}]}`
	if _, err := ParseJSON([]byte(none)); err != nil {
		t.Fatalf("no confidence column, nothing to refuse: %v", err)
	}
}

func TestLoadRoutesTheOptions(t *testing.T) {
	in := "confidence,correct,calibration\n0.9,1,x\n"
	if _, err := Load([]byte(in), "l.csv"); !errors.Is(err, ErrCalibratedLabels) {
		t.Fatal(err)
	}
	if _, err := LoadOpts([]byte(in), "l.csv", Options{AssumeUncalibrated: true}); err != nil {
		t.Fatal(err)
	}
}

func TestMalformedCalibratedRowIsNotARefusalReason(t *testing.T) {
	in := `{"records":[
 {"id":"bad","type":"choice","expected":"x","predicted":null,"well_formed":false,"confidence":0.9,"calibration":{"method":"platt","n":300,"profile_id":"p"}},
 {"id":"ok","type":"choice","expected":"x","predicted":"x","p_pred":0.7}]}`
	if _, err := ParseJSON([]byte(in)); err != nil {
		t.Fatalf("a malformed row never enters the fit, so it cannot double-calibrate: %v", err)
	}
}
