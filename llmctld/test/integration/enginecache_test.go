// Package integration (enginecache_test.go): 003-kv-cache-replication
// User Story 2 (T012/T013/T014) - the real-engine-boot tests spec.md's
// Acceptance Scenarios 1-3 (quickstart.md Scenario 3) require: a REAL
// llama-server process, started with the real --slot-save-path flag
// (lib/scheduler.sh's T015 wiring), actually saving/restoring its own
// real attention-weight KV cache to/from a real on-disk file via its
// real POST /slots/:id_slot?action=save|restore HTTP endpoint
// (internal/executor.LocalExecutor.SaveSlot/RestoreSlot, T016).
//
// HONEST ENVIRONMENT BOUNDARY (Constitution §11.4.6/§11.4.27 - no fakes
// beyond unit tests, and no guessed/fabricated results): every test in
// this file requires a REAL, already-built llama-server binary AND a
// REAL, already-downloaded GGUF model file on the machine running
// `go test`. Neither is invented, mocked, or faked here - a test that
// cannot obtain both SKIPS with a fully-detailed, honest reason (never
// a silent pass, never a fabricated timing number), matching this
// project's own established T057/SC-017 precedent for a structurally
// identical "cannot construct a real measurement fixture in this
// environment" situation.
//
// In the environment this feature was implemented in, BOTH resolution
// paths below were exhausted and BOTH failed for a confirmed, real,
// investigated reason (not assumed): the vendored submodules/llama.cpp
// git submodule is pinned to commit 3f152073d7949fe99229d90eae65c22bdf154cae,
// and a direct `git fetch` of that EXACT commit against the real
// upstream (https://github.com/ggml-org/llama.cpp.git, and independently
// against git@github.com:ggml-org/llama.cpp.git) fails with the git
// server's own real error "remote error: upload-pack: not our ref
// 3f152073d7949fe99229d90eae65c22bdf154cae" - the pinned commit is not
// fetchable from the real upstream in this environment, so
// submodules/llama.cpp cannot be checked out, so lib/engine.sh's
// engine_build_llama cannot produce a real llama-server binary here,
// so LLMCTL_LLAMA_SERVER/the default build path both resolve to nothing
// real. This is disclosed here exactly as found - see this feature's
// own final report for the full command transcript that confirmed it.
package integration

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

// repoRootFromThisFile mirrors internal/executor/local_test.go's own
// llmctlBinPath helper: computed from this test file's own location via
// runtime.Caller, never an assumed working directory.
func repoRootFromThisFile(t *testing.T) string {
	t.Helper()
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller(0) failed - cannot locate this test file")
	}
	// <repo>/llmctld/test/integration/enginecache_test.go -> <repo>
	return filepath.Join(filepath.Dir(thisFile), "..", "..", "..")
}

// realLlamaServerFixture names the two REAL, external prerequisites
// every test in this file needs and reports, honestly and specifically,
// which (if any) are missing - never a generic "skipped" with no
// reason.
type realLlamaServerFixture struct {
	bin   string // real llama-server binary path
	model string // real .gguf model file path
}

