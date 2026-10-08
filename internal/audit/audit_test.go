package audit_test

import (
	"bufio"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/internal/audit"
)

var testKey = func() []byte {
	k := make([]byte, 32)
	for i := range k {
		k[i] = byte(i)
	}
	return k
}()

const secretState = "SUPER SECRET STATE TEXT 12345"

func mustHash(t testing.TB, key []byte, s string) string {
	t.Helper()
	h, err := audit.StateHash(key, s)
	if err != nil {
		t.Fatal(err)
	}
	return h
}

func fields(t testing.TB, mod func(*audit.Fields)) audit.Fields {
	t.Helper()
	h := mustHash(t, testKey, secretState)
	prof := "decide-tiny"
	f := audit.Fields{
		RequestID: "0123456789abcdef", Method: "POST", Path: "/v1/systemone", Status: 200,
		Millis: 12.5, Bytes: 321, AuthResult: "ok", ClientIP: "192.0.2.7", Profile: &prof,
		TLSVersion: "TLSv1.3", StateHash: &h, Now: time.Unix(1_700_000_000, 0),
	}
	if mod != nil {
		mod(&f)
	}
	return f
}

func rec(t testing.TB, mod func(*audit.Fields)) audit.Record {
	return audit.NewRecord(fields(t, mod))
}

func decode(t testing.TB, line string) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal([]byte(line), &m); err != nil {
		t.Fatalf("not json: %v: %q", err, line)
	}
	return m
}

func TestStateHashIsHMACSHA256Hex(t *testing.T) {
	h := mustHash(t, testKey, secretState)
	mac := hmac.New(sha256.New, testKey)
	mac.Write([]byte(secretState))
	if want := hex.EncodeToString(mac.Sum(nil)); h != want {
		t.Fatalf("got %s want %s", h, want)
	}
	if !regexp.MustCompile(`^[0-9a-f]{64}$`).MatchString(h) {
		t.Fatal("not 64 hex")
	}
}

func TestStateHashIsKeyed(t *testing.T) {
	other := []byte(strings.Repeat("k", 32))
	if mustHash(t, testKey, secretState) == mustHash(t, other, secretState) {
		t.Fatal("different keys gave same hash")
	}
	plain := sha256.Sum256([]byte(secretState))
	if mustHash(t, testKey, secretState) == hex.EncodeToString(plain[:]) {
		t.Fatal("hash is unkeyed sha256")
	}
}

func TestStateHashStableAndDistinct(t *testing.T) {
	if mustHash(t, testKey, secretState) != mustHash(t, testKey, secretState) {
		t.Fatal("unstable")
	}
	if mustHash(t, testKey, secretState) == mustHash(t, testKey, secretState+"x") {
		t.Fatal("not distinct")
	}
}

func TestStateHashRejectsShortKey(t *testing.T) {
	for _, k := range [][]byte{nil, {}, []byte("short"), make([]byte, 15)} {
		if _, err := audit.StateHash(k, secretState); err == nil {
			t.Fatalf("accepted key len %d", len(k))
		}
	}
	if _, err := audit.StateHash(make([]byte, 16), secretState); err != nil {
		t.Fatalf("rejected 16-byte key: %v", err)
	}
}

func TestRecordFieldsExact(t *testing.T) {
	r := rec(t, nil)
	m := decode(t, audit.ToJSONLine(r))
	want := []string{"ts", "request_id", "method", "path", "status", "ms", "bytes", "auth", "client_ip", "profile", "tls", "state_hash"}
	if len(m) != len(want) {
		t.Fatalf("keys %v", m)
	}
	for _, k := range want {
		if _, ok := m[k]; !ok {
			t.Fatalf("missing %s", k)
		}
	}
	if m["ts"] != "2023-11-14T22:13:20Z" || m["status"].(float64) != 200 || m["bytes"].(float64) != 321 {
		t.Fatalf("values %v", m)
	}
}

// Fields must have no member that could carry state, key or question text.
func TestFieldsHaveNoTextCarryingMember(t *testing.T) {
	ty := reflect.TypeOf(audit.Fields{})
	allowed := map[string]bool{"RequestID": true, "Method": true, "Path": true, "Status": true, "Millis": true, "Bytes": true,
		"AuthResult": true, "ClientIP": true, "Profile": true, "TLSVersion": true, "StateHash": true, "Now": true}
	for i := 0; i < ty.NumField(); i++ {
		n := ty.Field(i).Name
		if !allowed[n] {
			t.Errorf("unexpected Fields member %q", n)
		}
		low := strings.ToLower(n)
		for _, bad := range []string{"state", "key", "question", "option", "body", "text"} {
			if strings.Contains(low, bad) && n != "StateHash" {
				t.Errorf("Fields member %q looks text/key carrying", n)
			}
		}
	}
	if ty.NumField() != len(allowed) {
		t.Errorf("field count %d != %d", ty.NumField(), len(allowed))
	}
}

