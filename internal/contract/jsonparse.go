package contract

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"math"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

// An order-preserving JSON tree. encoding/json's map decoding loses key order, which the contract
// needs (option letters follow the criteria order) and cannot detect duplicate keys, so the body is
// read with json.Decoder.Token (strict RFC 8259 syntax, UseNumber) into this tree.

type vkind uint8

const (
	vNull vkind = iota
	vBool
	vNumber
	vString
	vArray
	vObject
)

type member struct {
	key string
	val *value
}

type value struct {
	kind vkind
	b    bool
	s    string // string content, or the number's literal text
	arr  []*value
	obj  []member
}

var errJSON = errors.New("contract: invalid JSON")

// parseJSON reads exactly one JSON value. It rejects: invalid UTF-8, syntax errors, trailing data,
// a duplicate object key anywhere, a number that is not a finite double (NaN/Infinity are not JSON;
// 1e999 overflows), and nesting deeper than MaxJSONDepth.
func parseJSON(body []byte) (*value, error) {
	if !utf8.Valid(body) {
		return nil, errJSON
	}
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.UseNumber()
	v, err := readValue(dec, 0)
	if err != nil {
		return nil, errJSON
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, errJSON
	}
	return v, nil
}

func readValue(dec *json.Decoder, depth int) (*value, error) {
	tok, err := dec.Token()
	if err != nil {
		return nil, err
	}
	switch t := tok.(type) {
	case nil:
		return &value{kind: vNull}, nil
	case bool:
		return &value{kind: vBool, b: t}, nil
	case string:
		return &value{kind: vString, s: t}, nil
	case json.Number:
		txt := string(t)
		if strings.ContainsAny(txt, ".eE") {
			f, err := strconv.ParseFloat(txt, 64)
			if err != nil || math.IsInf(f, 0) || math.IsNaN(f) {
				return nil, errJSON
			}
		}
		return &value{kind: vNumber, s: txt}, nil
	case json.Delim:
		if depth >= MaxJSONDepth {
			return nil, errJSON
		}
		if t == '[' {
			v := &value{kind: vArray}
			for dec.More() {
				e, err := readValue(dec, depth+1)
				if err != nil {
					return nil, err
				}
				v.arr = append(v.arr, e)
			}
			if _, err := dec.Token(); err != nil { // ']'
				return nil, err
			}
			return v, nil
		}
		v := &value{kind: vObject}
		seen := map[string]struct{}{}
		for dec.More() {
			kt, err := dec.Token()
			if err != nil {
				return nil, err
			}
			k, ok := kt.(string)
			if !ok {
				return nil, errJSON
			}
			if _, dup := seen[k]; dup {
				return nil, errJSON
			}
			seen[k] = struct{}{}
			e, err := readValue(dec, depth+1)
			if err != nil {
				return nil, err
			}
			v.obj = append(v.obj, member{k, e})
		}
		if _, err := dec.Token(); err != nil { // '}'
			return nil, err
		}
		return v, nil
	}
	return nil, errJSON
}

func (v *value) get(key string) (*value, bool) {
	for _, m := range v.obj {
		if m.key == key {
			return m.val, true
		}
	}
	return nil, false
}

// toAny converts to plain Go values (objects lose order); used only to hand the model field to Resolve.
func (v *value) toAny() any {
	switch v.kind {
	case vBool:
		return v.b
	case vNumber:
		return json.Number(v.s)
	case vString:
		return v.s
	case vArray:
		a := make([]any, len(v.arr))
		for i, e := range v.arr {
			a[i] = e.toAny()
		}
		return a
	case vObject:
		m := make(map[string]any, len(v.obj))
		for _, e := range v.obj {
			m[e.key] = e.val.toAny()
		}
		return m
	}
	return nil
}

// isDesc reports whether v is an acceptable description: null, string, object or array.
func isDesc(v *value) bool {
	return v == nil || v.kind == vNull || v.kind == vString || v.kind == vArray || v.kind == vObject
}

// text is the contract's text form of a state/instructions/description value: a string as is,
// null as "", objects and arrays as canonical JSON (sorted keys, compact, non-ASCII kept).
func (v *value) text() string {
	if v == nil || v.kind == vNull {
		return ""
	}
	if v.kind == vString {
		return v.s
	}
	var sb strings.Builder
	v.write(&sb, true)
	return sb.String()
}

