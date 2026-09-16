package replication

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// --- EngineCacheRegistry --------------------------------------------------

func TestEngineCacheRegistry_SetThenGet(t *testing.T) {
	r := NewEngineCacheRegistry()
	if _, ok := r.Get("tenant-a"); ok {
		t.Fatalf("Get on empty registry: ok=true, want false")
	}
	f := EngineCacheFile{TenantID: "tenant-a", NodeID: "node-a", Path: "/tmp/x.bin", Validity: EngineCacheIntact, SavedAt: time.Now()}
	r.Set(f)
	got, ok := r.Get("tenant-a")
	if !ok {
		t.Fatalf("Get after Set: ok=false, want true")
	}
	if got.Path != f.Path || got.Validity != EngineCacheIntact {
		t.Fatalf("Get returned %+v, want %+v", got, f)
	}
}

func TestEngineCacheRegistry_SetReplacesPriorRecordForSameTenant(t *testing.T) {
	r := NewEngineCacheRegistry()
	r.Set(EngineCacheFile{TenantID: "t", Path: "/a", Validity: EngineCacheIntact})
	r.Set(EngineCacheFile{TenantID: "t", Path: "/b", Validity: EngineCacheUnavailable})
	got, ok := r.Get("t")
	if !ok || got.Path != "/b" || got.Validity != EngineCacheUnavailable {
		t.Fatalf("Get after replace = %+v, ok=%v, want Path=/b Validity=unavailable", got, ok)
	}
}

// --- MaybeSaveEngineCache ---------------------------------------------------

func TestMaybeSaveEngineCache_NilSaverIsHonestNoOp(t *testing.T) {
	r := NewEngineCacheRegistry()
	MaybeSaveEngineCache(r, "tenant-a", "node-a", nil)
	if _, ok := r.Get("tenant-a"); ok {
		t.Fatalf("MaybeSaveEngineCache with nil saver recorded something, want no-op")
	}
}

func TestMaybeSaveEngineCache_RecordsIntactOnRealSuccess(t *testing.T) {
	r := NewEngineCacheRegistry()
	saver := EngineSaver(func(tenantID string) (string, error) {
		if tenantID != "tenant-a" {
			t.Fatalf("saver called with tenantID=%q, want tenant-a", tenantID)
		}
		return "/var/lib/llmctl/slots/tenant-a.bin", nil
	})
	MaybeSaveEngineCache(r, "tenant-a", "node-a", saver)
	got, ok := r.Get("tenant-a")
	if !ok {
		t.Fatalf("MaybeSaveEngineCache did not record anything on success")
	}
	if got.Validity != EngineCacheIntact || got.Path != "/var/lib/llmctl/slots/tenant-a.bin" || got.NodeID != "node-a" {
		t.Fatalf("recorded %+v, want Validity=intact Path=/var/.../tenant-a.bin NodeID=node-a", got)
	}
	if got.SavedAt.IsZero() {
		t.Fatalf("recorded SavedAt is zero, want a real timestamp")
	}
}

func TestMaybeSaveEngineCache_RecordsUnavailableOnRealFailure(t *testing.T) {
	r := NewEngineCacheRegistry()
	saver := EngineSaver(func(tenantID string) (string, error) {
		return "", ErrEngineCacheUnsupported
	})
	MaybeSaveEngineCache(r, "tenant-a", "node-a", saver)
	got, ok := r.Get("tenant-a")
	if !ok {
		t.Fatalf("MaybeSaveEngineCache did not record anything on failure")
	}
	if got.Validity != EngineCacheUnavailable {
		t.Fatalf("recorded Validity=%q, want unavailable", got.Validity)
	}
	if got.Path != "" {
		t.Fatalf("recorded Path=%q on a failed save, want empty", got.Path)
	}
}

// --- RestoreOrFallback (T013: TestEngineCache_MissingOrCorruptFile_FallsBackCorrectly) --