// Leak test: key, state and question text must never appear in any produced line.
func TestLeakKeyStateQuestionNeverAppear(t *testing.T) {
	question := "Which colour should the wizard hat be?"
	paths := []string{
		"/v1/systemone?key=" + hex.EncodeToString(testKey) + "&state=" + secretState + "&q=" + question,
		"/v1/systemone#" + secretState,
		"/v1/" + "SUPER SECRET STATE TEXT 12345"[:5],
	}
	profs := []string{secretState, question, "ok-profile"}
	for _, p := range paths {
		for _, pr := range profs {
			pr := pr
			line := audit.ToJSONLine(rec(t, func(f *audit.Fields) {
				f.Path = p
				f.Profile = &pr
				f.RequestID = secretState
				f.AuthResult = hex.EncodeToString(testKey)
				f.Method = question
				f.TLSVersion = secretState
				f.ClientIP = question
				sh := secretState
				f.StateHash = &sh
			}))
			for _, leak := range []string{secretState, hex.EncodeToString(testKey), question, "SECRET", "wizard"} {
				if strings.Contains(line, leak) {
					t.Fatalf("leaked %q in %s", leak, line)
				}
			}
		}
	}
	// the genuine hash is present, the plaintext is not
	line := audit.ToJSONLine(rec(t, nil))
	if !strings.Contains(line, mustHash(t, testKey, secretState)) || strings.Contains(line, secretState) {
		t.Fatalf("hash/plaintext wrong: %s", line)
	}
}

func TestPathQueryAndFragmentStripped(t *testing.T) {
	m := decode(t, audit.ToJSONLine(rec(t, func(f *audit.Fields) { f.Path = "/a/b?x=1#frag" })))
	if m["path"] != "/a/b" {
		t.Fatalf("%v", m["path"])
	}
	m = decode(t, audit.ToJSONLine(rec(t, func(f *audit.Fields) { f.Path = "/a#frag?x" })))
	if m["path"] != "/a" {
		t.Fatalf("%v", m["path"])
	}
}

func TestPathCappedAt256(t *testing.T) {
	m := decode(t, audit.ToJSONLine(rec(t, func(f *audit.Fields) { f.Path = "/" + strings.Repeat("a", 5000) })))
	if n := len([]rune(m["path"].(string))); n != 256 {
		t.Fatalf("len %d", n)
	}
	m = decode(t, audit.ToJSONLine(rec(t, func(f *audit.Fields) { f.Path = strings.Repeat("é", 1000) })))
	if n := len([]rune(m["path"].(string))); n != 256 {
		t.Fatalf("rune len %d", n)
	}
}

func TestSingleLineJSONAndControlChars(t *testing.T) {
	line := audit.ToJSONLine(rec(t, func(f *audit.Fields) { f.Path = "/v1/sys\r\ntemone\x00\x1b[31m x" }))
	if strings.ContainsAny(line, "\n\r") {
		t.Fatalf("newline in %q", line)
	}
	p := decode(t, line)["path"].(string)
	for _, c := range p {
		if c < ' ' || c == 0x7f || c == 0x2028 {
			t.Fatalf("control char survived: %q", p)
		}
	}
}

func TestOutputIsASCIIAndKeysSorted(t *testing.T) {
	line := audit.ToJSONLine(rec(t, func(f *audit.Fields) { f.Path = "/ü<>&\U0001F600" }))
	for i := 0; i < len(line); i++ {
		if line[i] > 0x7e || (line[i] < 0x20) {
			t.Fatalf("non-ascii byte in %q", line)
		}
	}
	if !strings.Contains(line, `<>&`) {
		t.Fatalf("html escaped (python parity): %s", line)
	}
	if got := decode(t, line)["path"]; got != "/ü<>&\U0001F600" {
		t.Fatalf("roundtrip %q", got)
	}
	idx := -1
	for _, k := range []string{`"auth"`, `"bytes"`, `"client_ip"`, `"method"`, `"ms"`, `"path"`, `"profile"`, `"request_id"`, `"state_hash"`, `"status"`, `"tls"`, `"ts"`} {
		i := strings.Index(line, k)
		if i <= idx {
			t.Fatalf("keys not sorted at %s: %s", k, line)
		}
		idx = i
	}
}

