// Package replication (crypto.go): AES-256-GCM value-level encryption at
// rest for WAL entries and checkpoints (FR-051, Clarification 20). Keys
// are derived per-tenant by internal/tenancy.DeriveKey and supplied by
// the caller - this file never generates or stores a key itself.
package replication

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"fmt"
)

// encryptValue seals plaintext with AES-256-GCM under key, returning
// nonce||ciphertext||tag (GCM's Seal appends the auth tag; the random
// nonce is prepended so decryptValue can recover it without a separate
// channel).
func encryptValue(key, plaintext []byte) ([]byte, error) {
	gcm, err := newGCM(key)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, fmt.Errorf("replication: generate nonce: %w", err)
	}
	return gcm.Seal(nonce, nonce, plaintext, nil), nil
}

// decryptValue opens a value produced by encryptValue. Returns a real
// error - AES-GCM's authentication tag check fails closed - when key is
// wrong or the ciphertext has been tampered with; this is the mechanism
// that makes "unreadable without the correct tenant key" a genuine,
// enforced property rather than a documentation-only claim.
func decryptValue(key, sealed []byte) ([]byte, error) {
	gcm, err := newGCM(key)
	if err != nil {
		return nil, err
	}
	if len(sealed) < gcm.NonceSize() {
		return nil, fmt.Errorf("replication: encrypted value too short (%d bytes)", len(sealed))
	}
	nonce, ciphertext := sealed[:gcm.NonceSize()], sealed[gcm.NonceSize():]
	plaintext, err := gcm.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		return nil, fmt.Errorf("replication: decrypt: %w (wrong key or corrupted data)", err)
	}
	return plaintext, nil
}

func newGCM(key []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("replication: build AES cipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("replication: build GCM mode: %w", err)
	}
	return gcm, nil
}
