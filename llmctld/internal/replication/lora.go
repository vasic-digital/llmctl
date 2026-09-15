// Package replication (lora.go): synchronous LoRA adapter replication on
// creation (FR-027). Unlike wal.go/checkpoint.go's KVState (necessarily
// an abstraction, since a running inference engine's in-memory attention
// state is never directly reachable across llmctld's control-plane/
// data-plane split), a LoRA adapter IS a real, ordinary file on disk
// (a GGUF file) before it is ever loaded into an engine - so this file
// replicates REAL bytes, genuinely, with no abstraction gap.
package replication

import (
	"fmt"
	"os"
	"path/filepath"
)

// LoraAdapter identifies one on-disk LoRA adapter artifact.
type LoraAdapter struct {
	// Name is the adapter's replicated filename (used as the destination
	// filename at every sink) - kept separate from Path so a sink can
	// name the file identically across nodes regardless of the source's
	// local directory layout.
	Name string
	// Path is the adapter's real local filesystem path to read from.
	Path string
}

// AdapterSink delivers adapter bytes to one destination. Defined as a
// function type (not a concrete cross-node client) so ReplicateAdapter's
// synchronous-fan-out logic is testable without a real network -
// FileAdapterSink is the real, file-based implementation this package's
// own tests use; a genuinely cross-node sink (e.g. an HTTP PUT to
// another node's API) is a T058-extension concern built elsewhere, not
// needed for this package's own correctness.
type AdapterSink func(name string, data []byte) error

// FileAdapterSink returns an AdapterSink that writes data to
// filepath.Join(destDir, name) on the real local filesystem.
func FileAdapterSink(destDir string) AdapterSink {
	return func(name string, data []byte) error {
		return os.WriteFile(filepath.Join(destDir, name), data, 0o600)
	}
}

// ReplicateAdapter reads adapter's real file bytes ONCE and delivers them
// to every sink synchronously (in order, not concurrently - simplicity
// over throughput, since FR-027 only requires "replicated synchronously
// on creation" completes before the create operation returns, not that
// it completes as fast as possible). It returns an error, and does not
// attempt to roll back sinks that already succeeded, the moment any sink
// fails to accept the adapter - FR-027's synchronous guarantee means the
// caller MUST know replication did not complete everywhere; a caller
// that receives an error here should treat the adapter creation itself
// as failed and retry, not assume partial success.
func ReplicateAdapter(adapter LoraAdapter, sinks []AdapterSink) error {
	data, err := os.ReadFile(adapter.Path)
	if err != nil {
		return fmt.Errorf("replication: read LoRA adapter %q: %w", adapter.Path, err)
	}
	for i, sink := range sinks {
		if err := sink(adapter.Name, data); err != nil {
			return fmt.Errorf("replication: replicate LoRA adapter %q to sink %d of %d: %w", adapter.Name, i+1, len(sinks), err)
		}
	}
	return nil
}
