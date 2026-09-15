package raft

import (
	"encoding/json"
	"testing"
	"time"

	hraft "github.com/hashicorp/raft"
)

// TestApply_AcquireLock_GrantsWhenFree proves a fresh key is granted to the
// first acquirer.
func TestApply_AcquireLock_GrantsWhenFree(t *testing.T) {
	fsm := NewClusterFSM()
	now := time.Now()
	data := mustCommand(t, Command{
		Type:          CommandAcquireLock,
		LockKey:       "model:llama-3-70b",
		LockHolder:    "node-a",
		LockNow:       now,
		LockExpiresAt: now.Add(time.Minute),
	})
	if resp := fsm.Apply(&hraft.Log{Data: data}); resp != nil {
		t.Fatalf("apply acquire on a free key: unexpected error %v", resp)
	}
	state := fsm.State()
	entry, held := state.Locks["model:llama-3-70b"]
	if !held {
		t.Fatalf("expected the lock to be held after a successful acquire")
	}
	if entry.Holder != "node-a" {
		t.Fatalf("entry.Holder = %q, want %q", entry.Holder, "node-a")
	}
}

// TestApply_AcquireLock_RefusedWhenHeldAndNotExpired proves a second
// acquirer is refused (via Apply's response, never silently granted) while
// the first holder's lease has not yet expired - the core linearization
// guarantee FR-029 requires.
func TestApply_AcquireLock_RefusedWhenHeldAndNotExpired(t *testing.T) {
	fsm := NewClusterFSM()
	now := time.Now()

	first := mustCommand(t, Command{
		Type: CommandAcquireLock, LockKey: "k", LockHolder: "node-a",
		LockNow: now, LockExpiresAt: now.Add(time.Minute),
	})
	if resp := fsm.Apply(&hraft.Log{Data: first}); resp != nil {
		t.Fatalf("apply first acquire: unexpected error %v", resp)
	}

	second := mustCommand(t, Command{
		Type: CommandAcquireLock, LockKey: "k", LockHolder: "node-b",
		LockNow: now.Add(time.Second), LockExpiresAt: now.Add(2 * time.Minute),
	})
	resp := fsm.Apply(&hraft.Log{Data: second})
	if resp == nil {
		t.Fatalf("expected the second acquire to be refused while the first holder's lease is unexpired, got nil")
	}
	if _, ok := resp.(error); !ok {
		t.Fatalf("expected Apply's refusal response to be an error value, got %T", resp)
	}

	state := fsm.State()
	if state.Locks["k"].Holder != "node-a" {
		t.Fatalf("the refused acquire must not have changed the holder: got %q, want %q", state.Locks["k"].Holder, "node-a")
	}
}

// TestApply_AcquireLock_GrantedAfterExpiry proves a lock becomes acquirable
// by a different holder once its LockNow-vs-ExpiresAt comparison shows the
// prior lease has expired - proving TTL expiry is real, not decorative.
func TestApply_AcquireLock_GrantedAfterExpiry(t *testing.T) {
	fsm := NewClusterFSM()
	now := time.Now()

	first := mustCommand(t, Command{
		Type: CommandAcquireLock, LockKey: "k", LockHolder: "node-a",
		LockNow: now, LockExpiresAt: now.Add(time.Second),
	})
	if resp := fsm.Apply(&hraft.Log{Data: first}); resp != nil {
		t.Fatalf("apply first acquire: unexpected error %v", resp)
	}

	afterExpiry := mustCommand(t, Command{
		Type: CommandAcquireLock, LockKey: "k", LockHolder: "node-b",
		LockNow: now.Add(2 * time.Second), LockExpiresAt: now.Add(3 * time.Second),
	})
	if resp := fsm.Apply(&hraft.Log{Data: afterExpiry}); resp != nil {
		t.Fatalf("apply acquire after prior lease expired: unexpected error %v", resp)
	}

	state := fsm.State()
	if state.Locks["k"].Holder != "node-b" {
		t.Fatalf("expected node-b to hold the lock after the prior lease expired, got %q", state.Locks["k"].Holder)
	}
}

// TestApply_ReleaseLock_ByHolderSucceedsByOtherFails proves Release only
// lets the real holder clear their own lock.
func TestApply_ReleaseLock_ByHolderSucceedsByOtherFails(t *testing.T) {
	fsm := NewClusterFSM()
	now := time.Now()

	acquire := mustCommand(t, Command{
		Type: CommandAcquireLock, LockKey: "k", LockHolder: "node-a",
		LockNow: now, LockExpiresAt: now.Add(time.Minute),
	})
	if resp := fsm.Apply(&hraft.Log{Data: acquire}); resp != nil {
		t.Fatalf("apply acquire: unexpected error %v", resp)
	}

	badRelease := mustCommand(t, Command{Type: CommandReleaseLock, LockKey: "k", LockHolder: "node-b"})
	resp := fsm.Apply(&hraft.Log{Data: badRelease})
	if resp == nil {
		t.Fatalf("expected release by a non-holder to be refused, got nil")
	}
	if state := fsm.State(); state.Locks["k"].Holder != "node-a" {
		t.Fatalf("a refused release must not have cleared the lock; holder = %q", state.Locks["k"].Holder)
	}

	goodRelease := mustCommand(t, Command{Type: CommandReleaseLock, LockKey: "k", LockHolder: "node-a"})
	if resp := fsm.Apply(&hraft.Log{Data: goodRelease}); resp != nil {
		t.Fatalf("apply release by the real holder: unexpected error %v", resp)
	}
	if _, held := fsm.State().Locks["k"]; held {
		t.Fatalf("expected the lock to be gone after the real holder released it")
	}
}

// TestApply_ReleaseLock_OfAbsentKeyIsIdempotentNoOp proves releasing a key
// nobody holds (already released, or never acquired) is a safe no-op, never
// an error - a caller racing its own release against a TTL expiry must not
// be punished for the race.
func TestApply_ReleaseLock_OfAbsentKeyIsIdempotentNoOp(t *testing.T) {
	fsm := NewClusterFSM()
	release := mustCommand(t, Command{Type: CommandReleaseLock, LockKey: "never-held", LockHolder: "node-a"})
	if resp := fsm.Apply(&hraft.Log{Data: release}); resp != nil {
		t.Fatalf("releasing an absent key must be a no-op, got error %v", resp)
	}
}

// TestApply_LockCommandsDeterministic proves the lock state, like node
// membership, replays byte-identically given the same log sequence.
func TestApply_LockCommandsDeterministic(t *testing.T) {
	now := time.Now()
	entries := []Command{
		{Type: CommandAcquireLock, LockKey: "k", LockHolder: "node-a", LockNow: now, LockExpiresAt: now.Add(time.Minute)},
		{Type: CommandAcquireLock, LockKey: "k", LockHolder: "node-b", LockNow: now, LockExpiresAt: now.Add(time.Minute)},
		{Type: CommandReleaseLock, LockKey: "k", LockHolder: "node-a"},
		{Type: CommandAcquireLock, LockKey: "k", LockHolder: "node-b", LockNow: now, LockExpiresAt: now.Add(time.Minute)},
	}

	replay := func() []byte {
		fsm := NewClusterFSM()
		for _, cmd := range entries {
			data := mustCommand(t, cmd)
			fsm.Apply(&hraft.Log{Data: data})
		}
		b, err := json.Marshal(fsm.State())
		if err != nil {
			t.Fatalf("marshal state: %v", err)
		}
		return b
	}

	b1 := replay()
	b2 := replay()
	if string(b1) != string(b2) {
		t.Fatalf("lock Apply is not deterministic: %s != %s", b1, b2)
	}
}
