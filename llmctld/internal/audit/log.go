// Package audit implements the tamper-evident audit log Constitution
// §11.4.268 and FR-054/FR-035 require for every authZ/authN decision:
// each entry hash-chains to the previous one, and a periodic Anchor
// (head hash + entry count) catches what the chain alone cannot - a
// deleted entry with every subsequent hash correctly recomputed forward,
// or a tail truncation (see log_test.go's honest-boundary tests).
package audit

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"sync"
)

// Entry is one audit record: an authZ/authN decision with its position in
// the chain and the hash linking it to the previous entry.
type Entry struct {
	Seq      int
	Actor    string
	Action   string
	Resource string
	Decision string
	PrevHash string
	Hash     string
}

// Log is an in-memory, append-only, hash-chained audit log. (Persistence -
// writing entries to the tenant-scoped bbolt store from T064/T072 - is a
// Phase 11 wiring concern; this Foundational package owns the chaining and
// verification primitive itself.)
//
// mu guards every access to entries. This was NOT true when Log was first
// implemented (Phase 2, T013) - a real, previously-undiscovered data race
// was found and root-caused during T073 (Phase 11, US9): authz.Decider's
// ValidateToken/CheckRBAC/CheckQuota/CheckTenantBoundary each call
// Log.Append on EVERY authZ/authN decision this daemon makes, so ANY real
// concurrent HTTP load against the JWT-protected routes (T073's
// 1000-concurrent-request multi-tenancy isolation test is the first test
// in this codebase to genuinely drive that load) raced on the unsynchronized
// entries slice - confirmed via `go test -race` reporting a genuine
// DATA RACE on every run before this fix (see log_test.go's
// TestLog_ConcurrentAppendIsRaceFree/TestLog_ConcurrentReadsAndWritesAreRaceFree,
// added first as the RED, then fixed here as the GREEN). A single
// sync.Mutex is sufficient - this log's write volume is one Append per
// authZ decision, never a hot path needing finer-grained locking.
type Log struct {
	mu      sync.Mutex
	entries []Entry
}

// NewLog returns an empty audit log.
func NewLog() *Log {
	return &Log{}
}

// Append records one authZ/authN decision, chaining it to the previous
// entry's hash, and returns the recorded Entry (including its own hash).
func (l *Log) Append(actor, action, resource, decision string) Entry {
	l.mu.Lock()
	defer l.mu.Unlock()

	prevHash := ""
	if n := len(l.entries); n > 0 {
		prevHash = l.entries[n-1].Hash
	}
	e := Entry{
		Seq:      len(l.entries),
		Actor:    actor,
		Action:   action,
		Resource: resource,
		Decision: decision,
		PrevHash: prevHash,
	}
	e.Hash = entryHash(e)
	l.entries = append(l.entries, e)
	return e
}

func entryHash(e Entry) string {
	h := sha256.New()
	_, _ = fmt.Fprintf(h, "%d|%s|%s|%s|%s|%s", e.Seq, e.Actor, e.Action, e.Resource, e.Decision, e.PrevHash) // hash.Hash.Write never returns an error, per its documented contract
	return hex.EncodeToString(h.Sum(nil))
}

// VerifyChain walks the entire stored log, recomputing every entry's hash
// and checking it links correctly to the previous one. Returns ok=false
// and the index of the first inconsistency on a tampered MIDDLE entry or a
// broken link (reordering).
//
// Honest boundary (proven by TestVerifyChain_DoesNotCatchDeletionRecomputedForward):
// an actor who deletes an entry and recomputes every hash after it forward
// produces a chain that is STILL internally self-consistent - VerifyChain
// alone cannot see that. Use VerifyAgainstAnchor with a pre-recorded Anchor
// to catch that case and plain tail truncation.
func (l *Log) VerifyChain() (ok bool, brokenAt int) {
	l.mu.Lock()
	defer l.mu.Unlock()

	prevHash := ""
	for i, e := range l.entries {
		if e.PrevHash != prevHash {
			return false, i
		}
		want := entryHash(Entry{
			Seq: e.Seq, Actor: e.Actor, Action: e.Action,
			Resource: e.Resource, Decision: e.Decision, PrevHash: e.PrevHash,
		})
		if want != e.Hash {
			return false, i
		}
		prevHash = e.Hash
	}
	return true, -1
}

// Anchor is a periodic snapshot of the chain's head: the entry count and
// head hash at the moment it was taken.
type Anchor struct {
	Count int
	Head  string
}

// Entries returns a copy of every entry currently stored, in append order.
// A copy (never the live internal slice) is returned so a caller
// inspecting the log for testing or reporting cannot mutate stored entries
// through the returned slice - Append/the audit trail itself remain the
// only mutation path.
func (l *Log) Entries() []Entry {
	l.mu.Lock()
	defer l.mu.Unlock()

	out := make([]Entry, len(l.entries))
	copy(out, l.entries)
	return out
}

// Anchor returns the current chain's anchor (count + head hash), meant to
// be recorded somewhere the log itself cannot rewrite (Constitution
// §11.4.268's "append to a location the producer can append to but not
// rewrite" - the concrete storage for that is a Phase 11 wiring concern).
func (l *Log) Anchor() Anchor {
	l.mu.Lock()
	defer l.mu.Unlock()

	head := ""
	if n := len(l.entries); n > 0 {
		head = l.entries[n-1].Hash
	}
	return Anchor{Count: len(l.entries), Head: head}
}

// VerifyAgainstAnchor returns false if the log has fewer entries than the
// anchor recorded (tail truncation or wholesale deletion), or if the entry
// AT the anchor's recorded position no longer has the anchored hash
// (deletion followed by recomputing the chain forward from that point).
// A log that has only grown since the anchor was taken verifies cleanly
// (TestVerifyAgainstAnchor_CleanLogPasses - the false-positive guard).
func (l *Log) VerifyAgainstAnchor(a Anchor) bool {
	l.mu.Lock()
	defer l.mu.Unlock()

	if len(l.entries) < a.Count {
		return false
	}
	if a.Count == 0 {
		return true
	}
	return l.entries[a.Count-1].Hash == a.Head
}
