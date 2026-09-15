package audit

import (
	"fmt"
	"sync"
	"testing"
)

func appendFive(l *Log) {
	l.Append("alice", "model:create", "profile/fast", "allow")
	l.Append("bob", "model:delete", "profile/coder", "deny")
	l.Append("alice", "tenant:manage", "tenant/acme", "allow")
	l.Append("carol", "model:infer", "profile/vision", "allow")
	l.Append("bob", "apikey:rotate", "key/xyz", "allow")
}

func TestVerifyChain_CleanChainPasses(t *testing.T) {
	l := NewLog()
	appendFive(l)

	ok, brokenAt := l.VerifyChain()
	if !ok {
		t.Fatalf("expected a clean, untampered chain to verify, got brokenAt=%d", brokenAt)
	}
}

func TestEntries_ReturnsACopyNotTheLiveSlice(t *testing.T) {
	l := NewLog()
	appendFive(l)

	got := l.Entries()
	if len(got) != 5 {
		t.Fatalf("expected 5 entries, got %d", len(got))
	}
	got[0].Decision = "mutated-via-returned-slice"

	if l.entries[0].Decision == "mutated-via-returned-slice" {
		t.Fatal("expected Entries() to return a copy - mutating the returned slice must not affect the stored log")
	}
}

func TestVerifyChain_TamperedMiddleEntryDetected(t *testing.T) {
	l := NewLog()
	appendFive(l)

	// Tamper with entry 2's content WITHOUT recomputing its hash - the
	// realistic shape of tampering (an attacker editing stored data
	// directly, not re-deriving a consistent chain).
	l.entries[2].Decision = "allow-forged"

	ok, brokenAt := l.VerifyChain()
	if ok {
		t.Fatalf("expected a tampered middle entry to be detected, got ok=true")
	}
	if brokenAt != 2 {
		t.Fatalf("expected brokenAt=2 (the tampered entry), got %d", brokenAt)
	}
}

// TestVerifyChain_DoesNotCatchDeletionRecomputedForward proves the exact
// honest boundary Constitution §11.4.268 names: an actor who deletes an
// entry AND recomputes every hash after it forward produces a chain that
// is STILL internally self-consistent. The hash chain alone cannot detect
// this - only a periodic anchor can (see the next test). This test exists
// so the limitation is proven, not merely asserted in a comment.
func TestVerifyChain_DoesNotCatchDeletionRecomputedForward(t *testing.T) {
	l := NewLog()
	appendFive(l)

	tampered := NewLog()
	for i, e := range l.entries {
		if i == 2 {
			continue // delete entry 2
		}
		tampered.Append(e.Actor, e.Action, e.Resource, e.Decision)
	}

	ok, brokenAt := tampered.VerifyChain()
	if !ok {
		t.Fatalf("expected chain-alone verification to be FOOLED by a deleted-and-recomputed-forward entry (proving the honest boundary), but it caught the tamper at %d", brokenAt)
	}
}

// TestVerifyAgainstAnchor_DetectsWhatChainAloneCannot proves the anchor
// mechanism catches the exact case the previous test showed chain-alone
// verification missing.
func TestVerifyAgainstAnchor_DetectsWhatChainAloneCannot(t *testing.T) {
	l := NewLog()
	appendFive(l)
	anchor := l.Anchor()

	tampered := NewLog()
	for i, e := range l.entries {
		if i == 2 {
			continue // delete entry 2, then recompute forward
		}
		tampered.Append(e.Actor, e.Action, e.Resource, e.Decision)
	}

	if ok, _ := tampered.VerifyChain(); !ok {
		t.Fatalf("precondition failed: expected the recomputed-forward chain to still pass chain-alone verification")
	}
	if tampered.VerifyAgainstAnchor(anchor) {
		t.Fatalf("expected VerifyAgainstAnchor to detect the deleted entry via the pre-recorded anchor, but it reported clean")
	}
}

// TestVerifyAgainstAnchor_DetectsTailTruncation proves plain truncation
// (entries removed from the end, nothing recomputed) is caught too.
func TestVerifyAgainstAnchor_DetectsTailTruncation(t *testing.T) {
	l := NewLog()
	appendFive(l)
	anchor := l.Anchor()

	truncated := NewLog()
	for _, e := range l.entries[:3] {
		truncated.Append(e.Actor, e.Action, e.Resource, e.Decision)
	}

	if truncated.VerifyAgainstAnchor(anchor) {
		t.Fatalf("expected VerifyAgainstAnchor to detect a truncated tail (3 entries vs anchored 5), but it reported clean")
	}
}

