package keyring

import (
	"github.com/vasic-digital/llmctl/internal/placement"
)

// CheckPlacement refuses a path inside a git work tree that version control does not ignore
// (FR-087). It is the shared fail-closed guard of internal/placement: git missing allows, "not a
// git repository" allows, an ignored path allows, and everything else - a timeout, dubious
// ownership, a corrupt repository, an unexpected answer - refuses.
func CheckPlacement(path string) error {
	err := placement.Check(placement.Spec{
		Path: path,
		What: "the key",
		Fix:  "add the file to .gitignore (e.g. a line '.env'), or set LLMCTL_ENV_FILE to a path outside the repository",
	})
	if err != nil {
		return newErr(kindPlacement, "%s", err.Error())
	}
	return nil
}