// TestEngineCache_MissingOrCorruptFile_FallsBackCorrectly is T013
// (spec.md FR-008): every one of these cases MUST result in
// User Story 1's fallback path actually running (proven via a real
// invocation flag, never assumed), and the reported outcome MUST
// honestly distinguish "fell_back" (a real, once-present-but-now-bad
// file) from "unsupported" (no restore capability at all) - never
// silently reported as pure success or pure failure.
func TestEngineCache_MissingOrCorruptFile_FallsBackCorrectly(t *testing.T) {
	t.Run("missing file", func(t *testing.T) {
		dir := t.TempDir()
		path := filepath.Join(dir, "slot.bin")
		// Write it, then genuinely delete it - a real, deleted file, not
		// an assumed-never-existed path.
		if err := os.WriteFile(path, []byte("real engine bytes"), 0o600); err != nil {
			t.Fatalf("write fixture file: %v", err)
		}
		if err := os.Remove(path); err != nil {
			t.Fatalf("delete fixture file: %v", err)
		}

		var restorerCalled, fallbackCalled bool
		cache := EngineCacheFile{TenantID: "tenant-a", Path: path, Validity: EngineCacheIntact}
		restorer := EngineRestorer(func(tenantID, p string) error {
			restorerCalled = true
			return nil
		})
		fallback := FallbackFunc(func() error {
			fallbackCalled = true
			return nil
		})

		outcome, err := RestoreOrFallback(cache, true, restorer, fallback)
		if err != nil {
			t.Fatalf("RestoreOrFallback: unexpected error %v", err)
		}
		if outcome != RestoreOutcomeFellBack {
			t.Fatalf("outcome = %q, want %q (missing file must fall back, never silently succeed)", outcome, RestoreOutcomeFellBack)
		}
		if restorerCalled {
			t.Fatalf("restorer was called against a missing file - must be skipped entirely")
		}
		if !fallbackCalled {
			t.Fatalf("fallback was NOT called for a missing file - User Story 1's recovery must always run")
		}
	})

	t.Run("corrupted-to-empty file", func(t *testing.T) {
		dir := t.TempDir()
		path := filepath.Join(dir, "slot.bin")
		// A real, genuinely zero-byte file - the on-disk corruption
		// signature this package's own statFileNonEmpty check catches
		// without ever needing to ask a live engine about it.
		if err := os.WriteFile(path, []byte{}, 0o600); err != nil {
			t.Fatalf("write empty fixture file: %v", err)
		}

		var restorerCalled, fallbackCalled bool
		cache := EngineCacheFile{TenantID: "tenant-a", Path: path, Validity: EngineCacheIntact}
		restorer := EngineRestorer(func(tenantID, p string) error {
			restorerCalled = true
			return nil
		})
		fallback := FallbackFunc(func() error {
			fallbackCalled = true
			return nil
		})

		outcome, err := RestoreOrFallback(cache, true, restorer, fallback)
		if err != nil {
			t.Fatalf("RestoreOrFallback: unexpected error %v", err)
		}
		if outcome != RestoreOutcomeFellBack {
			t.Fatalf("outcome = %q, want %q (empty/corrupt file must fall back)", outcome, RestoreOutcomeFellBack)
		}
		if restorerCalled {
			t.Fatalf("restorer was called against a corrupt (empty) file - must be skipped entirely")
		}
		if !fallbackCalled {
			t.Fatalf("fallback was NOT called for a corrupt file")
		}
	})

	t.Run("non-empty but engine rejects it as corrupt", func(t *testing.T) {
		dir := t.TempDir()
		path := filepath.Join(dir, "slot.bin")
		// Non-empty, so statFileNonEmpty passes - but the SECOND line of
		// defense (the real restorer, standing in here for the real
		// engine's own binary-format rejection) reports it unusable.
		if err := os.WriteFile(path, []byte("truncated-garbage"), 0o600); err != nil {
			t.Fatalf("write fixture file: %v", err)
		}

		var fallbackCalled bool
		cache := EngineCacheFile{TenantID: "tenant-a", Path: path, Validity: EngineCacheIntact}
		restorer := EngineRestorer(func(tenantID, p string) error {
			return ErrEngineCacheUnsupported // stands in for a real engine parse failure
		})
		fallback := FallbackFunc(func() error {
			fallbackCalled = true
			return nil
		})

		outcome, err := RestoreOrFallback(cache, true, restorer, fallback)
		if err != nil {
			t.Fatalf("RestoreOrFallback: unexpected error %v", err)
		}
		if outcome != RestoreOutcomeFellBack {
			t.Fatalf("outcome = %q, want %q", outcome, RestoreOutcomeFellBack)
		}
		if !fallbackCalled {
			t.Fatalf("fallback was NOT called after the restorer rejected the file")
		}
	})

	t.Run("no cache known at all", func(t *testing.T) {
		var fallbackCalled bool
		restorer := EngineRestorer(func(tenantID, p string) error { return nil })
		fallback := FallbackFunc(func() error { fallbackCalled = true; return nil })
		outcome, err := RestoreOrFallback(EngineCacheFile{}, false, restorer, fallback)
		if err != nil {
			t.Fatalf("RestoreOrFallback: unexpected error %v", err)
		}
		if outcome != RestoreOutcomeFellBack {
			t.Fatalf("outcome = %q, want %q", outcome, RestoreOutcomeFellBack)
		}
		if !fallbackCalled {
			t.Fatalf("fallback was NOT called when no cache is known")
		}
	})

	t.Run("engine/model does not support restore at all", func(t *testing.T) {
		var fallbackCalled bool
		fallback := FallbackFunc(func() error { fallbackCalled = true; return nil })
		outcome, err := RestoreOrFallback(EngineCacheFile{}, false, nil, fallback)
		if err != nil {
			t.Fatalf("RestoreOrFallback: unexpected error %v", err)
		}
		if outcome != RestoreOutcomeUnsupported {
			t.Fatalf("outcome = %q, want %q (nil restorer means unsupported, distinct from fell_back)", outcome, RestoreOutcomeUnsupported)
		}
		if !fallbackCalled {
			t.Fatalf("fallback was NOT called when restore is unsupported")
		}
	})

	t.Run("fallback itself failing is a genuine reported error", func(t *testing.T) {
		fallback := FallbackFunc(func() error { return errFallbackFixture })
		outcome, err := RestoreOrFallback(EngineCacheFile{}, false, nil, fallback)
		if err == nil {
			t.Fatalf("RestoreOrFallback: want a genuine error when fallback itself fails, got nil")
		}
		if outcome != RestoreOutcomeUnsupported {
			t.Fatalf("outcome = %q, want %q even though fallback failed (outcome names WHICH path was attempted, err names whether it worked)", outcome, RestoreOutcomeUnsupported)
		}
	})
}

