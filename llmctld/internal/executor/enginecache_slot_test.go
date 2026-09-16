// enginecache_slot_test.go: 003-kv-cache-replication User Story 2 -
// SaveSlot/RestoreSlot's own request-construction/response-handling
// logic, proven against a REAL HTTP server implementing llama-server's
// documented /slots/:id_slot?action=save|restore wire contract (see
// local.go's own doc comment on this section for the honest boundary:
// this is NOT a substitute for a real booted llama-server, which
// test/integration's T012/T014 exercise separately and honestly SKIP in
// an environment where the pinned engine submodule cannot be fetched).
package executor

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// startFakeEngineSlotServer boots a real httptest.Server implementing
// EXACTLY the documented llama-server /slots/:id_slot?action=save|restore
// wire contract this file's doc comment describes: a POST to
// /slots/{id}?action={save|restore} with a JSON {"filename": "..."}
// body. wantStatus lets a caller simulate the real engine's own genuine
// rejection (e.g. 400 on a corrupt/missing file) without inventing a
// second, mocked transport - the HTTP layer here is completely real,
// only the process on the other end is a stand-in for llama-server
// itself (matching internal/replication/forwarder_test.go's own
// established convention for this codebase).
func startFakeEngineSlotServer(t *testing.T, wantStatus int) (baseURL string, lastPath *string, lastBody *engineSlotRequest) {
	t.Helper()
	var gotPath string
	var gotBody engineSlotRequest
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.String()
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
		w.WriteHeader(wantStatus)
		if wantStatus >= 200 && wantStatus < 300 {
			_, _ = w.Write([]byte(`{"id_slot":0,"filename":"` + gotBody.Filename + `"}`))
		} else {
			_, _ = w.Write([]byte(`{"error":"fixture rejection"}`))
		}
	}))
	t.Cleanup(srv.Close)
	return srv.URL, &gotPath, &gotBody
}

func TestLocalExecutor_SaveSlot_PostsRealRequestToDocumentedEndpoint(t *testing.T) {
	baseURL, lastPath, lastBody := startFakeEngineSlotServer(t, http.StatusOK)
	e := New(Config{})
	if err := e.SaveSlot(baseURL, 0, "tenant-a.bin"); err != nil {
		t.Fatalf("SaveSlot: unexpected error %v", err)
	}
	if *lastPath != "/slots/0?action=save" {
		t.Fatalf("SaveSlot posted to %q, want /slots/0?action=save", *lastPath)
	}
	if lastBody.Filename != "tenant-a.bin" {
		t.Fatalf("SaveSlot request body filename = %q, want tenant-a.bin", lastBody.Filename)
	}
}

func TestLocalExecutor_RestoreSlot_PostsRealRequestToDocumentedEndpoint(t *testing.T) {
	baseURL, lastPath, lastBody := startFakeEngineSlotServer(t, http.StatusOK)
	e := New(Config{})
	if err := e.RestoreSlot(baseURL, 3, "tenant-b.bin"); err != nil {
		t.Fatalf("RestoreSlot: unexpected error %v", err)
	}
	if *lastPath != "/slots/3?action=restore" {
		t.Fatalf("RestoreSlot posted to %q, want /slots/3?action=restore", *lastPath)
	}
	if lastBody.Filename != "tenant-b.bin" {
		t.Fatalf("RestoreSlot request body filename = %q, want tenant-b.bin", lastBody.Filename)
	}
}

func TestLocalExecutor_RestoreSlot_RealEngineRejection_ReturnsGenuineError(t *testing.T) {
	// Simulates the real engine's own genuine rejection of a corrupt/
	// unusable file (T013's "the engine's own binary-format parser
	// rejects it" class) - RestoreSlot must surface this as a real
	// error, never silently succeed.
	baseURL, _, _ := startFakeEngineSlotServer(t, http.StatusBadRequest)
	e := New(Config{})
	if err := e.RestoreSlot(baseURL, 0, "corrupt.bin"); err == nil {
		t.Fatalf("RestoreSlot against a rejecting engine: want a genuine error, got nil")
	}
}

func TestLocalExecutor_SaveSlot_EmptyFilename_RefusedWithoutAnyHTTPCall(t *testing.T) {
	called := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(srv.Close)

	e := New(Config{})
	err := e.SaveSlot(srv.URL, 0, "")
	if err == nil {
		t.Fatalf("SaveSlot with empty filename: want ErrEngineSlotFilenameInvalid, got nil")
	}
	if called {
		t.Fatalf("SaveSlot with an invalid filename made a real HTTP call - it must be refused BEFORE any call")
	}
}

func TestLocalExecutor_SaveSlot_PathLikeFilename_RefusedWithoutAnyHTTPCall(t *testing.T) {
	called := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(srv.Close)

	e := New(Config{})
	for _, bad := range []string{"../../etc/passwd", "/etc/passwd", "sub/dir.bin"} {
		if err := e.SaveSlot(srv.URL, 0, bad); err == nil {
			t.Fatalf("SaveSlot with path-like filename %q: want a refusal error, got nil", bad)
		}
	}
	if called {
		t.Fatalf("SaveSlot with a path-like filename made a real HTTP call - it must be refused BEFORE any call")
	}
}

func TestLocalExecutor_SaveSlot_UnreachableEngine_BoundedNotIndefinite(t *testing.T) {
	deadURL := "http://127.0.0.1:1" // real, always-refused privileged port
	e := New(Config{})
	start := time.Now()
	err := e.SaveSlot(deadURL, 0, "x.bin")
	elapsed := time.Since(start)
	if err == nil {
		t.Fatalf("SaveSlot against an unreachable engine: want a genuine error, got nil")
	}
	if elapsed > engineSlotRequestTimeout+5*time.Second {
		t.Fatalf("SaveSlot against an unreachable engine took %s, want well under its own %s timeout", elapsed, engineSlotRequestTimeout)
	}
}
