package gateway

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

func writeEngineKeyFile(t *testing.T, path, key string, mode os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(key), mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil { // WriteFile honours the umask; the mode under test is exact
		t.Fatal(err)
	}
}

func TestReadKeyFileAcceptsOnlyAPrivateRegularFileOfTheCaller(t *testing.T) {
	d := t.TempDir()
	ok := filepath.Join(d, "ok.key")
	writeEngineKeyFile(t, ok, "  sekret-1\n", 0o600)
	if k, err := ReadKeyFile(ok); err != nil || k != "sekret-1" {
		t.Fatalf("%q %v", k, err)
	}
	writeEngineKeyFile(t, filepath.Join(d, "ro.key"), "sekret-2", 0o400)
	if k, err := ReadKeyFile(filepath.Join(d, "ro.key")); err != nil || k != "sekret-2" {
		t.Fatalf("0400 is tighter than 0600 and must be accepted: %q %v", k, err)
	}
	for name, mode := range map[string]os.FileMode{"group": 0o640, "world": 0o604, "exec": 0o700, "loose": 0o666} {
		p := filepath.Join(d, name+".key")
		writeEngineKeyFile(t, p, "sekret", mode)
		if _, err := ReadKeyFile(p); err == nil {
			t.Errorf("mode %o must be refused", mode)
		} else if strings.Contains(err.Error(), "sekret") {
			t.Errorf("the error leaks the key: %v", err)
		}
	}
	link := filepath.Join(d, "link.key")
	if err := os.Symlink(ok, link); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadKeyFile(link); err == nil {
		t.Error("a symlink must be refused even when its target is fine")
	}
	writeEngineKeyFile(t, filepath.Join(d, "empty.key"), " \n", 0o600)
	if _, err := ReadKeyFile(filepath.Join(d, "empty.key")); err == nil {
		t.Error("an empty key must be refused")
	}
	writeEngineKeyFile(t, filepath.Join(d, "huge.key"), strings.Repeat("k", 5000), 0o600)
	if _, err := ReadKeyFile(filepath.Join(d, "huge.key")); err == nil {
		t.Error("an oversize key file must be refused")
	}
	if _, err := ReadKeyFile(d); err == nil {
		t.Error("a directory is not a key file")
	}
	if _, err := ReadKeyFile(filepath.Join(d, "missing.key")); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("a missing file must satisfy os.ErrNotExist: %v", err)
	}
}

func TestKeySourcePrefersTheProfileFileThenTheGlobalFile(t *testing.T) {
	st, d := t.TempDir(), t.TempDir()
	global := filepath.Join(d, "global.key")
	writeEngineKeyFile(t, global, "global-key", 0o600)
	ks := NewKeySource(testSpecs(), global, st)

	// no profile file: the global file
	if k, err := ks.Lookup("decide-nli", false); err != nil || k != "global-key" {
		t.Fatalf("%q %v", k, err)
	}
	// the NLI profile is served by the encoder runtime: keys/onnx-<profile>.key (lib/scheduler.sh)
	writeEngineKeyFile(t, filepath.Join(st, "keys", "onnx-decide-nli.key"), "onnx-key", 0o600)
	if k, err := ks.Lookup("decide-nli", false); err != nil || k != "onnx-key" {
		t.Fatalf("%q %v", k, err)
	}
	// a decoder profile uses the llama kind
	writeEngineKeyFile(t, filepath.Join(st, "keys", "llama-decide-tiny.key"), "llama-key", 0o600)
	if k, err := ks.Lookup("decide-tiny", false); err != nil || k != "llama-key" {
		t.Fatalf("%q %v", k, err)
	}
	// the onnx file does not leak to a decoder profile
	if k, _ := ks.Lookup("decide-laya", false); k != "global-key" {
		t.Fatalf("%q", k)
	}
}

func TestKeySourceDoesNotFallThroughToAnotherFileWhenTheProfileFileIsInsecure(t *testing.T) {
	st, d := t.TempDir(), t.TempDir()
	global := filepath.Join(d, "global.key")
	writeEngineKeyFile(t, global, "global-key", 0o600)
	writeEngineKeyFile(t, filepath.Join(st, "keys", "onnx-decide-nli.key"), "loose-key", 0o644)
	ks := NewKeySource(testSpecs(), global, st)
	k, err := ks.Lookup("decide-nli", false)
	if err == nil || k != "" || errors.Is(err, ErrNoKey) {
		t.Fatalf("an existing but insecure profile key file must be an error, not a silent fallback: %q %v", k, err)
	}
	if strings.Contains(err.Error(), "loose-key") || strings.Contains(err.Error(), "global-key") {
		t.Fatalf("leak: %v", err)
	}
}

