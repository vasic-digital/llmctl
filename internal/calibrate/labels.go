package calibrate

import (
	"bytes"
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"strconv"
	"strings"
)

// Loaded is a parsed label file.
type Loaded struct {
	Format            string // "csv" | "json"
	Records           []Record
	SkippedVariant    int // JSON: permuted-variant records (not evaluation items)
	SkippedUnlabelled int // JSON: records with neither an expected answer nor a correct flag

	// Calibration provenance (FR-080): rows collected from a gateway that applied a calibration
	// profile carry a `calibration` marker and a CALIBRATED `confidence`.
	CalibratedRows      int  // rows carrying a calibration marker
	RawFromCalibrated   int  // of those, rows whose p came from a raw source (p_pred or confidence_raw)
	AssumedUncalibrated bool // calibrated rows were read via their `confidence` because the caller said so
}

// Options tune how a label file is read.
type Options struct {
	// AssumeUncalibrated lets rows that carry a calibration marker but no raw probability source be
	// read through their (calibrated) `confidence` anyway. It double-calibrates; the caller owns that.
	AssumeUncalibrated bool
}

// ErrCalibratedLabels is returned (wrapped) when a label file holds rows collected from CALIBRATED
// answers and only their calibrated confidence as the probability: fitting a calibration on already
// calibrated values double-calibrates.
var ErrCalibratedLabels = errors.New("the labels were collected from calibrated answers")

func calibratedRefusal(where string) error {
	return fmt.Errorf("%w: %s carries a calibration marker and only its calibrated confidence; fitting on it would calibrate an already-calibrated value. Supply the raw probability (a p_pred column/field = the winner's own probability, or confidence_raw), or pass --assume-uncalibrated to read the calibrated confidence anyway", ErrCalibratedLabels, where)
}

// Load picks the parser: a name ending in .json, or content starting with { or [, is JSON; anything
// else is CSV.
func Load(data []byte, name string) (*Loaded, error) { return LoadOpts(data, name, Options{}) }

// LoadOpts is Load with options.
func LoadOpts(data []byte, name string, o Options) (*Loaded, error) {
	t := bytes.TrimLeft(bytes.TrimPrefix(data, []byte("\xef\xbb\xbf")), " \t\r\n")
	if strings.HasSuffix(strings.ToLower(name), ".json") || (len(t) > 0 && (t[0] == '{' || t[0] == '[')) {
		return ParseJSONOpts(data, o)
	}
	return ParseCSVOpts(data, o)
}

func parseBoolish(s string) (val, ok bool) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "1", "true", "yes", "y", "t":
		return true, true
	case "0", "false", "no", "n", "f":
		return false, true
	}
	return false, false
}

func checkP(p float64) error {
	if math.IsNaN(p) || math.IsInf(p, 0) || p < 0 || p > 1 {
		return fmt.Errorf("p_pred %v is not a probability between 0 and 1", p)
	}
	return nil
}

var csvAliases = map[string]string{
	"p_pred": "p_pred", "p": "p_pred",
	// "confidence" is the answer's (possibly CALIBRATED) confidence; "confidence_raw" is the value
	// before calibration. p_pred > confidence_raw > confidence when several are present.
	"confidence": "p_conf", "confidence_raw": "p_raw", "calibration": "calibration",
	"id": "id", "type": "type", "expected": "expected", "predicted": "predicted",
	"correct": "correct", "well_formed": "well_formed", "variant": "variant",
	"options": "options", "option_count": "options", "scale": "options",
}

// ParseCSV reads the documented label CSV (docs/scripts/decide.md): a header row, then one row per
// evaluated answer. Required: p_pred and either correct or both expected and predicted. Optional:
// id, type, well_formed, variant, options. Unknown columns are ignored. Values are compared as text
// after trimming (so expected/predicted "true" == "true", "3" == "3").
func ParseCSV(data []byte) (*Loaded, error) { return ParseCSVOpts(data, Options{}) }

