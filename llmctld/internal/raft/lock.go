// Package raft (lock.go): a Raft-backed distributed lock built on top of
// ClusterFSM's CommandAcquireLock/CommandReleaseLock handling (fsm.go).
// hashicorp/raft's replicated log already serializes every Apply() call
// across the whole cluster - this file wraps that guarantee in a named-lock
// API (Acquire/Release) so two nodes never concurrently download/load/
// update the same model into the shared pool (FR-029).
package raft

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/vasic-digital/llmctl/llmctld/internal/cluster"
)

// Lease is a held distributed lock, returned by Acquire and required to
// Release it again.
type Lease struct {
	Key       string
	Holder    string
	ExpiresAt time.Time
}

const (
	lockApplyTimeout = 5 * time.Second
	lockPollInterval = 25 * time.Millisecond
	// lockMaxWaitMultiple bounds how long Acquire will block waiting for a
	// contended key, as a multiple of the caller's own requested ttl. A
	// truly unbounded wait (matching hraft.Raft.Apply's own signature,
	// which always requires a timeout) is not a safe default for
	// production code with no cancellation mechanism, so this file picks
	// a generous-but-finite bound instead: long enough that a lock always
	// gets at least one full extra lease-cycle's worth of waiting (in
	// case the current holder renews right as this caller checks), short
	// enough that a genuinely stuck acquire fails loudly rather than
	// hanging forever.
	lockMaxWaitMultiple = 10
)

// Acquire blocks until "key" becomes available - via an explicit Release or
// via the current holder's lease TTL expiring - then claims it for ttl
// under this node's own ID as holder, via a real linearized Raft log entry.
// Because hashicorp/raft's log commit order is total across the whole
// cluster, whichever Acquire's log entry commits first wins outright: every
// other concurrent Acquire attempt's own Apply() deterministically observes
// the loser state (fsm.go's errLockHeldByAnother) and retries - so two
// nodes can never both believe they hold the same key at once.
func (n *Node) Acquire(key string, ttl time.Duration) (Lease, error) {
	return n.acquireAs(string(n.localID), key, ttl)
}

// acquireAs is Acquire's real implementation, parameterized on the holder
// identity - exported behavior only ever uses n's own localID (Acquire),
// but the tests in lock_test.go use this directly to prove a SECOND,
// distinct holder genuinely blocks on the same *Node's leader instance
// (a same-node holder-vs-holder race is a stronger proof than a
// same-holder no-op re-acquire would be).
func (n *Node) acquireAs(holder, key string, ttl time.Duration) (Lease, error) {
	deadline := time.Now().Add(ttl * lockMaxWaitMultiple)
	for {
		now := time.Now()
		expiresAt := now.Add(ttl)
		cmd := Command{
			Type:          CommandAcquireLock,
			LockKey:       key,
			LockHolder:    holder,
			LockNow:       now,
			LockExpiresAt: expiresAt,
		}
		data, err := json.Marshal(cmd)
		if err != nil {
			return Lease{}, fmt.Errorf("raft: acquire lock %q: marshal command: %w", key, err)
		}

		future := n.raft.Apply(data, lockApplyTimeout)
		if err := future.Error(); err != nil {
			return Lease{}, fmt.Errorf("raft: acquire lock %q: %w", key, err)
		}
		if resp := future.Response(); resp != nil {
			if _, isErr := resp.(error); isErr {
				if time.Now().After(deadline) {
					return Lease{}, fmt.Errorf("raft: acquire lock %q: timed out after %s waiting for release or TTL expiry", key, ttl*lockMaxWaitMultiple)
				}
				time.Sleep(lockPollInterval)
				continue
			}
			// A non-nil, non-error Response would be a fsm.go contract
			// violation (CommandAcquireLock only ever returns nil or an
			// error - see fsm.go's Apply) - treat it as a hard failure
			// rather than silently proceeding as if it were success.
			return Lease{}, fmt.Errorf("raft: acquire lock %q: unexpected FSM response type %T", key, resp)
		}
		return Lease{Key: key, Holder: holder, ExpiresAt: expiresAt}, nil
	}
}

// Release clears lease's lock via a real linearized Raft log entry.
// Releasing a lease this node does not (or no longer) hold returns an
// error (fsm.go's errNotLockHolder) rather than silently succeeding or
// silently clearing someone else's lock; releasing an already-absent key
// (already expired-and-reclaimed, or already released) is an idempotent
// no-op, matching fsm.go's CommandReleaseLock handling exactly.
func (n *Node) Release(lease Lease) error {
	cmd := Command{Type: CommandReleaseLock, LockKey: lease.Key, LockHolder: lease.Holder}
	data, err := json.Marshal(cmd)
	if err != nil {
		return fmt.Errorf("raft: release lock %q: marshal command: %w", lease.Key, err)
	}

	future := n.raft.Apply(data, lockApplyTimeout)
	if err := future.Error(); err != nil {
		return fmt.Errorf("raft: release lock %q: %w", lease.Key, err)
	}
	if resp := future.Response(); resp != nil {
		if respErr, isErr := resp.(error); isErr {
			return fmt.Errorf("raft: release lock %q: %w", lease.Key, respErr)
		}
		return fmt.Errorf("raft: release lock %q: unexpected FSM response type %T", lease.Key, resp)
	}
	return nil
}

// Locks returns a snapshot of every currently-held distributed lock, for
// callers (e.g. a future T058 HTTP status endpoint) that need to inspect
// lock state without reaching into internal FSM fields.
func (n *Node) Locks() map[string]cluster.LockEntry {
	return n.fsm.State().Locks
}