func TestKeySourceWithNothingConfiguredReportsErrNoKey(t *testing.T) {
	ks := NewKeySource(testSpecs(), "", t.TempDir())
	if _, err := ks.Lookup("decide-tiny", false); !errors.Is(err, ErrNoKey) {
		t.Fatalf("%v", err)
	}
	if _, err := NewKeySource(testSpecs(), "", "").Lookup("decide-tiny", false); !errors.Is(err, ErrNoKey) {
		t.Fatalf("%v", err)
	}
}

func TestKeySourceNoticesRotationAndPermissionChangesWithoutARestart(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "g.key")
	writeEngineKeyFile(t, p, "one", 0o600)
	ks := NewKeySource(testSpecs(), p, "")
	if k, _ := ks.Lookup("decide-tiny", false); k != "one" {
		t.Fatal(k)
	}
	writeEngineKeyFile(t, p, "two-longer", 0o600) // the size changes, so even an equal mtime tick is seen
	if k, _ := ks.Lookup("decide-tiny", false); k != "two-longer" {
		t.Fatalf("rotation not noticed: %q", k)
	}
	if err := os.Chmod(p, 0o644); err != nil {
		t.Fatal(err)
	}
	if k, err := ks.Lookup("decide-tiny", false); err == nil || k != "" {
		t.Fatalf("a cached key must not survive its file becoming group/world readable: %q %v", k, err)
	}
}

func TestKeyedResolverFillsKeysAndMarksUnusableKeysUnhealthy(t *testing.T) {
	st := t.TempDir()
	writeEngineKeyFile(t, filepath.Join(st, "keys", "onnx-decide-nli.key"), "onnx-key", 0o600)
	writeEngineKeyFile(t, filepath.Join(st, "keys", "llama-decide-tiny.key"), "loose", 0o666)
	in := NewStaticResolver()
	in.Set(KindDecide, "decide-nli", Endpoint{URL: "http://127.0.0.1:1", Healthy: true, Instance: "decide-nli"},
		Endpoint{URL: "http://127.0.0.1:2", Healthy: true, Instance: "decide-nli.2", Key: "preset"})
	in.Set(KindDecide, "decide-tiny", Endpoint{URL: "http://127.0.0.1:3", Healthy: true, Instance: "decide-tiny"})
	in.Set(KindDecide, "decide-laya", Endpoint{URL: "http://127.0.0.1:4", Healthy: true, Instance: "decide-laya"})
	var reported []string
	kr := &KeyedResolver{Inner: in, Keys: NewKeySource(testSpecs(), "", st), OnError: func(profile string, err error) { reported = append(reported, profile) }}

	eps, err := kr.Resolve(KindDecide, "decide-nli")
	if err != nil || len(eps) != 2 || eps[0].Key != "onnx-key" || !eps[0].Healthy || eps[1].Key != "preset" {
		t.Fatalf("%+v %v", eps, err)
	}
	eps, _ = kr.Resolve(KindDecide, "decide-tiny")
	if len(eps) != 1 || eps[0].Healthy || eps[0].Key != "" {
		t.Fatalf("an insecure key file must make the instance unhealthy and never be used: %+v", eps)
	}
	if len(reported) != 1 || reported[0] != "decide-tiny" {
		t.Fatalf("reported %v", reported)
	}
	eps, _ = kr.Resolve(KindDecide, "decide-laya")
	if len(eps) != 1 || !eps[0].Healthy || eps[0].Key != "" {
		t.Fatalf("no key configured at all = an unauthenticated engine, unchanged: %+v", eps)
	}
}

