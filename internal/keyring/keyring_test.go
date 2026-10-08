package keyring

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	mrand "math/rand"
	"os"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestGenerateKeyProperties(t *testing.T) {
	seen := map[string]bool{}
	re := regexp.MustCompile(`^[A-Za-z0-9_-]{32,}$`)
	for i := 0; i < 50; i++ {
		k := GenerateKey().Reveal()
		if len(k) < 43 || !re.MatchString(k) {
			t.Fatalf("bad generated key (len %d)", len(k))
		}
		if seen[k] {
			t.Fatal("duplicate key generated")
		}
		seen[k] = true
	}
}

func TestValidateKey(t *testing.T) {
	good := []string{goodKey, goodKey2, "0123456789abcdef0123456789abcdee", strings.Repeat("Ab", 8) + "Cd9-_xYz12345678"}
	for _, g := range good {
		if _, err := ValidateKey(g, "test"); err != nil {
			t.Errorf("%q rejected: %v", g, err)
		}
	}
	bad := map[string]string{
		"empty": "", "spaces": "   ", "tab": "\t", "short": "abc", "31": strings.Repeat("a", 31),
		"space-inside": goodKey + " x", "quote": "\"" + goodKey + "\"", "newline": goodKey + "\n",
		"unicode": strings.Repeat("é", 40), "plus": strings.Repeat("a", 31) + "+",
	}
	for name, b := range bad {
		_, err := ValidateKey(b, "the test")
		if err == nil {
			t.Errorf("%s: accepted", name)
			continue
		}
		if !errors.Is(err, ErrInvalidKey) || !errors.Is(err, ErrKey) {
			t.Errorf("%s: wrong class: %v", name, err)
		}
		if b != "" && strings.TrimSpace(b) != "" && contains(err.Error(), b) {
			t.Errorf("%s: error echoes value", name)
		}
	}
}

// A-06: operator-supplied keys need entropy; generated keys always pass.
func TestWeakOperatorKeysAreRefused(t *testing.T) {
	weak := map[string]string{
		"repeated char":        strings.Repeat("a", 32),
		"two chars":            strings.Repeat("ab", 20),
		"short period":         strings.Repeat("A-_9", 20),
		"block repeated":       strings.Repeat("Qw3rTy9xKp", 4),
		"digits only":          strings.Repeat("1234567890", 3) + "12",
		"one char dominates":   strings.Repeat("a", 30) + "bcdefghij",
		"low estimated bits":   "0123456789" + "01234567" + "89012345678901",
		"31 distinct but weak": "abcdefgh" + strings.Repeat("a", 24),
	}
	for name, k := range weak {
		_, err := ValidateKey(k, "test")
		if err == nil {
			t.Errorf("%s: accepted %q", name, k)
			continue
		}
		if !errors.Is(err, ErrInvalidKey) || !contains(err.Error(), "too weak") || contains(err.Error(), k) {
			t.Errorf("%s: wrong error %v", name, err)
		}
		if WeakKey(k) == "" {
			t.Errorf("%s: WeakKey says fine", name)
		}
	}
	// no false positives: 128-bit hex, 256-bit generated keys, a typical passphrase-like mixed key
	// DETERMINISTIC (fixed seed, §11.4.50): a 128-bit hex string is rejected by the dominance rule about
	// once in 200,000 draws, so a time-seeded loop here would be a flaky test.
	prng := mrand.New(mrand.NewSource(20261007))
	rnd := func(alpha string, n int) string {
		b := make([]byte, n)
		for i := range b {
			b[i] = alpha[prng.Intn(len(alpha))]
		}
		return string(b)
	}
	for i := 0; i < 400; i++ {
		for _, k := range []string{GenerateKey().Reveal(), rnd("0123456789abcdef", 32), rnd("0123456789abcdef", 64)} {
			if why := WeakKey(k); why != "" {
				t.Fatalf("random key %q rejected: %s", k, why)
			}
		}
	}
	if _, err := ValidateKey(strings.Repeat("aB3", 200), "t"); err == nil {
		t.Error("a key longer than MaxKeyLen must be refused")
	}
}

