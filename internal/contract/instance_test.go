package contract_test

import (
	"context"
	"strings"
	"testing"

	"github.com/vasic-digital/llmctl/internal/contract"
)

// B2-11: the serving instance is carried from the router to the HTTP layer through the context.
func TestInstanceNoteCarriesTheServingInstance(t *testing.T) {
	ctx, get := contract.WithInstanceNote(context.Background())
	if get() != "" {
		t.Fatal("nothing noted yet")
	}
	contract.NoteInstance(ctx, "decide-tiny.2")
	if get() != "decide-tiny.2" {
		t.Fatalf("got %q", get())
	}
	// no sink in the context: noting is a no-op, never a panic
	contract.NoteInstance(context.Background(), "x")
	// a label that is not header-safe is replaced by a stable hash handle, never forwarded (B3-07)
	ctx2, get2 := contract.WithInstanceNote(context.Background())
	contract.NoteInstance(ctx2, "bad\r\nx-injected: 1")
	if g := get2(); !strings.HasPrefix(g, "inst-") || strings.ContainsAny(g, "\r\n :") || strings.Contains(g, "injected") {
		t.Fatalf("an unsafe label must be hashed, not reported: %q", g)
	}
	if contract.HeaderInstance != "x-llmctl-decide-instance" {
		t.Fatal(contract.HeaderInstance)
	}
}

// B3-07 / M10: the accepted character class is pinned: tenant instances (upper case, "<tenant>--<profile>")
// are reported verbatim, a label outside the class or over the length is a stable hash, never dropped.
func TestSafeInstanceLabelClass(t *testing.T) {
	verbatim := []string{"decide-tiny", "decide-tiny.2", "Acme_Corp--decide-tiny", "A", strings.Repeat("a", 64)}
	for _, l := range verbatim {
		if got := contract.SafeInstanceLabel(l); got != l {
			t.Errorf("%q must be reported verbatim, got %q", l, got)
		}
	}
	hashed := []string{"has space", "tenant/profile", "unicodé", "a:b", "x\ny", strings.Repeat("a", 65)}
	seen := map[string]bool{}
	for _, l := range hashed {
		got := contract.SafeInstanceLabel(l)
		if !strings.HasPrefix(got, "inst-") || len(got) != len("inst-")+12 || contract.SafeInstanceLabel(l) != got {
			t.Errorf("%q: %q is not a stable 12-hex handle", l, got)
		}
		if seen[got] {
			t.Errorf("hash collision for %q", l)
		}
		seen[got] = true
	}
	if contract.SafeInstanceLabel("") != "" {
		t.Error("empty stays empty")
	}
	// lengths: 64 verbatim, 65 hashed (the boundary)
	if contract.SafeInstanceLabel(strings.Repeat("b", 64)) != strings.Repeat("b", 64) || !strings.HasPrefix(contract.SafeInstanceLabel(strings.Repeat("b", 65)), "inst-") {
		t.Error("length boundary")
	}
}