// TestVerifyAgainstAnchor_CleanLogPasses is the negative control (per
// Constitution §11.4.201's false-positive guard): a log that has ONLY grown
// since the anchor was taken must still verify cleanly.
func TestVerifyAgainstAnchor_CleanLogPasses(t *testing.T) {
	l := NewLog()
	appendFive(l)
	anchor := l.Anchor()

	l.Append("dave", "tenant:manage", "tenant/acme", "deny")

	if !l.VerifyAgainstAnchor(anchor) {
		t.Fatalf("expected a log that only grew since the anchor to verify cleanly against it")
	}
}

// TestLog_ConcurrentAppendIsRaceFree is a real, previously-undiscovered
// concurrency defect this project's Constitution (§11.4.102 systematic
// debugging + the anti-bluff covenant's "never paper over a real race")
// requires be root-caused and fixed rather than silently avoided: Log's
// Append (and every other method touching l.entries) had NO synchronization
// at all, yet authz.Decider's ValidateToken/CheckRBAC/CheckQuota/
// CheckTenantBoundary each call Log.Append on EVERY authZ/authN decision -
// meaning any real concurrent HTTP load against the JWT-protected routes
// (T073's 1000-concurrent-request multi-tenancy isolation test being the
// first test in this codebase to genuinely drive that load) raced on this
// exact field.
//
// TDD RED (observed BEFORE the sync.Mutex fix, via `go test -race
// ./internal/audit/...`): the Go race detector reported a genuine
// `DATA RACE` between concurrent `Append` calls' writes to `l.entries`
// (and the resulting slice header) - not a flaky/theoretical race, an
// actually-triggered one on every run of this test at -race. This test
// stays in the suite permanently as the regression guard: it drives
// `concurrentAppends` goroutines each calling Append exactly once,
// asserts the resulting log holds EXACTLY that many entries (a lost
// update under a real race would under-count), and asserts the full
// chain still verifies (a torn/interleaved write under a real race could
// leave `entries` internally inconsistent even if the count happened to
// come out right).
func TestLog_ConcurrentAppendIsRaceFree(t *testing.T) {
	const concurrentAppends = 200
	l := NewLog()

	var wg sync.WaitGroup
	wg.Add(concurrentAppends)
	for i := 0; i < concurrentAppends; i++ {
		go func(i int) {
			defer wg.Done()
			l.Append(fmt.Sprintf("actor-%d", i), "model:view", fmt.Sprintf("profile/%d", i), "allow")
		}(i)
	}
	wg.Wait()

	got := l.Entries()
	if len(got) != concurrentAppends {
		t.Fatalf("expected exactly %d entries after %d concurrent Append calls, got %d (a lost update under a real race)", concurrentAppends, concurrentAppends, len(got))
	}
	if ok, brokenAt := l.VerifyChain(); !ok {
		t.Fatalf("expected the chain built from %d concurrent Append calls to verify cleanly, but it broke at index %d (a torn/interleaved write under a real race)", concurrentAppends, brokenAt)
	}
}

// TestLog_ConcurrentReadsAndWritesAreRaceFree drives Append concurrently
// WITH VerifyChain/Entries/Anchor/VerifyAgainstAnchor - the exact mixed
// read/write pattern this daemon's real HTTP routes produce under
// concurrent load (routes_audit.go's GET /v1/audit/entries and
// GET /v1/audit/verify can be queried by an operator at any moment while
// other requests are still landing new Append calls via RequireJWT/
// CheckRBAC/CheckTenantBoundary).
func TestLog_ConcurrentReadsAndWritesAreRaceFree(t *testing.T) {
	const concurrentAppends = 200
	l := NewLog()

	var wg sync.WaitGroup
	wg.Add(concurrentAppends * 2)
	for i := 0; i < concurrentAppends; i++ {
		go func(i int) {
			defer wg.Done()
			l.Append(fmt.Sprintf("actor-%d", i), "model:view", fmt.Sprintf("profile/%d", i), "allow")
		}(i)
		go func() {
			defer wg.Done()
			l.VerifyChain()
			l.Entries()
			anchor := l.Anchor()
			l.VerifyAgainstAnchor(anchor)
		}()
	}
	wg.Wait()

	if len(l.Entries()) != concurrentAppends {
		t.Fatalf("expected exactly %d entries after %d concurrent Append calls interleaved with concurrent reads, got %d", concurrentAppends, concurrentAppends, len(l.Entries()))
	}
}