func TestAllowListsCollapse(t *testing.T) {
	r := rec(t, func(f *audit.Fields) {
		f.Method = "BREW"
		f.AuthResult = "topsecret"
		f.RequestID = "not-hex"
		f.ClientIP = "999.1.1.1"
		f.TLSVersion = strings.Repeat("x", 50)
	})
	if r.Method != "OTHER" || r.Auth != "other" || r.RequestID != "invalid" || r.ClientIP != "invalid" || r.TLS != "other" {
		t.Fatalf("%+v", r)
	}
}

func TestKnownValuesPass(t *testing.T) {
	for _, a := range []string{"ok", "missing", "wrong", "throttled", "none"} {
		if r := rec(t, func(f *audit.Fields) { f.AuthResult = a }); r.Auth != a {
			t.Fatal(a)
		}
	}
	for _, m := range []string{"GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS", "PATCH"} {
		if r := rec(t, func(f *audit.Fields) { f.Method = m }); r.Method != m {
			t.Fatal(m)
		}
	}
	for _, v := range []string{"TLSv1.2", "TLSv1.3"} {
		if r := rec(t, func(f *audit.Fields) { f.TLSVersion = v }); r.TLS != v {
			t.Fatal(v)
		}
	}
	if r := rec(t, func(f *audit.Fields) { f.ClientIP = "::1" }); r.ClientIP != "::1" {
		t.Fatal(r.ClientIP)
	}
	if r := rec(t, func(f *audit.Fields) { f.RequestID = "0123456789abcdef\n" }); r.RequestID != "invalid" {
		t.Fatal("request id with trailing newline accepted")
	}
}

func TestNumericSanitising(t *testing.T) {
	r := rec(t, func(f *audit.Fields) { f.Millis = math.NaN(); f.Bytes = -5; f.Status = 99999 })
	if r.MS != 0 || r.Bytes != 0 || r.Status != 0 {
		t.Fatalf("%+v", r)
	}
	for _, bad := range []float64{math.Inf(1), math.Inf(-1), -1} {
		if r := rec(t, func(f *audit.Fields) { f.Millis = bad }); r.MS != 0 {
			t.Fatalf("ms %v -> %v", bad, r.MS)
		}
	}
	if r := rec(t, func(f *audit.Fields) { f.Millis = 1.23456789 }); r.MS != 1.235 {
		t.Fatalf("%v", r.MS)
	}
	for _, s := range []int{99, 600, -1} {
		if r := rec(t, func(f *audit.Fields) { f.Status = s }); r.Status != 0 {
			t.Fatalf("status %d", s)
		}
	}
	if r := rec(t, func(f *audit.Fields) { f.Status = 599 }); r.Status != 599 {
		t.Fatal("599")
	}
}

func TestStateHashFieldMustLookLikeHashOrNil(t *testing.T) {
	if r := rec(t, func(f *audit.Fields) { f.StateHash = nil }); r.StateHash != nil {
		t.Fatal("nil must stay nil")
	}
	if m := decode(t, audit.ToJSONLine(rec(t, func(f *audit.Fields) { f.StateHash = nil }))); m["state_hash"] != nil {
		t.Fatal("must be JSON null")
	}
	s := secretState
	if r := rec(t, func(f *audit.Fields) { f.StateHash = &s }); r.StateHash == nil || *r.StateHash != "invalid" {
		t.Fatal("plaintext state not collapsed")
	}
}

func TestProfileSanitised(t *testing.T) {
	get := func(p *string) *string { return rec(t, func(f *audit.Fields) { f.Profile = p }).Profile }
	ok, bad, empty := "decide-tiny", "has space\nnewline", ""
	if p := get(&ok); p == nil || *p != ok {
		t.Fatal("ok")
	}
	if p := get(&bad); p == nil || *p != "other" {
		t.Fatal("bad")
	}
	if p := get(&empty); p == nil || *p != "other" {
		t.Fatal("empty")
	}
	if get(nil) != nil {
		t.Fatal("nil")
	}
	long := "a" + strings.Repeat("b", 64)
	if p := get(&long); *p != "other" {
		t.Fatal("65 chars")
	}
}

