// Package tenancy provides per-tenant key derivation for encryption at
// rest (FR-051, Clarification 20): KV cache checkpoints and WAL entries
// persist actual conversation content, so filesystem permissions alone
// (Clarification 18) are insufficient - each tenant's data is encrypted
// with a key unique to that tenant, derived here and consumed by
// internal/replication's encryption layer (checkpoint.go/wal.go).
//
// This is a minimal, focused package: full multi-tenancy (auth,
// authorization, RBAC, tenant lifecycle) is Phase 11's (US9) subject.
// This package exists now, ahead of Phase 11, only because T064
// explicitly names it as the key-derivation home for Phase 10's
// encryption-at-rest requirement.
package tenancy

import (
	"crypto/hmac"
	"crypto/sha256"
)

// DeriveKey derives a 32-byte AES-256 key unique to tenantID from
// masterSecret, via HMAC-SHA256 - a standard, correct KDF primitive:
// keyed, pseudorandom, and computationally infeasible to invert without
// masterSecret. The same (masterSecret, tenantID) pair always re-derives
// the identical key (so a node can decrypt its own previously-written
// files after a restart without persisting the derived key itself
// anywhere); different tenantIDs under the same masterSecret produce
// cryptographically independent keys (so one tenant's key can never
// decrypt another tenant's data).
//
// masterSecret's provenance (env var, secrets manager, etc.) is a Phase
// 11 (US9) concern - this function only performs the derivation.
func DeriveKey(masterSecret []byte, tenantID string) []byte {
	mac := hmac.New(sha256.New, masterSecret)
	mac.Write([]byte(tenantID))
	return mac.Sum(nil)
}
