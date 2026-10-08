package contract

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
)

// HeaderInstance names the response header that tells a caller which engine instance answered a
// decision. Deterministic mode promises byte-identical repeats PER INSTANCE and a busy primary
// overflows to the next one (FR-074), so a caller comparing two answers needs to know whether the
// same instance produced them (review-3 B2-11).
const HeaderInstance = "x-llmctl-decide-instance"

type instanceKey struct{}

type instanceNote struct{ label string }

// WithInstanceNote returns a context in which a backend can record the serving instance, and the
// reader of what was recorded ("" = none). The HTTP layer calls it before Decide and, when the
// reader returns a label, sets HeaderInstance.
func WithInstanceNote(ctx context.Context) (context.Context, func() string) {
	n := &instanceNote{}
	return context.WithValue(ctx, instanceKey{}, n), func() string { return n.label }
}

// InstanceLabelMax is the longest label reported verbatim.
const InstanceLabelMax = 64

// SafeInstanceLabel maps an engine instance label to a value that is safe in a response header:
// a label made only of [A-Za-z0-9._-] and at most InstanceLabelMax long is reported as is (tenant
// instances are "<TENANT>--<profile>", so upper case is part of the class); anything else - another
// character, or too long - becomes "inst-" plus 12 hex digits of its SHA-256, a stable, header-safe
// handle that discloses nothing of the original text (B3-07). "" stays "".
func SafeInstanceLabel(label string) string {
	if label == "" {
		return ""
	}
	if len(label) <= InstanceLabelMax {
		ok := true
		for _, r := range label {
			if !(r >= 'a' && r <= 'z') && !(r >= 'A' && r <= 'Z') && !(r >= '0' && r <= '9') && r != '.' && r != '-' && r != '_' {
				ok = false
				break
			}
		}
		if ok {
			return label
		}
	}
	sum := sha256.Sum256([]byte(label))
	return "inst-" + hex.EncodeToString(sum[:])[:12]
}

// NoteInstance records the serving instance (a no-op without a sink in ctx); the label is passed
// through SafeInstanceLabel because it ends up in a response header.
func NoteInstance(ctx context.Context, label string) {
	n, _ := ctx.Value(instanceKey{}).(*instanceNote)
	if n == nil || label == "" {
		return
	}
	n.label = SafeInstanceLabel(label)
}