// ParseCSVOpts is ParseCSV with options. The probability of a row is its p_pred, else its
// confidence_raw, else its confidence. A row whose calibration cell is set and whose probability could
// only come from confidence is refused unless o.AssumeUncalibrated.
func ParseCSVOpts(data []byte, o Options) (*Loaded, error) {
	data = bytes.TrimPrefix(data, []byte("\xef\xbb\xbf"))
	if len(bytes.TrimSpace(data)) == 0 {
		return nil, errors.New("the label file is empty")
	}
	r := csv.NewReader(bytes.NewReader(data))
	r.TrimLeadingSpace = true
	r.FieldsPerRecord = -1
	header, err := r.Read()
	if err != nil {
		return nil, fmt.Errorf("line 1: %v", err)
	}
	col := map[string]int{}
	for i, h := range header {
		name, known := csvAliases[strings.ToLower(strings.TrimSpace(h))]
		if !known {
			continue
		}
		if _, dup := col[name]; dup {
			return nil, fmt.Errorf("line 1: duplicate column %q", name)
		}
		col[name] = i
	}
	_, hasPP := col["p_pred"]
	_, hasPR := col["p_raw"]
	_, hasPC := col["p_conf"]
	hasP := hasPP || hasPR || hasPC
	_, hasCorrect := col["correct"]
	_, hasExp := col["expected"]
	_, hasPred := col["predicted"]
	switch {
	case !hasP:
		return nil, errors.New("line 1: the header has no p_pred column (the probability the answer gave to its own prediction)")
	case !hasCorrect && !(hasExp && hasPred):
		return nil, errors.New("line 1: the header needs a correct column, or both expected and predicted")
	}
	out := &Loaded{Format: "csv"}
	for {
		row, err := r.Read()
		if err == io.EOF {
			break
		}
		line, _ := r.FieldPos(0)
		if err != nil {
			return nil, fmt.Errorf("line %d: %v", line, err)
		}
		if len(row) <= maxIdx(col) {
			return nil, fmt.Errorf("line %d: the row has %d fields, the header needs %d", line, len(row), maxIdx(col)+1)
		}
		get := func(k string) string {
			if i, ok := col[k]; ok {
				return strings.TrimSpace(row[i])
			}
			return ""
		}
		rec := Record{ID: get("id"), Type: get("type"), WellFormed: true}
		if v := get("variant"); v != "" && v != "orig" {
			out.SkippedVariant++
			continue
		}
		if v := get("well_formed"); v != "" {
			b, ok := parseBoolish(v)
			if !ok {
				return nil, fmt.Errorf("line %d: well_formed %q is not true/false", line, v)
			}
			rec.WellFormed = b
		}
		pcol, v := "p_pred", get("p_pred")
		if v == "" {
			pcol, v = "confidence_raw", get("p_raw")
		}
		if v == "" {
			pcol, v = "confidence", get("p_conf")
		}
		calRow := csvCalibrated(get("calibration"))
		if calRow {
			out.CalibratedRows++
		}
		if v != "" {
			p, err := strconv.ParseFloat(v, 64)
			if err != nil {
				return nil, fmt.Errorf("line %d: %s %q is not a number", line, pcol, v)
			}
			if err := checkP(p); err != nil {
				return nil, fmt.Errorf("line %d: %v", line, err)
			}
			rec.P, rec.HasP = p, true
			if calRow {
				if pcol == "confidence" && rec.WellFormed { // a malformed row never enters the fit: nothing to double-calibrate
					if !o.AssumeUncalibrated {
						return nil, calibratedRefusal(fmt.Sprintf("line %d", line))
					}
					out.AssumedUncalibrated = true
				} else {
					out.RawFromCalibrated++
				}
			}
		}
		if v := get("options"); v != "" {
			n, err := strconv.Atoi(v)
			if err != nil || n < 2 {
				return nil, fmt.Errorf("line %d: options %q is not a whole number >= 2", line, v)
			}
			rec.Options = n
		}
		if hasCorrect {
			v := get("correct")
			b, ok := parseBoolish(v)
			if !ok {
				return nil, fmt.Errorf("line %d: correct %q is not 0/1/true/false", line, v)
			}
			rec.CorrectSet, rec.Correct = true, b
		}
		if hasExp && hasPred {
			rec.HasExpected = get("expected") != ""
			rec.Expected = "s:" + get("expected")
			if p := get("predicted"); p != "" {
				rec.Predicted = "s:" + p
			}
		}
		out.Records = append(out.Records, rec)
	}
	if len(out.Records) == 0 {
		return nil, errors.New("the label file has a header but no data rows")
	}
	return out, nil
}

// csvCalibrated reports whether a calibration cell marks a calibrated answer.
func csvCalibrated(v string) bool {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "", "0", "false", "no", "none", "-", "null":
		return false
	}
	return true
}

func maxIdx(m map[string]int) int {
	mx := 0
	for _, i := range m {
		if i > mx {
			mx = i
		}
	}
	return mx
}

// jsonRecord is the part of a scripts/golden/run_golden.py record the calibration reads.
type jsonRecord struct {
	ID          string          `json:"id"`
	Type        string          `json:"type"`
	Expected    json.RawMessage `json:"expected"`
	Predicted   json.RawMessage `json:"predicted"`
	Correct     *bool           `json:"correct"`
	WellFormed  *bool           `json:"well_formed"`
	Variant     *string         `json:"variant"`
	PPred       *float64        `json:"p_pred"`
	Confidence  *float64        `json:"confidence"`
	ConfidenceR *float64        `json:"confidence_raw"`
	Calibration json.RawMessage `json:"calibration"`
	OptionCount *int            `json:"option_count"`
	Scale       *int            `json:"scale"`
}