func TestRestoreOrFallback_RealFileIntactAndRestorerSucceeds_ReportsSucceeded(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "slot.bin")
	if err := os.WriteFile(path, []byte("real engine bytes"), 0o600); err != nil {
		t.Fatalf("write fixture file: %v", err)
	}
	var fallbackCalled bool
	cache := EngineCacheFile{TenantID: "tenant-a", Path: path, Validity: EngineCacheIntact}
	restorer := EngineRestorer(func(tenantID, p string) error {
		if tenantID != "tenant-a" || p != path {
			t.Fatalf("restorer called with (%q, %q), want (tenant-a, %q)", tenantID, p, path)
		}
		return nil
	})
	fallback := FallbackFunc(func() error { fallbackCalled = true; return nil })

	outcome, err := RestoreOrFallback(cache, true, restorer, fallback)
	if err != nil {
		t.Fatalf("RestoreOrFallback: unexpected error %v", err)
	}
	if outcome != RestoreOutcomeSucceeded {
		t.Fatalf("outcome = %q, want %q", outcome, RestoreOutcomeSucceeded)
	}
	if fallbackCalled {
		t.Fatalf("fallback was called even though the real restore succeeded")
	}
}

func TestRestoreOrFallback_StaleValidity_FallsBackWithoutCallingRestorer(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "slot.bin")
	if err := os.WriteFile(path, []byte("real bytes but stale"), 0o600); err != nil {
		t.Fatalf("write fixture file: %v", err)
	}
	var restorerCalled, fallbackCalled bool
	cache := EngineCacheFile{TenantID: "tenant-a", Path: path, Validity: EngineCacheStale}
	restorer := EngineRestorer(func(tenantID, p string) error { restorerCalled = true; return nil })
	fallback := FallbackFunc(func() error { fallbackCalled = true; return nil })

	outcome, err := RestoreOrFallback(cache, true, restorer, fallback)
	if err != nil {
		t.Fatalf("RestoreOrFallback: unexpected error %v", err)
	}
	if outcome != RestoreOutcomeFellBack {
		t.Fatalf("outcome = %q, want %q", outcome, RestoreOutcomeFellBack)
	}
	if restorerCalled {
		t.Fatalf("restorer was called against a stale-marked cache file")
	}
	if !fallbackCalled {
		t.Fatalf("fallback was NOT called for a stale cache file")
	}
}

