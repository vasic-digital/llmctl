package cluster

import "testing"

// TestPlace_ExactFit proves a candidate whose available resources exactly
// equal the request is selected, not rejected - "at least" not "strictly
// greater than" is the fits() boundary (FR-020).
func TestPlace_ExactFit(t *testing.T) {
	req := PlacementRequest{RAMMB: 1000, VRAMMB: 500, CPUCores: 2, NetworkMbps: 100}
	only := Node{
		ID:     "node-exact",
		Health: "healthy",
		Resources: Resources{
			RAMAvailMB:  1000,
			VRAMAvailMB: 500,
			CPUCores:    2,
			NetworkMbps: 100,
		},
	}

	got, err := Place([]Node{only}, req)
	if err != nil {
		t.Fatalf("Place() with an exact-fit candidate returned an error: %v", err)
	}
	if got.ID != "node-exact" {
		t.Fatalf("Place() = %q, want %q", got.ID, "node-exact")
	}
}

// TestPlace_OverBudgetRefusal proves Place refuses with a clear,
// informative error when NO candidate has enough capacity in every
// dimension - never silently picking an unfit node (FR-020, SC-014).
func TestPlace_OverBudgetRefusal(t *testing.T) {
	req := PlacementRequest{RAMMB: 8000, VRAMMB: 4000, CPUCores: 16, NetworkMbps: 1000}
	candidates := []Node{
		{
			ID:     "node-a",
			Health: "healthy",
			Resources: Resources{
				RAMAvailMB:  4000, // short on RAM
				VRAMAvailMB: 4000,
				CPUCores:    16,
				NetworkMbps: 1000,
			},
		},
		{
			ID:     "node-b",
			Health: "healthy",
			Resources: Resources{
				RAMAvailMB:  8000,
				VRAMAvailMB: 4000,
				CPUCores:    8, // short on CPU
				NetworkMbps: 1000,
			},
		},
	}

	_, err := Place(candidates, req)
	if err == nil {
		t.Fatalf("Place() with no fitting candidate must return an error, got nil")
	}
	msg := err.Error()
	for _, want := range []string{"no healthy candidate", "8000", "4000", "16", "1000"} {
		if !containsSubstring(msg, want) {
			t.Errorf("Place() error %q does not mention %q - error must be informative, not bare", msg, want)
		}
	}
}

// TestPlace_MultiCandidateBestFit proves that, among several fitting
// candidates, Place() picks the tightest fit (least leftover capacity
// after placement) rather than the first fitting node encountered - this
// is what makes it bin-packing rather than arbitrary first-fit. See
// leftoverScore's doc comment in placement.go for why best-fit was chosen.
//
// Every candidate here is exact-fit on VRAM/CPU/Network so only the RAM
// dimension varies, making the intended winner unambiguous by
// construction: node-tight leaves the least proportional RAM slack.
func TestPlace_MultiCandidateBestFit(t *testing.T) {
	req := PlacementRequest{RAMMB: 1000, VRAMMB: 500, CPUCores: 2, NetworkMbps: 100}
	exactOther := Resources{VRAMAvailMB: 500, CPUCores: 2, NetworkMbps: 100}

	loose := Node{ID: "node-loose", Health: "healthy", Resources: exactOther}
	loose.Resources.RAMAvailMB = 5000 // 4000MB leftover - loosest fit

	medium := Node{ID: "node-medium", Health: "healthy", Resources: exactOther}
	medium.Resources.RAMAvailMB = 1500 // 500MB leftover

	tight := Node{ID: "node-tight", Health: "healthy", Resources: exactOther}
	tight.Resources.RAMAvailMB = 1100 // 100MB leftover - tightest fit

	// Order deliberately does not match leftover ranking, to prove the
	// selection is by score, not by slice position.
	candidates := []Node{loose, tight, medium}

	for i := 0; i < 2; i++ {
		got, err := Place(candidates, req)
		if err != nil {
			t.Fatalf("run %d: Place() returned an unexpected error: %v", i, err)
		}
		if got.ID != "node-tight" {
			t.Fatalf("run %d: Place() = %q, want the tightest-fit candidate %q", i, got.ID, "node-tight")
		}
	}
}

