package replication

import (
	"crypto/sha256"
	"os"
	"path/filepath"
	"testing"
)

// TestReplicateAdapter_WeightsAreByteIdenticalOnReplica proves the core
// FR-027 guarantee: after ReplicateAdapter returns, EVERY destination has
// the EXACT SAME bytes as the source adapter file - not merely "some
// file exists", a real byte-for-byte comparison (and a sha256 comparison
// as an independent second check) against real files on real disk.
func TestReplicateAdapter_WeightsAreByteIdenticalOnReplica(t *testing.T) {
	srcDir := t.TempDir()
	srcPath := filepath.Join(srcDir, "adapter.gguf")
	// Real, non-trivial content standing in for actual LoRA weight bytes -
	// large enough that a truncated/corrupted copy would be detectable.
	content := make([]byte, 4096)
	for i := range content {
		content[i] = byte(i % 251)
	}
	if err := os.WriteFile(srcPath, content, 0o600); err != nil {
		t.Fatalf("write source adapter file: %v", err)
	}

	replicaDirA := t.TempDir()
	replicaDirB := t.TempDir()

	adapter := LoraAdapter{Name: "my-adapter.gguf", Path: srcPath}
	sinks := []AdapterSink{FileAdapterSink(replicaDirA), FileAdapterSink(replicaDirB)}

	if err := ReplicateAdapter(adapter, sinks); err != nil {
		t.Fatalf("ReplicateAdapter: %v", err)
	}

	wantHash := sha256.Sum256(content)
	for _, dir := range []string{replicaDirA, replicaDirB} {
		gotPath := filepath.Join(dir, "my-adapter.gguf")
		got, err := os.ReadFile(gotPath)
		if err != nil {
			t.Fatalf("read replica file %q: %v", gotPath, err)
		}
		if len(got) != len(content) {
			t.Fatalf("replica %q has %d bytes, want %d", gotPath, len(got), len(content))
		}
		for i := range got {
			if got[i] != content[i] {
				t.Fatalf("replica %q diverges from source at byte %d: got %d, want %d", gotPath, i, got[i], content[i])
			}
		}
		gotHash := sha256.Sum256(got)
		if gotHash != wantHash {
			t.Fatalf("replica %q sha256 = %x, want %x", gotPath, gotHash, wantHash)
		}
	}
}

// TestReplicateAdapter_FailsIfAnySinkFails proves ReplicateAdapter
// surfaces a real failure rather than silently succeeding when one
// destination could not be written - FR-027's "synchronous" guarantee
// means the create operation must know replication did NOT complete
// everywhere.
func TestReplicateAdapter_FailsIfAnySinkFails(t *testing.T) {
	srcDir := t.TempDir()
	srcPath := filepath.Join(srcDir, "adapter.gguf")
	if err := os.WriteFile(srcPath, []byte("weights"), 0o600); err != nil {
		t.Fatalf("write source adapter file: %v", err)
	}

	goodDir := t.TempDir()
	adapter := LoraAdapter{Name: "adapter.gguf", Path: srcPath}
	sinks := []AdapterSink{
		FileAdapterSink(goodDir),
		FileAdapterSink(filepath.Join(t.TempDir(), "does-not-exist-parent-dir")), // write will fail: no such directory
	}

	if err := ReplicateAdapter(adapter, sinks); err == nil {
		t.Fatalf("ReplicateAdapter with one failing sink must return an error, got nil")
	}
}

// TestReplicateAdapter_MissingSourceFileFails proves a nonexistent source
// adapter path is a real, surfaced error - never a silent no-op success.
func TestReplicateAdapter_MissingSourceFileFails(t *testing.T) {
	adapter := LoraAdapter{Name: "ghost.gguf", Path: filepath.Join(t.TempDir(), "does-not-exist.gguf")}
	if err := ReplicateAdapter(adapter, []AdapterSink{FileAdapterSink(t.TempDir())}); err == nil {
		t.Fatalf("ReplicateAdapter with a missing source file must return an error, got nil")
	}
}
