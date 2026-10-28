package isolation

// HostBudget is the Go twin of lib/reserve.sh (llmctl 3.4.0): the part of the host that local models
// may use, after the host reserve is kept back. The formulas MUST match the bash ones; the parity
// values are pinned in reserve_test.go and tests/test_host_reserve.sh.
//
//	Rc = max(MinCores, ceil(CPUPct% * N)), rounded up to whole physical cores, at most N-1
//	Bc = N - Rc;  chat = max(1, Bc*ChatPct%);  decide = max(1, Bc*DecidePct%)
//	Rm = max(MemMinMB, MemPct% * T);  Bm = T - Rm
//
// The reserve may be made stricter (larger percentages and floors) but never looser: values below the
// defaults are raised to the defaults. ChatPct/DecidePct are shares of the model budget Bc (the reserve
// is already kept back), clamped to 1..100; decide is never above chat. Bm has a 512 MiB floor.

import "sort"

// ReservePolicy holds the reserve percentages and floors.
type ReservePolicy struct {
	CPUPct, CPUMin     int
	MemPct             int
	MemMinMB           uint64
	ChatPct, DecidePct int
}

// DefaultReservePolicy is the 3.4.0 default: max(2 cores, 25%) and max(4 GiB, 20%) kept for the host.
var DefaultReservePolicy = ReservePolicy{CPUPct: 25, CPUMin: 2, MemPct: 20, MemMinMB: 4096, ChatPct: 50, DecidePct: 25}

// Budget is the computed host budget.
type Budget struct {
	ReservedCPUs, ModelCPUs []int
	ChatCPUs, DecideCPUs    int
	MemReservedMB           uint64
	MemModelMB              uint64
}

func clampPolicy(p ReservePolicy) ReservePolicy {
	d := DefaultReservePolicy
	if p.CPUPct < d.CPUPct {
		p.CPUPct = d.CPUPct
	}
	if p.CPUMin < d.CPUMin {
		p.CPUMin = d.CPUMin
	}
	if p.MemPct < d.MemPct {
		p.MemPct = d.MemPct
	}
	if p.MemMinMB < d.MemMinMB {
		p.MemMinMB = d.MemMinMB
	}
	if p.ChatPct <= 0 || p.ChatPct > 100 {
		p.ChatPct = d.ChatPct
	}
	if p.DecidePct <= 0 || p.DecidePct > 100 {
		p.DecidePct = d.DecidePct
	}
	return p
}

// HostBudget computes the budget for cpus online CPUs (0..cpus-1), siblings[c] = SMT thread siblings of
// CPU c (nil for none), and memTotalMB.
func HostBudget(cpus int, siblings map[int][]int, memTotalMB uint64, pol ReservePolicy) Budget {
	pol = clampPolicy(pol)
	var b Budget
	if cpus < 1 {
		cpus = 1
	}
	want := (cpus*pol.CPUPct + 99) / 100
	if want < pol.CPUMin {
		want = pol.CPUMin
	}
	if want > cpus-1 {
		want = cpus - 1
	}
	reserved := map[int]bool{}
	for c := 0; c < cpus && len(reserved) < want; c++ {
		if reserved[c] {
			continue
		}
		reserved[c] = true
		for _, s := range siblings[c] {
			if s < cpus {
				reserved[s] = true
			}
		}
	}
	if len(reserved) > cpus-1 { // core rounding left no model CPU: fall back to single CPUs
		reserved = map[int]bool{}
		for c := 0; c < want; c++ {
			reserved[c] = true
		}
	}
	for c := 0; c < cpus; c++ {
		if reserved[c] {
			b.ReservedCPUs = append(b.ReservedCPUs, c)
		} else {
			b.ModelCPUs = append(b.ModelCPUs, c)
		}
	}
	sort.Ints(b.ReservedCPUs)
	bc := len(b.ModelCPUs)
	if bc < 1 {
		bc = 1
		b.ModelCPUs = []int{cpus - 1}
	}
	b.ChatCPUs = max(1, bc*pol.ChatPct/100)
	b.DecideCPUs = min(b.ChatCPUs, max(1, bc*pol.DecidePct/100))
	b.MemReservedMB = max(pol.MemMinMB, memTotalMB*uint64(pol.MemPct)/100)
	b.MemModelMB = 512
	if memTotalMB > b.MemReservedMB+512 {
		b.MemModelMB = memTotalMB - b.MemReservedMB
	}
	return b
}