// TestPlace_UnhealthyNodeSkippedInFavorOfHealthy proves an unhealthy node
// is never selected even when it reports abundant capacity that would
// otherwise make it the best (tightest... or here, loosest but only)
// available fit - health MUST gate selection ahead of raw numeric
// capacity (Constitution §11.4.133 target-system safety).
func TestPlace_UnhealthyNodeSkippedInFavorOfHealthy(t *testing.T) {
	req := PlacementRequest{RAMMB: 1000, VRAMMB: 500, CPUCores: 2, NetworkMbps: 100}

	unhealthyButHuge := Node{
		ID:     "node-unhealthy-huge",
		Health: "unhealthy",
		Resources: Resources{
			RAMAvailMB:  100000,
			VRAMAvailMB: 100000,
			CPUCores:    128,
			NetworkMbps: 100000,
		},
	}
	healthySmaller := Node{
		ID:     "node-healthy-small",
		Health: "healthy",
		Resources: Resources{
			RAMAvailMB:  1200,
			VRAMAvailMB: 600,
			CPUCores:    2,
			NetworkMbps: 150,
		},
	}

	got, err := Place([]Node{unhealthyButHuge, healthySmaller}, req)
	if err != nil {
		t.Fatalf("Place() returned an unexpected error: %v", err)
	}
	if got.ID != "node-healthy-small" {
		t.Fatalf("Place() = %q, want the only healthy candidate %q (the unhealthy node must never be selected)", got.ID, "node-healthy-small")
	}
}

// TestPlace_UnhealthyOnlyCandidateRefused proves that when the ONLY
// candidate with sufficient numeric capacity is unhealthy, Place refuses
// rather than falling back to it.
func TestPlace_UnhealthyOnlyCandidateRefused(t *testing.T) {
	req := PlacementRequest{RAMMB: 1000, VRAMMB: 500, CPUCores: 2, NetworkMbps: 100}
	onlyUnhealthy := Node{
		ID:     "node-unhealthy-only",
		Health: "unhealthy",
		Resources: Resources{
			RAMAvailMB:  100000,
			VRAMAvailMB: 100000,
			CPUCores:    128,
			NetworkMbps: 100000,
		},
	}

	_, err := Place([]Node{onlyUnhealthy}, req)
	if err == nil {
		t.Fatalf("Place() with only an unhealthy candidate must return an error, got nil")
	}
}

// TestPlace_Deterministic proves that repeated calls with the identical
// candidate list and request always return the identical winning node -
// no reliance on map/slice iteration order for tie-breaking (ties are
// broken by ascending Node.ID).
func TestPlace_Deterministic(t *testing.T) {
	req := PlacementRequest{RAMMB: 1000, VRAMMB: 500, CPUCores: 2, NetworkMbps: 100}

	// b and a are constructed to have an IDENTICAL leftoverScore (both
	// exact-fit on every dimension), so the tie-break rule (ascending
	// Node.ID) is what determinism actually exercises here.
	a := Node{ID: "a-node", Health: "healthy", Resources: Resources{RAMAvailMB: 1000, VRAMAvailMB: 500, CPUCores: 2, NetworkMbps: 100}}
	b := Node{ID: "b-node", Health: "healthy", Resources: Resources{RAMAvailMB: 1000, VRAMAvailMB: 500, CPUCores: 2, NetworkMbps: 100}}

	candidates := []Node{b, a}

	first, err := Place(candidates, req)
	if err != nil {
		t.Fatalf("Place() returned an unexpected error: %v", err)
	}
	for i := 0; i < 5; i++ {
		again, err := Place(candidates, req)
		if err != nil {
			t.Fatalf("run %d: Place() returned an unexpected error: %v", i, err)
		}
		if again.ID != first.ID {
			t.Fatalf("run %d: Place() = %q, want the same result as the first call %q (determinism violated)", i, again.ID, first.ID)
		}
	}
	if first.ID != "a-node" {
		t.Fatalf("Place() tie-break = %q, want lexicographically-first ID %q", first.ID, "a-node")
	}
}

// containsSubstring is a tiny local helper so this test file has no extra
// import beyond "testing" (strings.Contains would be equally fine, but
// this keeps the file's import list minimal and obviously side-effect-free).
func containsSubstring(haystack, needle string) bool {
	return len(needle) == 0 ||
		(len(haystack) >= len(needle) && func() bool {
			for i := 0; i+len(needle) <= len(haystack); i++ {
				if haystack[i:i+len(needle)] == needle {
					return true
				}
			}
			return false
		}())
}