// resolveRealLlamaServerFixture looks for a real, already-built
// llama-server binary (LLMCTL_LLAMA_SERVER env var, else the SAME
// default path lib/scheduler.sh's sched_build_launch itself resolves -
// "${LLMCTL_ROOT}/submodules/llama.cpp/build/bin/llama-server", read
// from this file's own repo-root computation) and a real,
// already-downloaded .gguf model file (LLMCTL_TEST_GGUF_MODEL env var -
// this project does not vendor a model file in-repo; downloading one is
// an explicit, separate, network-and-disk-heavy operator step, never
// performed implicitly by a test). Returns ok=false with a fully
// detailed reason via t.Skip's own message when either is missing -
// callers of this helper never need to Skip themselves.
func resolveRealLlamaServerFixture(t *testing.T) (fx realLlamaServerFixture, ok bool) {
	t.Helper()
	repoRoot := repoRootFromThisFile(t)

	bin := os.Getenv("LLMCTL_LLAMA_SERVER")
	if bin == "" {
		bin = filepath.Join(repoRoot, "submodules", "llama.cpp", "build", "bin", "llama-server")
	}
	binInfo, binErr := os.Stat(bin)
	binOK := binErr == nil && !binInfo.IsDir()

	model := os.Getenv("LLMCTL_TEST_GGUF_MODEL")
	modelOK := false
	if model != "" {
		if info, err := os.Stat(model); err == nil && !info.IsDir() {
			modelOK = true
		}
	}

	if !binOK || !modelOK {
		var reasons []string
		if !binOK {
			reasons = append(reasons, fmt.Sprintf(
				"no real llama-server binary at %q (set LLMCTL_LLAMA_SERVER, or build submodules/llama.cpp: "+
					"CONFIRMED in this environment, submodules/llama.cpp is pinned to commit "+
					"3f152073d7949fe99229d90eae65c22bdf154cae, which a direct `git fetch` against the real "+
					"upstream github.com/ggml-org/llama.cpp.git rejects with 'not our ref' - see this file's "+
					"own package doc comment)", bin))
		}
		if !modelOK {
			reasons = append(reasons, "no real .gguf model file configured (set LLMCTL_TEST_GGUF_MODEL to an "+
				"already-downloaded real model file - this project does not vendor one in-repo)")
		}
		t.Skipf("SKIP (honest, per Constitution §11.4.6/§11.4.27 - never a fabricated result): "+
			"a real booted llama-server is required for this test and could not be obtained here: %v", reasons)
	}
	return realLlamaServerFixture{bin: bin, model: model}, true
}

// bootedRealLlamaServer is a real, running llama-server subprocess this
// file's tests drive over its real OpenAI-compatible + real
// /slots/:id_slot HTTP API - no mock, no fake, a genuine child process.
type bootedRealLlamaServer struct {
	cmd     *exec.Cmd
	baseURL string
}

// bootRealLlamaServer starts fx.bin as a real subprocess, bound to a
// real locally-reserved free TCP port, with the real --slot-save-path
// flag pointing at slotSaveDir (T015's own real launch-flag wiring,
// exercised here directly rather than through bin/llmctl's scheduler,
// since this test needs a single, directly-controlled long-lived
// process it can send explicit save/restore/completion calls to). Waits
// for the real engine's own /health endpoint to report ready before
// returning - never assumes a fixed boot delay.
func bootRealLlamaServer(t *testing.T, fx realLlamaServerFixture, slotSaveDir string) *bootedRealLlamaServer {
	t.Helper()
	port := reserveFreePort(t)
	baseURL := fmt.Sprintf("http://127.0.0.1:%d", port)

	cmd := exec.Command(fx.bin,
		"--model", fx.model,
		"--host", "127.0.0.1",
		"--port", fmt.Sprintf("%d", port),
		"--ctx-size", "4096",
		"--slot-save-path", slotSaveDir,
	)
	cmd.Stdout = os.Stderr // surfaced under `go test -v`, never silently discarded
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		t.Fatalf("start real llama-server: %v", err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	})

	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		resp, err := http.Get(baseURL + "/health")
		if err == nil {
			_ = resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return &bootedRealLlamaServer{cmd: cmd, baseURL: baseURL}
			}
		}
		time.Sleep(200 * time.Millisecond)
	}
	t.Fatalf("real llama-server at %s never became healthy within 60s", baseURL)
	return nil
}

// reserveFreePort asks the OS for a real free TCP port by binding then
// immediately releasing it - the SAME technique
// internal/replication/forwarder_test.go's own unreachable-port test
// already uses in this codebase, applied here to find a REAL usable
// port rather than a guaranteed-dead one.
func reserveFreePort(t *testing.T) int {
	t.Helper()
	ln, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve a free port: %v", err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	if err := ln.Close(); err != nil {
		t.Fatalf("close port reservation listener: %v", err)
	}
	return port
}

