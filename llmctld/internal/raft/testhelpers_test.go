package raft

import (
	"bytes"
	"io"
)

// memorySink is a minimal in-memory hraft.SnapshotSink for testing
// Persist/Restore round-trips without touching disk.
type memorySink struct {
	buf bytes.Buffer
}

func newMemorySink() *memorySink { return &memorySink{} }

func (s *memorySink) Write(p []byte) (int, error) { return s.buf.Write(p) }
func (s *memorySink) Close() error                { return nil }
func (s *memorySink) ID() string                  { return "test-snapshot" }
func (s *memorySink) Cancel() error               { return nil }

func (s *memorySink) reader() io.ReadCloser {
	return io.NopCloser(bytes.NewReader(s.buf.Bytes()))
}
