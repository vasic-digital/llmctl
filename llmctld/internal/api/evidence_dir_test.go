package api

import (
	"path/filepath"
	"strings"
	"testing"
)

// TestEvidenceOutputDir_DefaultsToTempNotTrackedEvidence is the test-first
// guard for the "tests must not overwrite tracked evidence" rule: without
// LLMCTL_QA_EVIDENCE=1 the observation dir MUST NOT be under docs/qa.
func TestEvidenceOutputDir_DefaultsToTempNotTrackedEvidence(t *testing.T) {
	t.Setenv("LLMCTL_QA_EVIDENCE", "")
	dir, err := evidenceOutputDir(t)
	if err != nil {
		t.Fatalf("evidenceOutputDir: %v", err)
	}
	if strings.Contains(filepath.ToSlash(dir), "docs/qa") {
		t.Fatalf("default evidence dir %q points into tracked docs/qa", dir)
	}
}

func TestEvidenceOutputDir_OptInUsesTrackedDir(t *testing.T) {
	t.Setenv("LLMCTL_QA_EVIDENCE", "1")
	dir, err := evidenceOutputDir(t)
	if err != nil {
		t.Fatalf("evidenceOutputDir: %v", err)
	}
	if !strings.HasSuffix(filepath.ToSlash(dir), "docs/qa/008-full-test-coverage") {
		t.Fatalf("opt-in evidence dir %q is not the tracked docs/qa/008-full-test-coverage", dir)
	}
}