// raw is the value as compact JSON in its original key order (legend values are echoed this way).
func (v *value) raw() []byte {
	if v == nil {
		return []byte("null")
	}
	var sb strings.Builder
	v.write(&sb, false)
	return []byte(sb.String())
}

func (v *value) write(sb *strings.Builder, sorted bool) {
	switch v.kind {
	case vNull:
		sb.WriteString("null")
	case vBool:
		sb.WriteString(strconv.FormatBool(v.b))
	case vNumber:
		if sorted {
			sb.WriteString(pyNumber(v.s))
		} else {
			sb.WriteString(v.s)
		}
	case vString:
		writeString(sb, v.s)
	case vArray:
		sb.WriteByte('[')
		for i, e := range v.arr {
			if i > 0 {
				sb.WriteByte(',')
			}
			e.write(sb, sorted)
		}
		sb.WriteByte(']')
	case vObject:
		ms := v.obj
		if sorted {
			ms = append([]member(nil), ms...)
			sort.Slice(ms, func(i, j int) bool { return ms[i].key < ms[j].key }) // UTF-8 byte order == code point order
		}
		sb.WriteByte('{')
		for i, m := range ms {
			if i > 0 {
				sb.WriteByte(',')
			}
			writeString(sb, m.key)
			sb.WriteByte(':')
			m.val.write(sb, sorted)
		}
		sb.WriteByte('}')
	}
}

// writeString mirrors Python's json.dumps(ensure_ascii=False): only ", \ and control characters are
// escaped (\b \f \n \r \t short forms, others \u00xx); everything else, including <, >, & and U+2028, is kept.
func writeString(sb *strings.Builder, s string) {
	const hex = "0123456789abcdef"
	sb.WriteByte('"')
	for _, r := range s {
		switch {
		case r == '"':
			sb.WriteString(`\"`)
		case r == '\\':
			sb.WriteString(`\\`)
		case r == '\n':
			sb.WriteString(`\n`)
		case r == '\r':
			sb.WriteString(`\r`)
		case r == '\t':
			sb.WriteString(`\t`)
		case r == '\b':
			sb.WriteString(`\b`)
		case r == '\f':
			sb.WriteString(`\f`)
		case r < 0x20:
			sb.WriteString(`\u00`)
			sb.WriteByte(hex[r>>4])
			sb.WriteByte(hex[r&15])
		default:
			sb.WriteRune(r)
		}
	}
	sb.WriteByte('"')
}

// pyNumber renders a JSON number literal the way Python's json.dumps renders the parsed value:
// integers exactly ("-0" -> "0"), everything else as float repr (1e2 -> 100.0, 1e16 -> 1e+16).
func pyNumber(lit string) string {
	if !strings.ContainsAny(lit, ".eE") {
		if lit == "-0" {
			return "0"
		}
		return lit
	}
	f, _ := strconv.ParseFloat(lit, 64)
	return pyFloatRepr(f)
}

// pyFloatRepr is Python's repr(float): shortest round-trip digits; exponent form when the decimal
// exponent is < -4 or >= 16; fixed form always carries a fractional part.
func pyFloatRepr(f float64) string {
	if f == 0 {
		if math.Signbit(f) {
			return "-0.0"
		}
		return "0.0"
	}
	s := strconv.FormatFloat(f, 'e', -1, 64) // d.ddde±XX
	neg := strings.HasPrefix(s, "-")
	s = strings.TrimPrefix(s, "-")
	mant, expS, _ := strings.Cut(s, "e")
	exp, _ := strconv.Atoi(expS)
	digits := strings.Replace(mant, ".", "", 1)
	decpt := exp + 1
	var out string
	switch {
	case decpt <= -4 || decpt > 16:
		out = digits[:1]
		if len(digits) > 1 {
			out += "." + digits[1:]
		}
		sign := "+"
		if exp < 0 {
			sign, exp = "-", -exp
		}
		e := strconv.Itoa(exp)
		if len(e) < 2 {
			e = "0" + e
		}
		out += "e" + sign + e
	case decpt <= 0:
		out = "0." + strings.Repeat("0", -decpt) + digits
	case decpt >= len(digits):
		out = digits + strings.Repeat("0", decpt-len(digits)) + ".0"
	default:
		out = digits[:decpt] + "." + digits[decpt:]
	}
	if neg {
		out = "-" + out
	}
	return out
}
