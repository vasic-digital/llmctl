package isolation

import (
	"reflect"
	"strings"
	"testing"
)

// smt16 is the reference host: 16 CPUs, SMT siblings i and i+8.
func smt16() map[int][]int {
	m := map[int][]int{}
	for i := 0; i < 8; i++ {
		m[i] = []int{i, i + 8}
		m[i+8] = []int{i, i + 8}
	}
	return m
}

// Parity with tests/test_host_reserve.sh (16 CPUs SMT, 32768 MiB): reserved 0-1,8-9; Bc 12; chat 6;
// decide 3; Rm 6553; Bm 26215.
func TestHostBudgetParity16SMT(t *testing.T) {
	b := HostBudget(16, smt16(), 32768, DefaultReservePolicy)
	if want := []int{0, 1, 8, 9}; !reflect.DeepEqual(b.ReservedCPUs, want) {
		t.Fatalf("reserved = %v, want %v", b.ReservedCPUs, want)
	}
	if len(b.ModelCPUs) != 12 || b.ChatCPUs != 6 || b.DecideCPUs != 3 {
		t.Fatalf("Bc=%d chat=%d decide=%d, want 12/6/3", len(b.ModelCPUs), b.ChatCPUs, b.DecideCPUs)
	}
	if b.MemReservedMB != 6553 || b.MemModelMB != 26215 {
		t.Fatalf("Rm=%d Bm=%d, want 6553/26215", b.MemReservedMB, b.MemModelMB)
	}
}

func TestHostBudgetFloors(t *testing.T) {
	b := HostBudget(4, nil, 8192, DefaultReservePolicy) // 25% of 4 = 1 -> floor 2 cores; 20% of 8 GiB < 4 GiB floor
	if len(b.ReservedCPUs) != 2 || b.MemReservedMB != 4096 || b.MemModelMB != 4096 {
		t.Fatalf("small host: %+v", b)
	}
	b = HostBudget(2, nil, 2048, DefaultReservePolicy) // never more than N-1; Bm floor 512
	if len(b.ReservedCPUs) != 1 || len(b.ModelCPUs) != 1 || b.MemModelMB != 512 {
		t.Fatalf("tiny host: %+v", b)
	}
}

func TestHostBudgetNeverLooser(t *testing.T) {
	loose := ReservePolicy{CPUPct: 1, CPUMin: 0, MemPct: 1, MemMinMB: 1, ChatPct: 50, DecidePct: 25}
	if got, want := HostBudget(16, smt16(), 32768, loose), HostBudget(16, smt16(), 32768, DefaultReservePolicy); !reflect.DeepEqual(got, want) {
		t.Fatalf("a looser policy changed the budget: %+v vs %+v", got, want)
	}
	strict := DefaultReservePolicy
	strict.CPUPct, strict.MemPct = 50, 40
	b := HostBudget(16, smt16(), 32768, strict)
	if len(b.ReservedCPUs) != 8 || b.MemReservedMB != 13107 {
		t.Fatalf("stricter policy not applied: %+v", b)
	}
}

func TestWrapCommandCPUAndSwapLimits(t *testing.T) {
	_, args, err := WrapCommand(WrapConfig{TenantID: "t1", CPUQuotaPercent: 300, CPUAffinity: "2-7 10-15", NoSwap: true}, "/bin/true")
	if err != nil {
		t.Fatal(err)
	}
	j := strings.Join(args, " ")
	for _, w := range []string{"-p CPUQuota=300%", "-p CPUAffinity=2-7 10-15", "-p MemorySwapMax=0"} {
		if !strings.Contains(j, w) {
			t.Errorf("args %q missing %q", j, w)
		}
	}
	_, args, _ = WrapCommand(WrapConfig{TenantID: "t1"}, "/bin/true")
	if j := strings.Join(args, " "); strings.Contains(j, "CPUQuota") || strings.Contains(j, "SwapMax") || strings.Contains(j, "CPUAffinity") {
		t.Errorf("zero config added limits: %q", j)
	}
	for _, bad := range []string{"2-7;rm", "all", "-1", "2--7"} {
		if _, _, err := WrapCommand(WrapConfig{TenantID: "t1", CPUAffinity: bad}, "/bin/true"); err == nil {
			t.Errorf("affinity %q accepted", bad)
		}
	}
}