func TestErrorClassesAndExitCode(t *testing.T) {
	for _, e := range []error{ErrInvalidKey, ErrUnsafePermissions, ErrUnsafePlacement, ErrEnvFile, ErrKey} {
		if !IsKeyError(e) {
			t.Errorf("%v not a key error", e)
		}
	}
	if IsKeyError(errors.New("x")) || IsKeyError(nil) {
		t.Error("non-key error classified as key error")
	}
	if ExitCode != 4 {
		t.Errorf("ExitCode=%d", ExitCode)
	}
	if errors.Is(ErrUnsafePlacement, ErrEnvFile) {
		t.Error("distinct classes must not match each other")
	}
}

func TestResolutionOrder(t *testing.T) {
	f := newFixture(t)
	f.write("LLMCTL_API_KEY="+goodKey+"\n", 0o600)
	r, err := f.resolve(Environ{"LLMCTL_API_KEY": goodKey2})
	if err != nil || r.Source != "env" || r.Key.Reveal() != goodKey2 {
		t.Fatalf("env must win: %+v %v", r, err)
	}
	r, err = f.resolve(Environ{})
	if err != nil || r.Source != "file" || r.Key.Reveal() != goodKey {
		t.Fatalf("file used: %+v %v", r, err)
	}
}

func TestGeneratedFirstStartThenReuse(t *testing.T) {
	f := newFixture(t)
	r, err := f.resolve(Environ{})
	if err != nil || r.Source != "generated" {
		t.Fatalf("%+v %v", r, err)
	}
	if f.mode() != 0o600 {
		t.Errorf("mode %v", f.mode())
	}
	if !contains(f.read(), "LLMCTL_API_KEY="+r.Key.Reveal()) {
		t.Error("key not persisted")
	}
	r2, err := f.resolve(Environ{})
	if err != nil || r2.Source != "file" || r2.Key.Reveal() != r.Key.Reveal() {
		t.Fatalf("reuse: %+v %v", r2, err)
	}
	entries, _ := os.ReadDir(f.dir)
	if len(entries) != 1 {
		t.Errorf("leftover files: %v", entries)
	}
}

func TestFreshInstallsDistinct(t *testing.T) {
	a, b := newFixture(t), newFixture(t)
	ra, _ := a.resolve(Environ{})
	rb, _ := b.resolve(Environ{})
	if ra.Key.Reveal() == rb.Key.Reveal() {
		t.Fatal("two fresh installs share a key")
	}
}

func TestEnvFileOverride(t *testing.T) {
	f := newFixture(t)
	ovr := f.dir + "/sub/my.env"
	r, err := Resolve(f.dir, Environ{"LLMCTL_ENV_FILE": ovr}, true)
	if err != nil || r.Path != ovr {
		t.Fatalf("%+v %v", r, err)
	}
	if _, err := os.Stat(ovr); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(f.file); err == nil {
		t.Fatal("default .env must stay untouched")
	}
	// blank override falls back to default
	if p := EnvFilePath(f.dir, Environ{"LLMCTL_ENV_FILE": "  "}); p != f.file {
		t.Errorf("blank override: %s", p)
	}
}

func TestBlankOrMalformedIsErrorNotNoKey(t *testing.T) {
	f := newFixture(t)
	for _, v := range []string{"", "   ", "short", goodKey + "!"} {
		_, err := f.resolve(Environ{"LLMCTL_API_KEY": v})
		if !errors.Is(err, ErrInvalidKey) {
			t.Errorf("env %q: %v", v, err)
		}
	}
	for _, v := range []string{"", "short", "\"" + goodKey + " \""} {
		f.write("LLMCTL_API_KEY="+v+"\n", 0o600)
		_, err := f.resolve(Environ{})
		if !errors.Is(err, ErrInvalidKey) {
			t.Errorf("file %q: %v", v, err)
		}
	}
}

func TestExistingKeyNeverOverwrittenSilently(t *testing.T) {
	f := newFixture(t)
	f.write("LLMCTL_API_KEY="+goodKey+"\n", 0o600)
	if err := SetKey(f.file, goodKey2, false); !errors.Is(err, ErrKey) {
		t.Fatalf("expected refusal, got %v", err)
	}
	if !contains(f.read(), goodKey) || contains(f.read(), goodKey2) {
		t.Fatal("file changed")
	}
	if err := SetKey(f.file, goodKey2, true); err != nil || !contains(f.read(), goodKey2) {
		t.Fatalf("explicit overwrite failed: %v", err)
	}
	if err := SetKey(f.file, "bad", true); !errors.Is(err, ErrInvalidKey) {
		t.Fatalf("invalid key accepted: %v", err)
	}
}

