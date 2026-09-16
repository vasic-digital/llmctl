// Package integration (mtls_rotation_test.go): real multi-process
// integration tests for Feature 004 (mTLS certificate and CA rotation with
// revocation) - closes T012/T075's disclosed boundary. Every test in this
// file reuses cluster_bootstrap_test.go's testCluster harness (real
// llmctld OS processes, real QUIC+mTLS transports, real HTTP/3 API
// servers - nothing mocked or run in-process), per this project's
// Constitution §11.4.27 (no fakes beyond unit tests).
package integration