// driveRealCompletion issues one real /completion request against
// srv's real OpenAI-compatible-ish endpoint, forcing the engine to
// genuinely populate slot 0's real attention-weight KV cache with
// prompt's real tokens - required before a save/restore round trip has
// anything real to save.
func driveRealCompletion(t *testing.T, srv *bootedRealLlamaServer, prompt string, nPredict int) {
	t.Helper()
	body, _ := json.Marshal(map[string]any{
		"prompt":    prompt,
		"n_predict": nPredict,
		"id_slot":   0,
	})
	resp, err := http.Post(srv.baseURL+"/completion", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("real /completion request: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("real /completion request: status %d", resp.StatusCode)
	}
}

// TestEngineCache_RealSaveProducesARealInspectedFile is T012: confirm a
// real save via /slots/:id_slot?action=save actually produces a real
// file on disk - opened and inspected directly, never inferred from the
// HTTP call's own 200 status alone (this project's established
// "verify the artifact, not just the API response" discipline,
// Constitution §11.4.38/§11.4.108).
func TestEngineCache_RealSaveProducesARealInspectedFile(t *testing.T) {
	fx, ok := resolveRealLlamaServerFixture(t)
	if !ok {
		return // resolveRealLlamaServerFixture already called t.Skipf
	}
	slotSaveDir := t.TempDir()
	srv := bootRealLlamaServer(t, fx, slotSaveDir)

	driveRealCompletion(t, srv, "The quick brown fox jumps over the lazy dog.", 16)

	body, _ := json.Marshal(map[string]any{"filename": "t012.bin"})
	resp, err := http.Post(srv.baseURL+"/slots/0?action=save", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("real /slots/0?action=save request: %v", err)
	}
	respBody := new(bytes.Buffer)
	_, _ = respBody.ReadFrom(resp.Body)
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("real save request: status %d, body %s", resp.StatusCode, respBody.String())
	}

	// The API said 200 - now OPEN AND INSPECT the real file it claims to
	// have written, per this project's own established discipline.
	savedPath := filepath.Join(slotSaveDir, "t012.bin")
	info, err := os.Stat(savedPath)
	if err != nil {
		t.Fatalf("real save file %s does not exist despite a 200 response: %v", savedPath, err)
	}
	if info.Size() == 0 {
		t.Fatalf("real save file %s exists but is empty - the API's 200 response did not correspond to a real, usable artifact", savedPath)
	}
	data, err := os.ReadFile(savedPath)
	if err != nil {
		t.Fatalf("open+read real save file: %v", err)
	}
	if len(data) != int(info.Size()) {
		t.Fatalf("read %d bytes but Stat reported size %d - inconsistent real file", len(data), info.Size())
	}
}

