// Package cluster (placement.go): a GPU/CPU/RAM/Network-aware bin-packing
// scheduler that decides which candidate Node a workload should land on
// (FR-020's "model placement optimization across cluster", SC-014's
// "optimal bin-packing across cluster").
package cluster

import "fmt"

// PlacementRequest describes the minimum resource footprint a workload
// needs in order to be placed onto a candidate Node - the demand side of
// Place()'s bin-packing decision. Its fields mirror Resources (the supply
// side, in state.go) field-for-field so a caller compares req directly
// against a node's Resources.RAMAvailMB / VRAMAvailMB / CPUCores /
// NetworkMbps, which already represent AVAILABLE (not total) capacity.
type PlacementRequest struct {
	RAMMB       int64
	VRAMMB      int64
	CPUCores    int
	NetworkMbps int
}

// fits reports whether n currently has AT LEAST req's worth of available
// capacity in every tracked dimension. "At least", not "strictly more
// than": a candidate whose available resources exactly equal req is a
// valid exact-fit placement, never rejected for lacking headroom it was
// never asked to have.
func fits(n Node, req PlacementRequest) bool {
	return n.Resources.RAMAvailMB >= req.RAMMB &&
		n.Resources.VRAMAvailMB >= req.VRAMMB &&
		n.Resources.CPUCores >= req.CPUCores &&
		n.Resources.NetworkMbps >= req.NetworkMbps
}

// leftoverScore computes a dimension-normalized measure of how much slack
// candidate n would have left AFTER req is placed onto it - the value
// Place()'s best-fit policy minimizes. Lower score = tighter fit.
//
// Design note (best-fit chosen over first-fit or worst-fit): the four
// tracked dimensions (RAM/VRAM in MB, CPU in cores, network in Mbps) live
// on wildly different numeric scales, so a raw sum of leftover
// (available-required) would be dominated by whichever dimension happens
// to have the largest absolute numbers (almost always RAM/VRAM), making
// the CPU-core and network dimensions essentially invisible to the
// comparison. leftoverScore instead normalizes each dimension's leftover
// as a FRACTION of that node's available capacity in that dimension
// (leftover / available) and sums the four fractions - a
// scale-independent measure of "how much of this node's spare room, as a
// proportion, would still be free after this workload lands here".
//
// best-fit (minimizing this sum, i.e. choosing the tightest fit) is the
// standard bin-packing heuristic for minimizing FRAGMENTATION: it packs
// workloads into nodes that already have the least slack, leaving large
// blocks of free capacity on other nodes intact for a future large
// workload. The alternative, worst-fit (maximizing leftover, spreading
// load as evenly as possible across every node), trades that away - it
// shrinks every node's free capacity roughly in step, so the LARGEST
// contiguous free block available anywhere in the cluster shrinks
// fastest, making it MORE likely that a future large workload finds no
// single node with enough spare capacity even though the cluster's
// aggregate spare capacity is unchanged. Since FR-020/SC-014 ask for
// "optimal bin-packing" (not deliberate load-spreading), best-fit is the
// correct default policy here.
//
// A dimension with zero available capacity contributes zero leftover
// fraction (0/0 defined as 0, not NaN): fits() already guarantees req's
// requirement for that dimension is also zero whenever available is
// zero, so this is an exact-fit (zero slack) case, not a missing-capacity
// case that could otherwise slip through.
func leftoverScore(n Node, req PlacementRequest) float64 {
	frac := func(avail, want int64) float64 {
		if avail == 0 {
			return 0
		}
		return float64(avail-want) / float64(avail)
	}
	return frac(n.Resources.RAMAvailMB, req.RAMMB) +
		frac(n.Resources.VRAMAvailMB, req.VRAMMB) +
		frac(int64(n.Resources.CPUCores), int64(req.CPUCores)) +
		frac(int64(n.Resources.NetworkMbps), int64(req.NetworkMbps))
}

// Place chooses the healthy candidate Node best suited to host a workload
// needing req's resources, using the best-fit bin-packing policy
// documented on leftoverScore.
//
// Place refuses (returns a non-nil, informative error) rather than ever
// choosing a candidate that does not genuinely have enough available
// capacity in every dimension, and never considers a candidate whose
// Health is not exactly "healthy" - scheduling a workload onto a node
// already known to be unhealthy is unsafe regardless of how much numeric
// capacity it reports (Constitution §11.4.133 target-system safety: a
// numeric-capacity reading alone is never sufficient justification to
// place a workload on a node the cluster already knows is unhealthy).
//
// Place is deterministic: given the same candidates and req, it always
// returns the same node. Ties in leftoverScore - including the common
// case of exactly one fitting candidate - are broken by ascending
// Node.ID string comparison, so correctness never depends on
// candidates' slice order or on any map iteration order.
func Place(candidates []Node, req PlacementRequest) (Node, error) {
	var best Node
	haveBest := false

	for _, n := range candidates {
		if n.Health != "healthy" {
			continue
		}
		if !fits(n, req) {
			continue
		}
		if !haveBest {
			best = n
			haveBest = true
			continue
		}
		if score, bestScore := leftoverScore(n, req), leftoverScore(best, req); score < bestScore || (score == bestScore && n.ID < best.ID) {
			best = n
		}
	}

	if !haveBest {
		return Node{}, fmt.Errorf(
			"cluster: placement refused: no healthy candidate node has sufficient capacity for request (ram=%dMB vram=%dMB cpu=%d cores network=%dMbps) among %d candidate(s)",
			req.RAMMB, req.VRAMMB, req.CPUCores, req.NetworkMbps, len(candidates),
		)
	}
	return best, nil
}

// DefaultTargetReplicaCount is US7's default target replica count per
// model (T052a: "configurable target replica count per model (default
// N=3, per US7 Acceptance Scenario patterns)"). A caller MAY override it
// per-model via ReplicaState.TargetCount; this is only the default.
const DefaultTargetReplicaCount = 3

// ReplicaState describes one model's current replica placement across the
// cluster - the input health.go's reconciliation pass (T052a) uses to
// detect an under-replicated model and re-place a replacement replica via
// Place().
type ReplicaState struct {
	Model       string
	TargetCount int
	LiveNodeIDs []string
}

// UnderReplicated reports whether s currently has fewer live replicas
// than its target (SC-018: availability must hold with 1 of 3 replicas
// failed, i.e. TargetCount=3, len(LiveNodeIDs)=2 -> true).
func (s ReplicaState) UnderReplicated() bool {
	return len(s.LiveNodeIDs) < s.TargetCount
}

// Deficit returns how many additional replicas are needed to reach
// TargetCount (0 when not under-replicated).
func (s ReplicaState) Deficit() int {
	if d := s.TargetCount - len(s.LiveNodeIDs); d > 0 {
		return d
	}
	return 0
}