var errFallbackFixture = fallbackFixtureError("fixture: fallback path itself genuinely failed")

type fallbackFixtureError string

func (e fallbackFixtureError) Error() string { return string(e) }

// --- Cross-node transfer (HTTPCacheSink / TransferEngineCache) -------------

// startEngineCacheReceiver boots a real httptest.Server implementing the
// SAME wire contract HTTPCacheSink posts against, recording every real
// request it receives (path, headers, and the real posted bytes) -
// mirroring forwarder_test.go's startForwardTargetServer exactly, for
// the identical reason: HTTPCacheSink's own logic (does it POST the
// right bytes to the right path, with the right headers) is fully
// testable against this without needing a real HTTP/3+mTLS listener.
type recordedCacheUpload struct {
	path           string
	tenantIDHeader string
	filenameHeader string
	authHeader     string
	body           []byte
}

func startEngineCacheReceiver(t *testing.T) (baseURL string, requests *[]recordedCacheUpload, mu *sync.Mutex) {
	t.Helper()
	var recorded []recordedCacheUpload
	var m sync.Mutex
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body := make([]byte, r.ContentLength)
		_, _ = r.Body.Read(body)
		m.Lock()
		recorded = append(recorded, recordedCacheUpload{
			path:           r.URL.Path,
			tenantIDHeader: r.Header.Get("X-Tenant-Id"),
			filenameHeader: r.Header.Get("X-Engine-Cache-Filename"),
			authHeader:     r.Header.Get("Authorization"),
			body:           body,
		})
		m.Unlock()
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(srv.Close)
	return srv.URL, &recorded, &m
}

func TestHTTPCacheSink_PostsRealFileBytesWithHeaders(t *testing.T) {
	baseURL, requests, mu := startEngineCacheReceiver(t)

	sink := HTTPCacheSink(baseURL, "tenant-a", "fixture-jwt", http.DefaultClient)
	realBytes := []byte("genuine slot-cache bytes, not a placeholder")
	if err := sink("tenant-a.bin", realBytes); err != nil {
		t.Fatalf("HTTPCacheSink: %v", err)
	}

	mu.Lock()
	defer mu.Unlock()
	if len(*requests) != 1 {
		t.Fatalf("received %d request(s), want 1", len(*requests))
	}
	got := (*requests)[0]
	if got.path != "/v1/replication/enginecache" {
		t.Fatalf("posted to path %q, want /v1/replication/enginecache", got.path)
	}
	if got.tenantIDHeader != "tenant-a" {
		t.Fatalf("X-Tenant-Id header = %q, want tenant-a", got.tenantIDHeader)
	}
	if got.filenameHeader != "tenant-a.bin" {
		t.Fatalf("X-Engine-Cache-Filename header = %q, want tenant-a.bin", got.filenameHeader)
	}
	if got.authHeader != "Bearer fixture-jwt" {
		t.Fatalf("Authorization header = %q, want %q", got.authHeader, "Bearer fixture-jwt")
	}
	if string(got.body) != string(realBytes) {
		t.Fatalf("posted body = %q, want %q", got.body, realBytes)
	}
}