// canon turns a JSON value into a tagged canonical string; ok is false for null/absent.
func canon(raw json.RawMessage) (string, bool) {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 || bytes.Equal(raw, []byte("null")) {
		return "", false
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var v any
	if dec.Decode(&v) != nil {
		return "", false
	}
	switch x := v.(type) {
	case bool:
		return "b:" + strconv.FormatBool(x), true
	case json.Number:
		f, err := x.Float64()
		if err != nil {
			return "n:" + x.String(), true
		}
		return "n:" + strconv.FormatFloat(f, 'g', -1, 64), true // 3 and 3.0 are equal, as in Python
	case string:
		return "s:" + x, true
	}
	var b bytes.Buffer
	_ = json.Compact(&b, raw)
	return "j:" + b.String(), true
}

// ParseJSON reads the result file written by scripts/golden/run_golden.py ({"records": [...]}) or a
// bare array of such records. Records with a variant other than "orig" are not evaluation items and
// are skipped (stats.py reports the permuted variants separately); records with neither an expected
// answer nor a correct flag are skipped and counted. A record without well_formed is read as
// well-formed (run_golden.py always writes it).
func ParseJSON(data []byte) (*Loaded, error) { return ParseJSONOpts(data, Options{}) }

// ParseJSONOpts is ParseJSON with options. The probability of a record is its p_pred, else its
// confidence_raw, else its confidence; a record carrying a calibration marker (an object, or the
// string "mixed") whose probability could only come from confidence is refused unless
// o.AssumeUncalibrated.
func ParseJSONOpts(data []byte, o Options) (*Loaded, error) {
	t := bytes.TrimLeft(bytes.TrimPrefix(data, []byte("\xef\xbb\xbf")), " \t\r\n")
	var raws []json.RawMessage
	switch {
	case len(t) > 0 && t[0] == '[':
		if err := json.Unmarshal(t, &raws); err != nil {
			return nil, fmt.Errorf("the label file is not valid JSON: %v", err)
		}
	case len(t) > 0 && t[0] == '{':
		var top map[string]json.RawMessage
		if err := json.Unmarshal(t, &top); err != nil {
			return nil, fmt.Errorf("the label file is not valid JSON: %v", err)
		}
		rec, ok := top["records"]
		if !ok {
			return nil, errors.New(`the JSON label file has no "records" array (expected the output of scripts/golden/run_golden.py or an array of records)`)
		}
		if err := json.Unmarshal(rec, &raws); err != nil {
			return nil, errors.New(`"records" must be an array of objects`)
		}
	default:
		return nil, errors.New("the label file is not a JSON object or array")
	}
	out := &Loaded{Format: "json"}
	for i, raw := range raws {
		var jr jsonRecord
		dec := json.NewDecoder(bytes.NewReader(raw))
		if err := dec.Decode(&jr); err != nil || bytes.TrimSpace(raw)[0] != '{' {
			return nil, fmt.Errorf("record %d is not a valid record object", i+1)
		}
		if jr.Variant != nil && *jr.Variant != "orig" {
			out.SkippedVariant++
			continue
		}
		rec := Record{ID: jr.ID, Type: jr.Type, WellFormed: jr.WellFormed == nil || *jr.WellFormed}
		pv, pcol := jr.PPred, "p_pred"
		if pv == nil {
			pv, pcol = jr.ConfidenceR, "confidence_raw"
		}
		if pv == nil {
			pv, pcol = jr.Confidence, "confidence"
		}
		calRec := jsonCalibrated(jr.Calibration)
		if calRec {
			out.CalibratedRows++
		}
		if pv != nil {
			if err := checkP(*pv); err != nil {
				return nil, fmt.Errorf("record %d (%s): %v", i+1, jr.ID, err)
			}
			rec.P, rec.HasP = *pv, true
			if calRec {
				if pcol == "confidence" && rec.WellFormed {
					if !o.AssumeUncalibrated {
						return nil, calibratedRefusal(fmt.Sprintf("record %d (%s)", i+1, jr.ID))
					}
					out.AssumedUncalibrated = true
				} else {
					out.RawFromCalibrated++
				}
			}
		}
		switch {
		case jr.OptionCount != nil:
			rec.Options = *jr.OptionCount
		case jr.Scale != nil:
			rec.Options = *jr.Scale
		}
		if e, ok := canon(jr.Expected); ok {
			rec.HasExpected, rec.Expected = true, e
			rec.Predicted, _ = canon(jr.Predicted)
		} else if jr.Correct != nil {
			rec.CorrectSet, rec.Correct = true, *jr.Correct
		} else {
			out.SkippedUnlabelled++
			continue
		}
		out.Records = append(out.Records, rec)
	}
	if len(out.Records) == 0 {
		return nil, errors.New("the label file has no labelled evaluation records")
	}
	return out, nil
}

// jsonCalibrated reports whether a record's calibration value marks a calibrated answer: an object
// or a non-empty string ("mixed"); null, absent and false do not.
func jsonCalibrated(raw json.RawMessage) bool {
	t := bytes.TrimSpace(raw)
	if len(t) == 0 || bytes.Equal(t, []byte("null")) || bytes.Equal(t, []byte("false")) || bytes.Equal(t, []byte(`""`)) {
		return false
	}
	return true
}