func TestFileWithoutKeyKeepsOtherLines(t *testing.T) {
	f := newFixture(t)
	f.write("# mine\nOTHER=1\n", 0o600)
	r, err := f.resolve(Environ{})
	if err != nil || r.Source != "generated" {
		t.Fatal(err)
	}
	c := f.read()
	if !contains(c, "# mine\nOTHER=1\n") || !contains(c, "LLMCTL_API_KEY=") {
		t.Fatalf("lines lost: %q", strings.ReplaceAll(c, r.Key.Reveal(), "K"))
	}
}

func TestGenerateFalseReturnsNone(t *testing.T) {
	f := newFixture(t)
	r, err := Resolve(f.dir, Environ{}, false)
	if err != nil || r.Source != "none" || r.Key.Reveal() != "" {
		t.Fatalf("%+v %v", r, err)
	}
	if _, err := os.Stat(f.file); err == nil {
		t.Fatal("must not create file")
	}
}

func TestInspectShadowing(t *testing.T) {
	f := newFixture(t)
	f.write("LLMCTL_API_KEY="+goodKey+"\n", 0o600)
	i, err := Inspect(f.dir, Environ{"LLMCTL_API_KEY": goodKey2})
	if err != nil || i.Source != "env" || !i.FileShadowed || !i.FileHasKey {
		t.Fatalf("%+v %v", i, err)
	}
	i, _ = Inspect(f.dir, Environ{"LLMCTL_API_KEY": goodKey})
	if i.FileShadowed {
		t.Error("equal keys are not shadowing")
	}
	i, _ = Inspect(f.dir, Environ{})
	if i.Source != "file" || i.Mode != "600" {
		t.Errorf("%+v", i)
	}
	e := newFixture(t)
	i, _ = Inspect(e.dir, Environ{})
	if i.Source != "none" || i.FileExists {
		t.Errorf("%+v", i)
	}
	if _, err := os.Stat(e.file); err == nil {
		t.Error("inspect must not create the file")
	}
}

func TestConcurrentFirstStartsMakeOneKey(t *testing.T) {
	f := newFixture(t)
	const n = 24
	keys := make([]string, n)
	errs := make([]error, n)
	var wg sync.WaitGroup
	start := make(chan struct{})
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			<-start
			r, err := f.resolve(Environ{})
			keys[i], errs[i] = r.Key.Reveal(), err
		}(i)
	}
	close(start)
	wg.Wait()
	for i := range keys {
		if errs[i] != nil {
			t.Fatal(errs[i])
		}
		if keys[i] != keys[0] {
			t.Fatalf("goroutine %d got a different key", i)
		}
	}
	if strings.Count(f.read(), "LLMCTL_API_KEY=") != 1 {
		t.Fatal("more than one key line")
	}
}

// ---- rotation ----

func TestRotateNoGrace(t *testing.T) {
	f := newFixture(t)
	f.write("LLMCTL_API_KEY="+goodKey+"\nLLMCTL_API_KEY_PREVIOUS="+goodKey2+"\nLLMCTL_API_KEY_PREVIOUS_EXPIRES=99999999999\n", 0o600)
	r, err := Rotate(f.dir, Environ{}, 0, time.Unix(1000, 0))
	if err != nil {
		t.Fatal(err)
	}
	c := f.read()
	if r.Key.Reveal() == goodKey || !contains(c, "LLMCTL_API_KEY="+r.Key.Reveal()) {
		t.Fatal("key not replaced")
	}
	if contains(c, "PREVIOUS") || contains(c, goodKey) {
		t.Fatalf("stale previous kept: %q", c)
	}
	if f.mode() != 0o600 || r.PreviousExpires != 0 || r.EnvShadows {
		t.Errorf("mode %v %+v", f.mode(), r)
	}
}

func TestRotateWithGraceAcceptsPreviousUntilExpiry(t *testing.T) {
	f := newFixture(t)
	f.write("LLMCTL_API_KEY="+goodKey+"\n", 0o600)
	now := time.Unix(10_000, 0)
	r, err := Rotate(f.dir, Environ{}, 600, now)
	if err != nil || r.PreviousExpires != 10_600 {
		t.Fatalf("%+v %v", r, err)
	}
	if !contains(f.read(), "LLMCTL_API_KEY_PREVIOUS="+goodKey) || !contains(f.read(), "LLMCTL_API_KEY_PREVIOUS_EXPIRES=10600") {
		t.Fatal("previous not stored")
	}
	acc, _ := AcceptedKeys(f.dir, Environ{}, now.Add(599*time.Second))
	if len(acc) != 2 {
		t.Fatalf("within grace: %d", len(acc))
	}
	acc, _ = AcceptedKeys(f.dir, Environ{}, now.Add(600*time.Second))
	if len(acc) != 1 {
		t.Fatalf("at expiry: %d", len(acc))
	}
}