func TestHTTPCacheSink_UnreachableTarget_BoundedNotIndefinite(t *testing.T) {
	deadURL := "http://127.0.0.1:1" // real, always-refused port (privileged, unbound)
	sink := HTTPCacheSink(deadURL, "tenant-a", "", &http.Client{Timeout: 300 * time.Millisecond})
	start := time.Now()
	err := sink("x.bin", []byte("data"))
	elapsed := time.Since(start)
	if err == nil {
		t.Fatalf("HTTPCacheSink against an unreachable target: want a genuine error, got nil")
	}
	if elapsed > 8*time.Second {
		t.Fatalf("HTTPCacheSink against an unreachable target took %s, want well under 8s (bounded retry)", elapsed)
	}
}

func TestTransferEngineCache_DeliversRealFileBytesToEveryRealSink(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "tenant-a.bin")
	realBytes := []byte("a real slot-cache payload written by the engine")
	if err := os.WriteFile(path, realBytes, 0o600); err != nil {
		t.Fatalf("write fixture file: %v", err)
	}

	destA := t.TempDir()
	destB := t.TempDir()
	cache := EngineCacheFile{TenantID: "tenant-a", Path: path}
	err := TransferEngineCache(cache, []AdapterSink{FileAdapterSink(destA), FileAdapterSink(destB)})
	if err != nil {
		t.Fatalf("TransferEngineCache: %v", err)
	}

	for _, dest := range []string{destA, destB} {
		got, readErr := os.ReadFile(filepath.Join(dest, "tenant-a.bin"))
		if readErr != nil {
			t.Fatalf("read transferred file in %s: %v", dest, readErr)
		}
		if string(got) != string(realBytes) {
			t.Fatalf("transferred bytes in %s = %q, want %q", dest, got, realBytes)
		}
	}
}

func TestTransferEngineCache_OverRealHTTPToAReceivingHTTPServer(t *testing.T) {
	// End-to-end: a real file on disk -> TransferEngineCache ->
	// HTTPCacheSink -> a real HTTP POST -> a real receiving server that
	// writes the real bytes it received to its own local disk - the
	// FULL cross-node transfer path (FR-007/FR-012), minus only the
	// production HTTP/3+mTLS transport (an httptest.Server + plain
	// http.Client stand in for it, matching forwarder_test.go's own
	// established precedent for testing this codebase's cross-node HTTP
	// logic without a live HTTP/3+mTLS listener).
	receiveDir := t.TempDir()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		filename := r.Header.Get("X-Engine-Cache-Filename")
		body := make([]byte, r.ContentLength)
		_, _ = r.Body.Read(body)
		if err := os.WriteFile(filepath.Join(receiveDir, filename), body, 0o600); err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(srv.Close)

	srcDir := t.TempDir()
	path := filepath.Join(srcDir, "tenant-a.bin")
	realBytes := []byte("real end-to-end transferred payload")
	if err := os.WriteFile(path, realBytes, 0o600); err != nil {
		t.Fatalf("write fixture file: %v", err)
	}

	cache := EngineCacheFile{TenantID: "tenant-a", Path: path}
	sink := HTTPCacheSink(srv.URL, "tenant-a", "", http.DefaultClient)
	if err := TransferEngineCache(cache, []AdapterSink{sink}); err != nil {
		t.Fatalf("TransferEngineCache over real HTTP: %v", err)
	}

	got, err := os.ReadFile(filepath.Join(receiveDir, "tenant-a.bin"))
	if err != nil {
		t.Fatalf("read received file: %v", err)
	}
	if string(got) != string(realBytes) {
		t.Fatalf("received bytes = %q, want %q", got, realBytes)
	}
}