// A rotated key file is picked up on a 401 from the engine without restarting the gateway; the
// retry is bounded to ONE extra attempt and only when the re-read key actually differs.
func TestPostJSONReReadsTheKeyFileOnA401AndRetriesOnce(t *testing.T) {
	d := t.TempDir()
	kf := filepath.Join(d, "k.key")
	writeEngineKeyFile(t, kf, "old-key", 0o600)
	var calls atomic.Int32
	var seen []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		seen = append(seen, r.Header.Get("Authorization"))
		if r.Header.Get("Authorization") != "Bearer new-key" {
			w.WriteHeader(401)
			return
		}
		_, _ = w.Write([]byte(`{}`))
	}))
	defer srv.Close()
	ks := NewKeySource(testSpecs(), kf, "")
	SetEngineKeys(ks)
	defer SetEngineKeys(nil)
	e := Endpoint{URL: srv.URL, Key: "old-key", Healthy: true, Instance: "decide-tiny"}

	writeEngineKeyFile(t, kf, "new-key", 0o600) // the operator rotated the file behind the gateway's back
	if _, err := postJSON(context.Background(), nil, e, "/x", []byte(`{}`)); err != nil {
		t.Fatalf("rotation without restart failed: %v", err)
	}
	if calls.Load() != 2 || seen[0] != "Bearer old-key" || seen[1] != "Bearer new-key" {
		t.Fatalf("calls=%d seen=%v", calls.Load(), seen)
	}

	// file still holds the key the engine already rejected: no pointless second attempt
	calls.Store(0)
	seen = nil
	writeEngineKeyFile(t, kf, "old-key", 0o600)
	if _, err := postJSON(context.Background(), nil, e, "/x", []byte(`{}`)); err == nil {
		t.Fatal("must fail")
	}
	if calls.Load() != 1 {
		t.Fatalf("retried although the key did not change: %d", calls.Load())
	}

	// the re-read key is rejected too: exactly ONE retry, never a loop
	calls.Store(0)
	seen = nil
	writeEngineKeyFile(t, kf, "other-key", 0o600)
	if _, err := postJSON(context.Background(), nil, e, "/x", []byte(`{}`)); err == nil {
		t.Fatal("must fail")
	}
	if calls.Load() != 2 {
		t.Fatalf("retry must be bounded to one: %d", calls.Load())
	}
}

func TestPostJSONWithoutAKeySourceDoesNotRetryA401(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls.Add(1); w.WriteHeader(401) }))
	defer srv.Close()
	SetEngineKeys(nil)
	if _, err := postJSON(context.Background(), nil, Endpoint{URL: srv.URL, Key: "k", Instance: "decide-tiny"}, "/x", []byte(`{}`)); err == nil || calls.Load() != 1 {
		t.Fatalf("%v %d", err, calls.Load())
	}
}

// G-040: the internal key travels in a file, never in the environment (/proc/<pid>/environ).
func TestNoCodeReadsTheInternalKeyFromTheEnvironment(t *testing.T) {
	root := "../.."
	var hits []string
	_ = filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			switch d.Name() {
			case ".git", "node_modules", "evidence", "research", "specs", "submodules", ".specify":
				return filepath.SkipDir
			}
			return nil
		}
		if !(strings.HasSuffix(p, ".go") || strings.HasSuffix(p, ".sh") || strings.HasSuffix(p, ".md") || strings.HasSuffix(p, ".py")) ||
			strings.HasSuffix(p, "keyfile_test.go") ||
			// the retired-variable guard names the variable on purpose: that is its whole job
			strings.HasSuffix(p, "tests/test_no_retired_vars.sh") ||
			// ... and its generated documentation page quotes that guard's own header
			strings.HasSuffix(p, "docs/scripts/test_no_retired_vars.md") {
			return nil
		}
		b, rerr := os.ReadFile(p)
		if rerr != nil {
			return nil
		}
		for _, line := range strings.Split(string(b), "\n") {
			for i := strings.Index(line, "LLMCTL_DECIDE_INTERNAL_KEY"); i >= 0; {
				rest := line[i+len("LLMCTL_DECIDE_INTERNAL_KEY"):]
				if !strings.HasPrefix(rest, "_FILE") {
					hits = append(hits, p)
				}
				j := strings.Index(rest, "LLMCTL_DECIDE_INTERNAL_KEY")
				if j < 0 {
					break
				}
				i += len("LLMCTL_DECIDE_INTERNAL_KEY") + j
			}
		}
		return nil
	})
	if len(hits) != 0 {
		t.Fatalf("the env-var form of the internal key must be gone (use LLMCTL_DECIDE_INTERNAL_KEY_FILE): %v", hits)
	}
}