func TestPreviousNeverFromEnvironment(t *testing.T) {
	f := newFixture(t)
	f.write("LLMCTL_API_KEY="+goodKey+"\n", 0o600)
	acc, _ := AcceptedKeys(f.dir, Environ{"LLMCTL_API_KEY_PREVIOUS": goodKey2, "LLMCTL_API_KEY_PREVIOUS_EXPIRES": "99999999999"}, time.Unix(1, 0))
	if len(acc) != 1 {
		t.Fatal("previous honoured from environment")
	}
}

func TestPreviousWithoutValidExpiryNotAccepted(t *testing.T) {
	for _, tail := range []string{"", "LLMCTL_API_KEY_PREVIOUS_EXPIRES=abc\n", "LLMCTL_API_KEY_PREVIOUS_EXPIRES=-5\n"} {
		f := newFixture(t)
		f.write("LLMCTL_API_KEY="+goodKey+"\nLLMCTL_API_KEY_PREVIOUS="+goodKey2+"\n"+tail, 0o600)
		acc, _ := AcceptedKeys(f.dir, Environ{}, time.Unix(1, 0))
		if len(acc) != 1 {
			t.Errorf("tail %q accepted previous", tail)
		}
	}
	f := newFixture(t)
	f.write("LLMCTL_API_KEY="+goodKey+"\nLLMCTL_API_KEY_PREVIOUS=short\nLLMCTL_API_KEY_PREVIOUS_EXPIRES=99999999999\n", 0o600)
	if acc, _ := AcceptedKeys(f.dir, Environ{}, time.Unix(1, 0)); len(acc) != 1 {
		t.Error("malformed previous accepted")
	}
}

func TestSecondRotationReplacesPrevious(t *testing.T) {
	f := newFixture(t)
	f.write("LLMCTL_API_KEY="+goodKey+"\n", 0o600)
	now := time.Unix(5, 0)
	r1, _ := Rotate(f.dir, Environ{}, 60, now)
	r2, _ := Rotate(f.dir, Environ{}, 60, now)
	c := f.read()
	if !contains(c, "LLMCTL_API_KEY_PREVIOUS="+r1.Key.Reveal()) || contains(c, goodKey) {
		t.Fatalf("previous not replaced: %q", c)
	}
	if strings.Count(c, "LLMCTL_API_KEY_PREVIOUS=") != 1 || !contains(c, "LLMCTL_API_KEY="+r2.Key.Reveal()) {
		t.Fatal("duplicate lines")
	}
}

func TestRotateReportsEnvShadowAndRejectsNegativeGrace(t *testing.T) {
	f := newFixture(t)
	r, err := Rotate(f.dir, Environ{"LLMCTL_API_KEY": goodKey}, 0, time.Now())
	if err != nil || !r.EnvShadows {
		t.Fatalf("%+v %v", r, err)
	}
	if _, err := Rotate(f.dir, Environ{}, -1, time.Now()); !errors.Is(err, ErrKey) {
		t.Fatalf("negative grace: %v", err)
	}
}

// Superseded by review A2-01: the file's PREVIOUS is an overlap for a FILE-sourced key only; an
// environment key is accepted ALONE (the pre-A2-01 expectation of two keys was the widening defect).
func TestEnvKeyIsAcceptedAloneEvenWithAFilePrevious(t *testing.T) {
	f := newFixture(t)
	f.write("LLMCTL_API_KEY="+goodKey+"\nLLMCTL_API_KEY_PREVIOUS="+goodKey2+"\nLLMCTL_API_KEY_PREVIOUS_EXPIRES=99999999999\n", 0o600)
	env := "eNvK3y-" + goodKey2[:33]
	acc, _ := AcceptedKeys(f.dir, Environ{"LLMCTL_API_KEY": env}, time.Unix(1, 0))
	if len(acc) != 1 || acc[0].Reveal() != env {
		t.Fatalf("%d accepted", len(acc))
	}
}

// ---- constant-time comparison ----