func TestNowDefaultsToClock(t *testing.T) {
	f := fields(t, func(f *audit.Fields) { f.Now = time.Time{} })
	r := audit.NewRecord(f)
	ts, err := time.Parse("2006-01-02T15:04:05Z", r.TS)
	if err != nil || time.Since(ts) > time.Minute || time.Until(ts) > time.Minute {
		t.Fatalf("ts %q err %v", r.TS, err)
	}
}

func TestSinkWritesJSONLinesWith0600(t *testing.T) {
	p := filepath.Join(t.TempDir(), "sub", "audit.log")
	s, err := audit.NewSink(p)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	for i := 0; i < 3; i++ {
		if err := s.Write(rec(t, nil)); err != nil {
			t.Fatal(err)
		}
	}
	st, _ := os.Stat(p)
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", st.Mode())
	}
	b, _ := os.ReadFile(p)
	if n := strings.Count(string(b), "\n"); n != 3 {
		t.Fatalf("lines %d", n)
	}
	for _, l := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		decode(t, l)
	}
}

func TestSinkTightensExistingLooseFile(t *testing.T) {
	p := filepath.Join(t.TempDir(), "a.log")
	if err := os.WriteFile(p, []byte("old\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_ = os.Chmod(p, 0o644)
	s, err := audit.NewSink(p)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	st, _ := os.Stat(p)
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", st.Mode())
	}
	if err := s.Write(rec(t, nil)); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(p)
	if !strings.HasPrefix(string(b), "old\n") {
		t.Fatal("existing content lost")
	}
}

func TestSinkRefusesSymlink(t *testing.T) {
	d := t.TempDir()
	target := filepath.Join(d, "t")
	_ = os.WriteFile(target, nil, 0o600)
	l := filepath.Join(d, "l.log")
	if err := os.Symlink(target, l); err != nil {
		t.Fatal(err)
	}
	if _, err := audit.NewSink(l); err == nil {
		t.Fatal("followed symlink")
	}
}

func TestSinkRotationSafe(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "a.log")
	s, err := audit.NewSink(p)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	_ = s.Write(rec(t, nil))
	if err := os.Rename(p, p+".1"); err != nil {
		t.Fatal(err)
	}
	if err := s.Write(rec(t, nil)); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(p)
	if err != nil || strings.Count(string(b), "\n") != 1 {
		t.Fatalf("new file after rotate: %q %v", b, err)
	}
	old, _ := os.ReadFile(p + ".1")
	if strings.Count(string(old), "\n") != 1 {
		t.Fatalf("rotated file got extra lines: %q", old)
	}
	st, _ := os.Stat(p)
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("recreated mode %v", st.Mode())
	}
	// deletion (not rename) is also recovered
	_ = os.Remove(p)
	if err := s.Write(rec(t, nil)); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(p); strings.Count(string(b), "\n") != 1 {
		t.Fatal("not recreated after delete")
	}
}

func TestSinkConcurrentWritersNoInterleave(t *testing.T) {
	p := filepath.Join(t.TempDir(), "c.log")
	s, err := audit.NewSink(p)
	if err != nil {
		t.Fatal(err)
	}
	const G, N = 16, 200
	var wg sync.WaitGroup
	for g := 0; g < G; g++ {
		wg.Add(1)
		go func(g int) {
			defer wg.Done()
			for i := 0; i < N; i++ {
				r := rec(t, func(f *audit.Fields) { f.Path = "/v1/" + strings.Repeat("p", 100+g) })
				if err := s.Write(r); err != nil {
					t.Error(err)
					return
				}
			}
		}(g)
	}
	wg.Wait()
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	f, _ := os.Open(p)
	defer f.Close()
	sc := bufio.NewScanner(f)
	n := 0
	for sc.Scan() {
		decode(t, sc.Text())
		n++
	}
	if n != G*N {
		t.Fatalf("lines %d want %d", n, G*N)
	}
}

func TestSinkWriteAfterCloseErrors(t *testing.T) {
	s, err := audit.NewSink(filepath.Join(t.TempDir(), "x.log"))
	if err != nil {
		t.Fatal(err)
	}
	_ = s.Close()
	if err := s.Write(rec(t, nil)); err == nil {
		t.Fatal("write after close succeeded")
	}
	if err := s.Close(); err != nil {
		t.Fatalf("double close: %v", err)
	}
}