// TestEngineCache_LiveEngine_MissingOrCorruptFile_FallsBackCorrectly is
// T013's live-engine companion to
// internal/replication's own (non-live-engine) TestEngineCache_
// MissingOrCorruptFile_FallsBackCorrectly: confirms the REAL engine's
// own /slots/:id_slot?action=restore genuinely rejects a corrupt file
// (rather than this project's own code merely assuming it would),
// closing the loop RestoreOrFallback's design (enginecache.go) depends
// on.
func TestEngineCache_LiveEngine_MissingOrCorruptFile_FallsBackCorrectly(t *testing.T) {
	fx, ok := resolveRealLlamaServerFixture(t)
	if !ok {
		return
	}
	slotSaveDir := t.TempDir()
	srv := bootRealLlamaServer(t, fx, slotSaveDir)

	// A real, non-empty, but genuinely garbled file - not the engine's
	// own real binary format.
	corruptPath := filepath.Join(slotSaveDir, "corrupt.bin")
	if err := os.WriteFile(corruptPath, []byte("this is not a real llama.cpp slot save file"), 0o600); err != nil {
		t.Fatalf("write corrupt fixture file: %v", err)
	}

	body, _ := json.Marshal(map[string]any{"filename": "corrupt.bin"})
	resp, err := http.Post(srv.baseURL+"/slots/0?action=restore", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("real /slots/0?action=restore request: %v", err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode == http.StatusOK {
		t.Fatalf("the real engine reported success restoring a genuinely corrupt file - this test's own corruption fixture is not corrupt enough to exercise the rejection path")
	}
	// A real rejection (non-2xx) is exactly what
	// internal/replication.RestoreOrFallback's restorer contract expects
	// to receive and fall back from (FR-008) - confirmed here against
	// the real engine, not merely assumed from documentation.
}

// TestEngineCache_RealTimingComparison_WithVsWithoutWarmCache is T014
// (spec.md SC-004): a genuine, captured before/after time-to-first-
// response measurement comparing a real warm-restore against full
// recomputation from the replayed token history - never a fabricated
// percentage.
func TestEngineCache_RealTimingComparison_WithVsWithoutWarmCache(t *testing.T) {
	fx, ok := resolveRealLlamaServerFixture(t)
	if !ok {
		return
	}

	longPrompt := longConversationFixture(t)

	// Run 1: cold - a fresh server, fresh completion, no warm cache.
	coldDir := t.TempDir()
	coldSrv := bootRealLlamaServer(t, fx, coldDir)
	coldStart := time.Now()
	driveRealCompletion(t, coldSrv, longPrompt, 1)
	coldElapsed := time.Since(coldStart)

	// Save the warm cache from a server that has ALREADY processed the
	// long prompt once (simulating "the primary already computed this
	// context").
	warmSourceDir := t.TempDir()
	warmSourceSrv := bootRealLlamaServer(t, fx, warmSourceDir)
	driveRealCompletion(t, warmSourceSrv, longPrompt, 1)
	saveBody, _ := json.Marshal(map[string]any{"filename": "warm.bin"})
	saveResp, err := http.Post(warmSourceSrv.baseURL+"/slots/0?action=save", "application/json", bytes.NewReader(saveBody))
	if err != nil {
		t.Fatalf("save warm cache: %v", err)
	}
	_ = saveResp.Body.Close()

	// Run 2: warm - a DIFFERENT fresh server, restoring the saved cache
	// BEFORE issuing the same completion request.
	warmTargetSrv := bootRealLlamaServer(t, fx, warmSourceDir) // same slot-save-path so the file is visible
	restoreBody, _ := json.Marshal(map[string]any{"filename": "warm.bin"})
	restoreResp, err := http.Post(warmTargetSrv.baseURL+"/slots/0?action=restore", "application/json", bytes.NewReader(restoreBody))
	if err != nil {
		t.Fatalf("restore warm cache: %v", err)
	}
	_ = restoreResp.Body.Close()
	if restoreResp.StatusCode != http.StatusOK {
		t.Fatalf("real restore of a genuinely-just-saved cache failed: status %d", restoreResp.StatusCode)
	}
	warmStart := time.Now()
	driveRealCompletion(t, warmTargetSrv, longPrompt, 1)
	warmElapsed := time.Since(warmStart)

	t.Logf("SC-004 real captured measurement: cold time-to-first-response=%s, warm(restored)=%s", coldElapsed, warmElapsed)
	if warmElapsed >= coldElapsed {
		t.Fatalf("SC-004: warm-restored time-to-first-response (%s) was NOT faster than cold recomputation (%s) on this fixture - the real measurement contradicts the claimed benefit for this prompt length; see this test's own doc comment for the fixture's real prompt length before assuming the fixture is too short", warmElapsed, coldElapsed)
	}
}

// longConversationFixture returns a real, long-enough prompt (many
// repeated real sentences) that recomputing its full context from
// scratch is not already near-instant - LLMCTL_TEST_LONG_PROMPT_REPEATS
// (default 200) controls its real length so an operator can tune it for
// their own hardware's real "not near-instant" threshold, matching this
// project's "configurable, not hardcoded" convention (checkpoint.go's
// CheckpointConfig doc comment) rather than a fixed guessed constant.
func longConversationFixture(t *testing.T) string {
	t.Helper()
	repeats := 200
	if v := os.Getenv("LLMCTL_TEST_LONG_PROMPT_REPEATS"); v != "" {
		if n, err := fmt.Sscanf(v, "%d", &repeats); err != nil || n != 1 {
			t.Fatalf("LLMCTL_TEST_LONG_PROMPT_REPEATS=%q is not a real integer", v)
		}
	}
	sentence := "The quick brown fox jumps over the lazy dog and considers what to do next. "
	out := make([]byte, 0, len(sentence)*repeats)
	for i := 0; i < repeats; i++ {
		out = append(out, sentence...)
	}
	return string(out)
}