func TestKeyMatchesAnyAccepted(t *testing.T) {
	acc := []Secret{NewSecret(goodKey), NewSecret(goodKey2)}
	if !KeyMatches(goodKey, acc) || !KeyMatches(goodKey2, acc) {
		t.Error("accepted key not matched")
	}
	for _, c := range []string{"", goodKey + "x", goodKey[:10], "nope"} {
		if KeyMatches(c, acc) {
			t.Errorf("%q matched", c)
		}
	}
	if KeyMatches(goodKey, nil) {
		t.Error("matched against empty set")
	}
	if KeyMatches("", []Secret{NewSecret("")}) {
		t.Error("empty candidate must never match")
	}
}

func TestKeyMatchesComparesEveryKeyNoEarlyExit(t *testing.T) {
	old := ctEqual
	defer func() { ctEqual = old }()
	calls := 0
	ctEqual = func(a, b []byte) int { calls++; return old(a, b) }
	acc := []Secret{NewSecret(goodKey), NewSecret(goodKey2), NewSecret(strings.Repeat("z", 40))} // raw secrets: KeyMatches does not validate
	if !KeyMatches(goodKey, acc) {                                                               // matches the FIRST accepted key
		t.Fatal("no match")
	}
	if calls != len(acc) {
		t.Fatalf("early exit: %d comparisons for %d keys", calls, len(acc))
	}
}

// ---- redaction / leak checks ----

func TestRedaction(t *testing.T) {
	r, _ := f2(t).resolve(Environ{"LLMCTL_API_KEY": goodKey})
	s := NewSecret(goodKey)
	rot := RotateResult{Key: s, Path: "/x"}
	var buf bytes.Buffer
	lg := slog.New(slog.NewTextHandler(&buf, nil))
	lg.Info("k", "secret", s, "res", r)
	js, _ := json.Marshal(map[string]any{"s": s, "r": r, "rot": rot})
	things := []any{s, &s, r, &r, rot, &rot, []any{s, r}, map[string]any{"k": s}, struct{ K Secret }{s}}
	for i, v := range things {
		for _, out := range []string{
			fmt.Sprint(v), fmt.Sprintf("%v", v), fmt.Sprintf("%+v", v), fmt.Sprintf("%#v", v),
			fmt.Sprintf("%s", v), fmt.Sprintf("%q", v), fmt.Sprintf("%x", v), fmt.Sprintf("%d", v),
		} {
			if contains(out, goodKey) {
				t.Errorf("thing %d leaks: %s", i, out)
			}
		}
	}
	if contains(buf.String(), goodKey) || contains(string(js), goodKey) {
		t.Errorf("log/json leak: %s %s", buf.String(), js)
	}
	if !contains(fmt.Sprint(s), "redacted") || !contains(fmt.Sprint(r), "redacted") {
		t.Error("no redaction marker")
	}
	if s.Reveal() != goodKey {
		t.Error("Reveal broken")
	}
}

func f2(t *testing.T) *fixture { return newFixture(t) }

func TestNoKeyInLogsOrErrors(t *testing.T) {
	var buf bytes.Buffer
	old := Logger
	Logger = slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelDebug}))
	defer func() { Logger = old }()
	f := newFixture(t)
	r, err := f.resolve(Environ{})
	if err != nil {
		t.Fatal(err)
	}
	rot, _ := Rotate(f.dir, Environ{}, 30, time.Now())
	_, _ = AcceptedKeys(f.dir, Environ{}, time.Now())
	_, _ = Inspect(f.dir, Environ{})
	var texts []string
	for _, bad := range []string{goodKey + "!", goodKey[:5], "  "} {
		_, e := ValidateKey(bad, "arg")
		texts = append(texts, e.Error())
	}
	_, e := ParseEnvText("oops " + goodKey2 + "\n")
	texts = append(texts, e.Error())
	if buf.Len() == 0 {
		t.Error("expected an info log line (generation/rotation)")
	}
	all := buf.String() + strings.Join(texts, "\n")
	for _, k := range []string{r.Key.Reveal(), rot.Key.Reveal(), goodKey, goodKey2, goodKey + "!"} {
		if contains(all, k) {
			t.Errorf("leak of %.6s...", k)
		}
	}
}

func TestInspectNeverContainsKey(t *testing.T) {
	f := newFixture(t)
	r, _ := f.resolve(Environ{})
	i, _ := Inspect(f.dir, Environ{})
	if contains(fmt.Sprintf("%+v %#v", i, i), r.Key.Reveal()) {
		t.Fatal("inspect output holds key")
	}
}
