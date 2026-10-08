package audit_test

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/vasic-digital/llmctl/internal/audit"
)

func TestLogKeyCreates0600AndIsStable(t *testing.T) {
	sub := filepath.Join(t.TempDir(), "decide")
	k1, err := audit.LoadOrCreateLogKey(sub)
	if err != nil {
		t.Fatal(err)
	}
	if len(k1) < 32 {
		t.Fatalf("len %d", len(k1))
	}
	st, _ := os.Stat(filepath.Join(sub, "log.key"))
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("file %v", st.Mode())
	}
	ds, _ := os.Stat(sub)
	if ds.Mode().Perm() != 0o700 {
		t.Fatalf("dir %v", ds.Mode())
	}
	k2, err := audit.LoadOrCreateLogKey(sub)
	if err != nil || string(k1) != string(k2) {
		t.Fatal("key not stable")
	}
}

func TestLogKeyTightensLooseMode(t *testing.T) {
	d := t.TempDir()
	k, _ := audit.LoadOrCreateLogKey(d)
	p := filepath.Join(d, "log.key")
	_ = os.Chmod(p, 0o644)
	k2, err := audit.LoadOrCreateLogKey(d)
	if err != nil || string(k) != string(k2) {
		t.Fatalf("err %v", err)
	}
	st, _ := os.Stat(p)
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", st.Mode())
	}
}

func TestLogKeyMalformedIsErrorNotRegenerated(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "log.key")
	for _, c := range []string{"", "   \n", "short", strings.Repeat("zz", 40), strings.Repeat("AB", 32), strings.Repeat("a", 33)} {
		if err := os.WriteFile(p, []byte(c), 0o600); err != nil {
			t.Fatal(err)
		}
		_, err := audit.LoadOrCreateLogKey(d)
		var le *audit.LogKeyError
		if !errors.As(err, &le) {
			t.Fatalf("content %q: err %v", c, err)
		}
		if b, _ := os.ReadFile(p); string(b) != c {
			t.Fatalf("file overwritten for %q", c)
		}
	}
}

func TestLogKeyNotRegularFileRefused(t *testing.T) {
	d := t.TempDir()
	if err := os.Mkdir(filepath.Join(d, "log.key"), 0o700); err != nil {
		t.Fatal(err)
	}
	var le *audit.LogKeyError
	if _, err := audit.LoadOrCreateLogKey(d); !errors.As(err, &le) {
		t.Fatalf("err %v", err)
	}
}

func TestLogKeySymlinkRefused(t *testing.T) {
	d := t.TempDir()
	target := filepath.Join(d, "target")
	_ = os.WriteFile(target, []byte(strings.Repeat("ab", 32)), 0o600)
	if err := os.Symlink(target, filepath.Join(d, "log.key")); err != nil {
		t.Fatal(err)
	}
	var le *audit.LogKeyError
	if _, err := audit.LoadOrCreateLogKey(d); !errors.As(err, &le) {
		t.Fatalf("err %v", err)
	}
}

func TestLogKeyConcurrentCreationYieldsOneKey(t *testing.T) {
	d := t.TempDir()
	const N = 16
	out := make([][]byte, N)
	errs := make([]error, N)
	var wg sync.WaitGroup
	start := make(chan struct{})
	for i := 0; i < N; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			<-start
			out[i], errs[i] = audit.LoadOrCreateLogKey(d)
		}(i)
	}
	close(start)
	wg.Wait()
	for i := 0; i < N; i++ {
		if errs[i] != nil {
			t.Fatalf("caller %d: %v", i, errs[i])
		}
		if string(out[i]) != string(out[0]) {
			t.Fatalf("caller %d got a different key", i)
		}
	}
	ents, _ := os.ReadDir(d)
	if len(ents) != 1 {
		t.Fatalf("leftover temp files: %v", ents)
	}
}

func TestLogKeyErrorNeverContainsKeyMaterial(t *testing.T) {
	d := t.TempDir()
	k, _ := audit.LoadOrCreateLogKey(d)
	hexk := ""
	for _, b := range k {
		hexk += string("0123456789abcdef"[b>>4]) + string("0123456789abcdef"[b&15])
	}
	// corrupt file with trailing junk so the key text is in the file but malformed
	p := filepath.Join(d, "log.key")
	_ = os.WriteFile(p, []byte(hexk+"!!"), 0o600)
	_, err := audit.LoadOrCreateLogKey(d)
	if err == nil || strings.Contains(err.Error(), hexk) {
		t.Fatalf("err %v", err)
	}
}
