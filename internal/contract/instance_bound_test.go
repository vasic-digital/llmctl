package contract_test

import (
	"context"
	"strings"
	"testing"

	"github.com/vasic-digital/llmctl/internal/contract"
)

// A3-T4: the instance label is bounded to 64 characters (it ends up in a response header): exactly
// 64 is kept verbatim, 65 becomes a fixed-size hash handle (B3-07), never a truncation.
func TestInstanceNoteLabelLengthBound(t *testing.T) {
	for _, tc := range []struct {
		n    int
		keep bool
	}{{1, true}, {63, true}, {64, true}, {65, false}, {4096, false}} {
		ctx, get := contract.WithInstanceNote(context.Background())
		label := strings.Repeat("a", tc.n)
		contract.NoteInstance(ctx, label)
		if got := get(); tc.keep && got != label || !tc.keep && (!strings.HasPrefix(got, "inst-") || len(got) != 17) {
			t.Errorf("len %d: kept=%v want keep=%v (got %d chars)", tc.n, got != "", tc.keep, len(got))
		}
	}
}
