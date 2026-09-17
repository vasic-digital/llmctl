// Command llmctld is the opt-in cluster daemon for llmctl: Raft consensus,
// KV-cache replication, JWT/RBAC auth, and audit logging for multi-host
// deployments. Single-host llmctl usage never depends on this binary.
package main

import (
	"crypto/tls"
	"crypto/x509"
	"flag"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/quic-go/quic-go/http3"

	"github.com/vasic-digital/llmctl/llmctld/internal/api"
	"github.com/vasic-digital/llmctl/llmctld/internal/audit"
	"github.com/vasic-digital/llmctl/llmctld/internal/auth"
	"github.com/vasic-digital/llmctl/llmctld/internal/authz"
	"github.com/vasic-digital/llmctl/llmctld/internal/cluster"
	"github.com/vasic-digital/llmctl/llmctld/internal/executor"
	"github.com/vasic-digital/llmctl/llmctld/internal/mtls"
	"github.com/vasic-digital/llmctl/llmctld/internal/raft"
	"github.com/vasic-digital/llmctl/llmctld/internal/replication"
	"github.com/vasic-digital/llmctl/llmctld/internal/tenancy"
)

// jwtSigningKeyEnvVar names the environment variable .env.example
// documents for llmctld's JWT signing key (Phase 11, US9, FR-030) - a
// symmetric HS256 secret, generated via `openssl rand -base64 32` per
// .env.example's own instructions. Required once cluster mode is
// enabled: every real llmctld process registers the auth/tenant/audit
// routes (T074) unconditionally, and those routes cannot issue or
// validate a JWT without a real signing key - there is no silently-guessed
// fallback (Constitution §11.4.6).
const jwtSigningKeyEnvVar = "LLMCTLD_JWT_SIGNING_KEY"

// tenantEncryptionKeyEnvVar names the environment variable .env.example
// documents for llmctld's per-tenant replication-state encryption master
// secret (Clarification 20/FR-051, T072-FU3) - the raw material
// internal/tenancy.DeriveKey turns into each tenant's own AES-256 key
// for internal/replication's WAL/checkpoint Store. Unlike
// jwtSigningKeyEnvVar, this one is OPTIONAL and follows this project's
// established zero-means-unset convention (Constitution §11.4.6 - no
// invented default): when unset, every tenant's replication state is
// stored in plaintext (StoreRegistry, not NewEncryptedStoreRegistry) -
// the exact T072-FU2 behavior every existing test and deployment already
// relies on - and encryption at rest is opt-in for a deployment that
// configures it, never silently forced on or off.
const tenantEncryptionKeyEnvVar = "LLMCTLD_TENANT_ENCRYPTION_KEY"

// newStoreRegistry returns a *replication.StoreRegistry rooted at
// stateDir: NewEncryptedStoreRegistry when tenantEncryptionKeyEnvVar is
// set (real per-tenant encryption at rest, T072-FU3), else
// NewStoreRegistry (plaintext, T072-FU2's original behavior) - the one
// place both cluster-bootstrap and cluster-join wiring resolve this
// choice, so the two subcommands can never drift apart on it.
func newStoreRegistry(stateDir string, cfg replication.CheckpointConfig) *replication.StoreRegistry {
	if secret := os.Getenv(tenantEncryptionKeyEnvVar); secret != "" {
		return replication.NewEncryptedStoreRegistry(stateDir, cfg, []byte(secret))
	}
	return replication.NewStoreRegistry(stateDir, cfg)
}

// slotSaveEnvVar is the daemon-side counterpart of
// lib/scheduler.sh's own LLMCTL_SLOT_SAVE_PATH opt-in env var
// (003-kv-cache-replication T015, User Story 2): when set, this node
// resolves a per-tenant subdirectory under it as the REAL local
// directory a received engine-cache file (api.RegisterEngineCacheRoute)
// is written into. This MUST be the SAME base directory the real
// engine's own --slot-save-path was launched with
// (lib/scheduler.sh's sched_build_launch writes
// "${LLMCTL_SLOT_SAVE_PATH}/${profile}" - see that file's own comment)
// or a warm-restore attempt against a transferred file looks in the
// wrong place; wiring the two together at the profile/tenant-mapping
// layer is a disclosed, deliberate scope boundary of this task (see
// this feature's own final report) since no existing tenant-to-running-
// profile resolution API exists yet to hook this into cleanly.
//
// Left unset (the default), this node has User Story 2's cross-node
// transfer RECEIVING side fully DISABLED - it never writes a received
// file anywhere; RegisterEngineCacheRoute honestly refuses every upload
// with 503 rather than inventing a directory (matching
// tenantEncryptionKeyEnvVar's own opt-in-only, zero-means-unset
// convention, Constitution §11.4.6).
const slotSaveEnvVar = "LLMCTL_SLOT_SAVE_PATH"

// slotSaveDirResolver returns an api.EngineCacheDirResolver reading
// slotSaveEnvVar fresh, per call (this daemon has no live-reload use
// case for this value - matching newStoreRegistry's own "resolve once
// from an explicit input" simplicity). tenantID == "" (the default/
// no-tenancy path) resolves to the base directory directly, mirroring
// StoreRegistry.Get's own "" -> baseDir-directly convention exactly, so
// a single-tenant deployment's engine-cache directory is byte-identical
// to what it would be without any tenant concept at all.
func slotSaveDirResolver() api.EngineCacheDirResolver {
	return func(tenantID string) (string, bool) {
		base := os.Getenv(slotSaveEnvVar)
		if base == "" {
			return "", false
		}
		if tenantID == "" {
			return base, true
		}
		return filepath.Join(base, tenantID), true
	}
}

// bootstrapAdminOwnerID is the OwnerID recorded on the API key
// `-bootstrap-admin` seeds (main.go's runClusterBootstrap) - a fixed,
// documented, non-secret label (the key's ID/secret are the real
// credential; OwnerID is only an audit-trail label, matching
// auth.Store.Create's existing "caller-supplied string, no particular
// format required" contract) rather than an invented default that would
// be mistaken for a real operator identity.
const bootstrapAdminOwnerID = "bootstrap-admin"

// newAuthzDecider constructs the Phase 11 authZ/authN stack every real
// cluster node wires: a fresh in-memory audit log, RBAC registry, quota
// enforcer, and tenant registry, composed into one audited *authz.Decider
// (T071) plus the *auth.Store (T067) the auth routes (T074) need
// separately. signingKey MUST be non-empty - callers read it from
// jwtSigningKeyEnvVar and fail fast if it is unset, rather than falling
// back to an invented default key that would make every issued token
// forgeable by anyone who reads this source.
func newAuthzDecider(signingKey string) (*authz.Decider, *auth.Store) {
	decider := authz.NewDecider(
		audit.NewLog(),
		[]byte(signingKey),
		auth.NewRoleRegistry(),
		tenancy.NewEnforcer(),
		tenancy.NewRegistry(),
	)
	return decider, auth.NewKeyStore()
}

// registerAuthzRoutes wires T074's auth/tenant/audit route sets, plus
// T072-FU4's model-lifecycle dispatch routes and Feature 004's mTLS
// management routes (routes_mtls.go), onto srv's router, backed by
// decider, keys, node, and modelExecutor - the one call site both
// runClusterBootstrap and runClusterJoinReal use, so the two subcommands'
// wiring can never drift apart.
//
// node and forwardTLS (002-cluster-model-scheduler Phase 3) enable
// RegisterModelRoutes's auto-placement path on POST .../start - see that
// function's own doc comment for the full contract. node is also reused
// (004-mtls-cert-rotation) by RegisterMTLSRoutes's revoke/status actions.
// rotationHolder, raftTrustStore, and apiTrustStore (004-mtls-cert-rotation
// Phase 4 T016, extended Phase 5) are THIS node's own local CA-issuance
// holder (mtls.RotationCAHolder, constructed from this node's shared CA -
// see buildNodeTLSConfig/RegisterMTLSRoutes's own doc comments) and the
// exact same two *mtls.TrustStore instances buildNodeTLSConfig already
// constructed for this node's Raft-transport and HTTP-API tls.Config -
// passed through so RegisterMTLSRoutes's renew/begin/finalize actions can
// issue and swap in fresh certificates, and activate/retire dual CA
// trust, for both live transports.
// mtlsForwardTLS/mtlsForwardStore (004-mtls-cert-rotation Phase 5) are
// THIS node's own DEDICATED client identity + TrustStore for
// RegisterMTLSRoutes's leader-forwarding fallback - see that call's own
// doc comment and mtlsForwardStore's construction site (main.go's
// runClusterBootstrap/runClusterJoinReal) for why this must be separate
// from forwardTLS (002-cluster-model-scheduler's own, unrelated
// auto-placement forwarding).
func registerAuthzRoutes(srv *api.Server, decider *authz.Decider, keys *auth.Store, modelExecutor *executor.LocalExecutor, node *raft.Node, forwardTLS *tls.Config, rotationHolder *mtls.RotationCAHolder, mtlsForwardTLS *tls.Config, mtlsForwardStore, raftTrustStore, apiTrustStore *mtls.TrustStore) {
	api.RegisterAuthRoutes(srv.Router(), decider, keys)
	api.RegisterTenantRoutes(srv.Router(), decider)
	api.RegisterAuditRoutes(srv.Router(), decider)
	api.RegisterModelRoutes(srv.Router(), decider, modelExecutor, node, forwardTLS)
	api.RegisterMTLSRoutes(srv.Router(), node, decider, rotationHolder, mtlsForwardTLS, raftTrustStore, apiTrustStore, mtlsForwardStore)
}

// version is the llmctld build version. It is bumped alongside the bash
// CLI's LLMCTL_VERSION in bin/llmctl, but tracked independently since the
// two components ship on separate lifecycles (Constitution §11.4.264).
const version = "0.1.0"

// llmctldUsage is the accurate, current description of what `llmctld`'s
// own CLI supports, printed on a bare or unrecognized invocation.
// Updated 2026-09-17 (Constitution §11.4.6 - no stale claims): llmctld
// is NOT a Phase-1 scaffold any more - real Raft consensus, mTLS
// certificate/CA rotation with revocation, JWT/RBAC auth, per-tenant
// isolation, cluster-wide model placement, and cross-node KV-cache
// replication are all implemented and exercised by this project's own
// test suite (see docs/cluster-architecture.md). The CLI surface itself
// is intentionally narrow: `bootstrap` and `join` are the only two
// subcommands this binary's own arg parser recognizes - everything else
// this daemon does is reached through its real HTTP API
// (internal/api/routes_*.go) once a node is running, not through
// additional `llmctld cluster <verb>` subcommands (there is no
// CLI-level `leave`/`status`/etc. here today). Separately, and
// unrelated to this binary, the bash `bin/llmctl` CLI's own
// `cluster`/`tenant`/`apikey` subcommands are honestly-labeled stubs
// (bin/llmctl:186-211) - this message does not speak for that surface.
const llmctldUsage = "usage: llmctld cluster <bootstrap|join> [flags]\n" +
	"  bootstrap and join are the only two CLI subcommands this daemon\n" +
	"  supports; once a node is running, its real HTTP API (Raft/mTLS/\n" +
	"  auth/RBAC/tenancy/placement/replication) is reachable directly -\n" +
	"  see docs/cluster-architecture.md and docs/api-reference.md."

func main() {
	if len(os.Args) > 1 && (os.Args[1] == "version" || os.Args[1] == "--version") {
		fmt.Println("llmctld " + version)
		return
	}

	if len(os.Args) > 1 && os.Args[1] == "cluster" {
		if len(os.Args) > 2 {
			switch os.Args[2] {
			case "bootstrap":
				runClusterBootstrap(os.Args[3:])
				return
			case "join":
				runClusterJoin(os.Args[3:])
				return
			}
			// A genuinely unrecognized `cluster` subcommand (e.g. "leave",
			// "status") - distinct from "no args at all": the operator DID
			// ask for something specific, and this CLI does not implement
			// it (the daemon's real HTTP API may still cover the same
			// capability once the node is running - see llmctldUsage).
			fmt.Fprintf(os.Stderr, "llmctld: cluster subcommand %q is not implemented at the CLI level "+
				"(this binary's own arg parser only recognizes bootstrap/join)\n%s\n", os.Args[2], llmctldUsage)
			os.Exit(1)
		}
		// `llmctld cluster` with no subcommand named at all.
		fmt.Fprintln(os.Stderr, "llmctld: no cluster subcommand given\n"+llmctldUsage)
		os.Exit(1)
	}

	// No args, or a first argument that is not "cluster"/"version" at
	// all - plain usage, never an "unimplemented" claim (nothing
	// specific was asked for that could be unimplemented).
	fmt.Fprintln(os.Stderr, "llmctld: "+llmctldUsage)
	os.Exit(1)
}

// clusterFlags is the flag set common to both "cluster bootstrap" and
// "cluster join" - kept as one function so both subcommands stay
// consistent as this evolves, rather than drifting into two
// independently-maintained flag lists.
type clusterFlags struct {
	nodeID         string
	raftBind       string
	apiBind        string
	caCert         string
	caKey          string
	stateDir       string
	bootstrapAdmin bool
	llmctlPath     string
}

func parseClusterFlags(fs *flag.FlagSet, args []string) *clusterFlags {
	f := &clusterFlags{}
	fs.StringVar(&f.nodeID, "node-id", "", "this node's stable Raft/mTLS identity (required)")
	fs.StringVar(&f.raftBind, "raft-bind", "127.0.0.1:0", "address for this node's Raft QUIC+mTLS transport to listen on")
	fs.StringVar(&f.apiBind, "api-bind", "127.0.0.1:0", "address for this node's cluster HTTP/3 API to listen on")
	fs.StringVar(&f.caCert, "ca-cert", "", "path to the cluster's shared CA certificate PEM (required)")
	fs.StringVar(&f.caKey, "ca-key", "", "path to the cluster's shared CA private-key PEM (required)")
	fs.StringVar(&f.stateDir, "state-dir", "", "directory for this node's replication.Store (WAL + checkpoints); default: a per-node subdirectory next to -ca-cert")
	fs.BoolVar(&f.bootstrapAdmin, "bootstrap-admin", false, "seed one admin-role API key into this node's own auth.Store at startup and print its id+secret to stdout once, as \"BOOTSTRAP_ADMIN_KEY_ID=... BOOTSTRAP_ADMIN_KEY_SECRET=...\" (before the READY line) - the out-of-the-box way to stand up a cluster with no existing credential (a first-time operator, or a test harness with no other bootstrap path); only meaningful on \"cluster bootstrap\" since that is where a node's auth.Store is genuinely empty")
	fs.StringVar(&f.llmctlPath, "llmctl-path", "", "path to the real bin/llmctl script this node's model-lifecycle routes (T072-FU4) shell out to; default: the bare \"llmctl\" name, PATH-resolved at call time (executor.Config.LLMCtlPath's own documented default)")
	if err := fs.Parse(args); err != nil {
		fmt.Fprintln(os.Stderr, "llmctld:", err)
		os.Exit(2)
	}
	if f.nodeID == "" || f.caCert == "" || f.caKey == "" {
		fmt.Fprintln(os.Stderr, "llmctld: -node-id, -ca-cert, and -ca-key are required")
		os.Exit(2)
	}
	return f
}

// resolveStateDir returns stateDir if non-empty, else a deterministic
// per-node default derived from caCertPath's directory - so a caller
// that does not care about the exact location (every test in
// test/integration, for instance) still gets a real, functional,
// per-node-isolated replication.Store directory out of the box, while a
// caller that DOES care (e.g. co-locating state on a specific volume in
// production) can override it explicitly via -state-dir.
func resolveStateDir(stateDir, caCertPath, nodeID string) string {
	if stateDir != "" {
		return stateDir
	}
	return filepath.Join(filepath.Dir(caCertPath), "replication-"+nodeID)
}

// buildNodeTLSConfig builds the real mTLS tls.Config shape this whole
// codebase uses for node-to-node/API traffic: a leaf cert issued by ca
// for nodeID, trusting only ca, with InsecureSkipVerify +
// VerifyPeerCertificateAgainstCA (raft.transport.go's exported helper) so
// verification is by CA chain rather than by a DNS/IP SAN matching
// whatever address happens to be dialed - the same real bug (and fix)
// T049 found and fixed, applied identically here rather than
// reintroducing it in a third place.
//
// Refactored for Feature 004 (T006): the certificate + trust data now
// live in a *mtls.TrustStore, wired into tls.Config via
// GetCertificate/GetClientCertificate (live-swap, per research.md
// Decision 2) instead of a static Certificates field, and the returned
// *mtls.TrustStore is handed back to the caller so a later revocation
// event (T011) can call UpdateRevoked on the SAME store this tls.Config's
// handshakes read from - for a node that never triggers
// revocation/renewal/rotation, every existing CLI flag and the READY
// line stay behavior-identical (proven by test/integration's existing
// real multi-process bootstrap/failover tests continuing to pass
// unmodified).
//
// ClientAuth: tls.RequireAnyClientCert (Feature 004 Phase 5 fix, T018) -
// deliberately NOT tls.RequireAndVerifyClientCert. Root-caused via
// Constitution §11.4.102 systematic debugging against a genuine RED
// (TestMTLSRotation_DualTrust_AcceptsBothOldAndNewCA: a real node
// rejected a client certificate signed by a freshly-added incoming CA
// with "tls: unknown certificate authority", DESPITE
// TrustStore.UpdateTrustedCAs having already been called with both
// pools). Confirmed by reading Go's own crypto/tls server source
// (handshake_server.go's processCertsFromClient): when ClientAuth >=
// VerifyClientCertIfGiven, Go's stdlib ALWAYS performs its OWN built-in
// chain verification against c.config.ClientCAs - the tls.Config STRUCT
// FIELD below, a snapshot captured ONCE at construction time - BEFORE
// (and independently of) VerifyPeerCertificate ever runs, and
// UNCONDITIONALLY (InsecureSkipVerify has no effect on this SERVER-side
// check; that field only ever affects a CLIENT verifying a SERVER's
// certificate, per its own doc comment). TrustStore.UpdateTrustedCAs
// mutates ONLY the *mtls.TrustStore's own internal pool slice, never
// this tls.Config's ClientCAs field, so the built-in check kept using
// the STALE, CA-1-only pool forever - invisible until this feature's
// widen-trust (dual-CA) need actually exercised it (revocation only ever
// NARROWS trust within the SAME already-trusted CA, so this gap was
// never triggered by Phase 3's own real multi-process tests).
// tls.RequireAnyClientCert is Go's own documented escape hatch for
// exactly this shape (VerifyPeerCertificate's doc comment: "for a
// server, when ClientAuth is RequestClientCert or RequireAnyClientCert,
// then this callback will be considered but the verifiedChains argument
// will always be nil") - it still REQUIRES the client to present at
// least one certificate, but defers 100% of the real chain+revocation
// verification to VerifyPeerCertificate below (raft.
// VerifyPeerCertificateAgainstCA, which already correctly loops over
// TrustStore's LIVE, dynamically-updatable pool set) - identical
// security guarantee, zero stale-static-pool surface.
func buildNodeTLSConfig(ca *mtls.CA, nodeID string) (*tls.Config, *mtls.TrustStore, error) {
	nodeCert, err := ca.IssueNodeCert(nodeID)
	if err != nil {
		return nil, nil, fmt.Errorf("issue node cert for %q: %w", nodeID, err)
	}
	cert, err := mtls.LoadTLSCertificate(nodeCert.CertPEM, nodeCert.KeyPEM)
	if err != nil {
		return nil, nil, fmt.Errorf("load node cert for %q: %w", nodeID, err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(ca.CertPEM) {
		return nil, nil, fmt.Errorf("add CA cert to pool for %q", nodeID)
	}
	store, err := mtls.NewTrustStore(pool, &cert)
	if err != nil {
		return nil, nil, fmt.Errorf("new trust store for %q: %w", nodeID, err)
	}
	return &tls.Config{
		GetCertificate:        store.GetCertificate,
		GetClientCertificate:  store.GetClientCertificate,
		RootCAs:               pool,
		ClientCAs:             pool,
		ClientAuth:            tls.RequireAnyClientCert,
		InsecureSkipVerify:    true,
		VerifyPeerCertificate: raft.VerifyPeerCertificateAgainstCA(store),
	}, store, nil
}

// wireRevocationHandler registers node's revocation-event handler
// (Feature 004, T011) so raftTrustStore and apiTrustStore - the two
// *mtls.TrustStore instances backing THIS node's raft-transport and
// HTTP-API tls.Config respectively (buildNodeTLSConfig's two per-node
// calls) - stay synchronized with the cluster's Raft-replicated
// revocation state on EVERY node, with zero polling and zero process
// restart. The handler re-reads node.State().Revocations in full and
// REPLACES both stores' revoked-serial sets (TrustStore.UpdateRevoked's
// documented full-set-replace contract) rather than applying an
// incremental delta, so a lost or duplicated firing of this handler can
// never leave either store out of sync with the replicated source of
// truth. Shared by both runClusterBootstrap and runClusterJoinReal so the
// two subcommands' wiring can never drift apart, matching this file's
// registerAuthzRoutes/newAuthzDecider sharing pattern.
//
// Feature 004 Phase 5 (T023) extends the SAME registered closure (fsm.go's
// onRevocationApplied notify mechanism now ALSO fires for
// CommandBeginCARotation/CommandFinalizeCARotation, per that type's own
// doc comment - "forward-compatible with Phase 5's future CA-rotation
// event without a second handler mechanism") to ALSO keep CA-rotation
// state synchronized: the moment node.State().CARotation.Status flips to
// "finalized" (durably, cluster-wide, via a SINGLE Raft Apply anywhere -
// see internal/api/routes_mtls.go's own package doc comment), rotationHolder
// drops its own locally-tracked outgoing CA and both TrustStores follow
// suit, PROVIDED this node had already locally loaded the incoming CA via
// its own prior "begin rotation" API call (rotationHolder.
// FinalizeLocalRotation's own doc comment: an honest no-op otherwise - a
// node never told the incoming CA's material out-of-band cannot be made
// to trust it merely by this status flip). "begin"'s OWN dual-trust
// activation is intentionally NOT re-derived here: it happens directly
// and synchronously inside the "begin rotation" handler at the moment it
// loads the incoming CA's actual material (which this notify-only handler
// never receives - only a fingerprint HASH ever travels through Raft).
// trustStores is variadic (Feature 004 Phase 5) so every one of THIS
// node's live *mtls.TrustStore instances - Raft-transport, HTTP-API, and
// the dedicated mtls-forward-client store (main.go's own
// mtlsForwardTLS/mtlsForwardStore, backing RegisterMTLSRoutes's
// leader-forwarding fallback) - stays synchronized identically, without
// this function's own body needing to enumerate them by name.
func wireRevocationHandler(node *raft.Node, rotationHolder *mtls.RotationCAHolder, trustStores ...*mtls.TrustStore) {
	node.SetRevocationHandler(func() {
		state := node.State()
		revoked := make(map[string]struct{}, len(state.Revocations))
		for serial := range state.Revocations {
			revoked[serial] = struct{}{}
		}
		for _, store := range trustStores {
			store.UpdateRevoked(revoked)
		}

		if state.CARotation != nil && state.CARotation.Status == "finalized" {
			rotationHolder.FinalizeLocalRotation()
			pools := rotationHolder.Pools()
			for _, store := range trustStores {
				store.UpdateTrustedCAs(pools)
			}
		}
	})
}

// wireHealthMonitor constructs, wires, and starts T072-FU6/T072-FU7's
// cluster.Monitor - closing this project's own two disclosed follow-up
// gaps (docs/CONTINUATION.md §10f/§10g, the shared "Honest scope note" in
// §10h): (1) the resource-freshness heartbeat (Monitor.SetResourceReporting,
// 002-cluster-model-scheduler T008) was fully implemented and unit-tested
// but had ZERO non-test callers anywhere in this binary - selfID/
// resourceSource/resourceSubmit are wired here so every real cluster node
// now periodically re-probes its own real hardware capacity and durably
// refreshes it cluster-wide; (2) crash-triggered ReplicationRole failover
// was not reliably automatic - internal/cluster.ReconcileReplicationRoles
// (health.go, itself the per-tenant fan-out layer over the pure
// cluster.ReconcileTenantRole decision function replication_roles.go's
// own package doc comment names) is now genuinely invoked from a REAL
// failure signal (this Monitor's own Rescheduler callback, fed by a real
// HTTP health check against every other node's /v1/cluster/status)
// rather than never at all - closing the gap routes_replication.go's
// ensureReplicationRole left open by always passing nil deadNodeIDs (that
// function's own doc comment names this SAME Monitor+Rescheduler pair as
// one of the two intended real-liveness feeds for exactly this decision).
//
// healthCheckTLS is THIS node's own DEDICATED mTLS client identity for
// polling every OTHER node's /v1/cluster/status (a NEW per-purpose cert -
// mirroring this file's established one-cert-per-forwarding-purpose
// discipline; see mtlsForwardTLS/forwardClientTLS/forwardTLS's own doc
// comments for why a purpose never reuses another purpose's client
// identity - never a second, ad-hoc HTTP-client-construction pattern:
// the transport below is the SAME http3.Transport+TLSClientConfig shape
// newForwardingHTTPClient/client.go's ForwardModelStart already use).
// resourceForwardTLS is the EXISTING 002-cluster-model-scheduler
// auto-placement-forwarding client identity (this file's own forwardTLS)
// reused here, never a new cert - a resource-update forward to the
// leader is the SAME kind of node-to-node cluster-state write forwardTLS
// already exists for.
//
// llmctlPath is forwarded to probeLocalResources exactly as this
// function's caller's own initial join/bootstrap-time probe call already
// does, so every re-probe on every tick shells out to the SAME real
// hardware-probe binary, never a second, independently-resolved path.
//
// The returned stop func MUST be deferred by the caller (mirroring this
// file's own node.Shutdown()/srv.Close()/storeRegistry.Close() deferred-
// cleanup pattern, the only "shutdown hook mechanism" this binary has -
// there is no separate hook registry to wire into) - it halts both this
// Monitor's own background loop (Monitor.Stop(), health.go) AND the
// node-registry-freshening goroutine below, so neither leaks past this
// process's real shutdown.
//
// Excludes THIS node's own ID from the set Monitor.SetNodes checks
// (self-health-checking over the network is redundant - a node that can
// run its own health-check loop at all is, by construction, up - and a
// transient self-check failure would otherwise make this node propose
// reassigning its OWN ReplicationRole primaries away from itself, a
// spurious self-inflicted failover this design deliberately rules out
// rather than merely hoping never happens).
func wireHealthMonitor(node *raft.Node, llmctlPath string, healthCheckTLS, resourceForwardTLS *tls.Config) (monitor *cluster.Monitor, stop func()) {
	// healthCheckClientTimeout is deliberately SHORT and DEDICATED -
	// never forwardClientRequestTimeout (10s), which is tuned for
	// forwarding real replication data to a LIVE node and would be
	// actively harmful reused here: a genuinely dead node's QUIC/UDP
	// handshake produces no ICMP-equivalent fast failure the way a closed
	// TCP port does, so a health check against it blocks for the FULL
	// client timeout before failing. Monitor.CheckOnce (health.go) checks
	// every registered node SEQUENTIALLY, so a single slow-to-fail check
	// stalls every other node's check behind it for that same duration -
	// and, found as a genuine RED during this task's own real 3-node
	// crash test, ties up real per-node network/CPU resources for that
	// whole window at PRECISELY the moment a real crash has already put
	// Raft's own heartbeats under stress, destabilizing leader election
	// on the SURVIVING nodes (observed: a survivor's own Raft heartbeat
	// to another LIVE survivor missed its window and the leader stepped
	// down mid-recovery, purely as a side effect of this health check's
	// own timeout being far longer than it needed to be for its actual
	// job of detecting a dead node quickly). 2s is generous for a live
	// node's real response time while bounding a dead node's detection
	// cost to a small fraction of cluster.DefaultHealthCheckInterval
	// (10s), so even N-1 sequential dead-node checks in one CheckOnce
	// pass complete well before the next tick.
	const healthCheckClientTimeout = 2 * time.Second
	healthClient := &http.Client{
		Transport: &http3.Transport{TLSClientConfig: healthCheckTLS},
		Timeout:   healthCheckClientTimeout,
	}
	checker := func(addr string) bool {
		resp, err := healthClient.Get("https://" + addr + "/v1/cluster/status")
		if err != nil {
			return false
		}
		_ = resp.Body.Close()
		return resp.StatusCode >= http.StatusOK && resp.StatusCode < http.StatusMultipleChoices
	}

	// rescheduler is T072-FU7's fix: the ONE place a real health-check
	// failure signal now reaches cluster.ReconcileReplicationRoles - see
	// this function's own doc comment above for the full gap this
	// closes. Runs on EVERY node's own Monitor (each node health-checks
	// every OTHER node), but only the current Raft leader's
	// ReassignReplicationRole Apply can durably commit
	// (hraft.ErrNotLeader on a follower, silently ignored here - the
	// SAME best-effort-and-honest discipline routes_replication.go's own
	// ensureReplicationRole already establishes for this identical
	// class of write); the leader's OWN health check against the SAME
	// failed node fires this identical callback and succeeds, so
	// convergence never depends on which node's tick "wins" the race.
	//
	// Two-primaries-at-once race, ruled out (Constitution §11.4.6 - not
	// merely assumed safe): internal/replication/forwarder.go's own T005
	// race-condition analysis already establishes that
	// cluster.ClusterState.ReplicationRoles is Raft-replicated COMMITTED
	// state - CommandAssignReplicationRole/CommandReassignReplicationRole
	// both apply as a single atomic map-replace-in-place write
	// (fsm.go's own doc comment), so at any given committed log index
	// EXACTLY ONE ReplicationRole record exists per tenant. This
	// Rescheduler introduces NO second commit mechanism - every
	// candidate role it computes is proposed through the SAME
	// already-tested node.ReassignReplicationRole -> applyCommand ->
	// n.raft.Apply path routes_replication.go's own ensureReplicationRole
	// already uses, so it inherits that path's existing safety property
	// rather than needing a new one. Multiple nodes' Monitors firing this
	// callback concurrently for the same failedNodeID is harmless: every
	// call recomputes newPrimary deterministically from the SAME
	// Raft-replicated inputs (cluster.ReconcileReplicationRoles's own
	// sorted firstOtherLiveNode selection over node.Servers()'s
	// replicated voter configuration), so every proposal - whichever one
	// actually reaches a leader's Apply - names the IDENTICAL
	// PrimaryNodeID/ReplicaNodeIDs; a second Apply of an
	// already-identical role (possible only across a leadership change
	// mid-episode) is an idempotent overwrite, never a conflicting one.
	// What this rescheduler does NOT solve, deliberately, matching
	// forwarder.go's own disclosed scope boundary: which node accepts a
	// NEW inbound client request for a tenant is a request-routing
	// decision outside 003-kv-cache-replication's ReplicationRole
	// tracking entirely - unchanged by this wiring.
	rescheduler := func(failedNodeID string) {
		state := node.State()
		servers, err := node.Servers()
		if err != nil {
			return
		}
		liveNodeIDs := make([]string, 0, len(servers))
		for _, s := range servers {
			liveNodeIDs = append(liveNodeIDs, s.ID)
		}
		changed := cluster.ReconcileReplicationRoles(state.ReplicationRoles, failedNodeID, liveNodeIDs, "", time.Now())
		for _, role := range changed {
			_ = node.ReassignReplicationRole(role)
		}
	}

	monitor = cluster.NewMonitor(checker, rescheduler, cluster.DefaultHealthCheckInterval)

	resourceSource := func() (cluster.Resources, error) {
		return probeLocalResources(llmctlPath)
	}
	resourceSubmit := func(nodeID string, r cluster.Resources) error {
		if node.IsLeader() {
			return node.UpdateResources(nodeID, r)
		}
		leaderAddr := node.LeaderAddr()
		if leaderAddr == "" {
			return fmt.Errorf("update resources for %q: no known cluster leader", nodeID)
		}
		var leaderAPIAddr string
		for _, peer := range node.State().Nodes {
			if peer.Addr == leaderAddr {
				leaderAPIAddr = peer.APIAddr
				break
			}
		}
		if leaderAPIAddr == "" {
			return fmt.Errorf("update resources for %q: leader %q has no registered API address", nodeID, leaderAddr)
		}
		return api.ForwardUpdateResources(resourceForwardTLS, leaderAPIAddr, nodeID, r)
	}
	monitor.SetResourceReporting(node.ID(), resourceSource, resourceSubmit)

	// healthCheckAddrs re-reads node.State().Nodes fresh every call
	// (never cached) - matching forwarder.go's own T005-documented
	// "never cache replicated state across calls" discipline.
	healthCheckAddrs := func() map[string]string {
		addrs := make(map[string]string, len(node.State().Nodes))
		selfID := node.ID()
		for id, n := range node.State().Nodes {
			if id == selfID || n.APIAddr == "" {
				continue
			}
			addrs[id] = n.APIAddr
		}
		return addrs
	}
	monitor.SetNodes(healthCheckAddrs())

	// nodeSyncStopCh stops the goroutine below, which keeps Monitor.SetNodes
	// current with real cluster membership changes (T072-FU6's design
	// point 5: "at minimum on your own periodic tick, reading
	// node.State().Nodes" - health.go's Monitor deliberately has no
	// membership-change notification of its own to hook into, so this is
	// a genuinely separate, minimal periodic sync, not a modification to
	// the already-implemented-and-tested Monitor type). A dedicated
	// nodeRegistrySyncInterval - deliberately SHORTER than
	// cluster.DefaultHealthCheckInterval - rather than reusing the same
	// constant: refreshing the registry is a purely local, cheap
	// operation (one map copy from this node's own already-replicated
	// state, zero network I/O), so ticking it faster than the network
	// health-check cadence bounds how long a newly-joined node can go
	// un-monitored, and how long a node that just crashed can go
	// un-DETECTED-as-a-monitoring-target, to (at most) one
	// nodeRegistrySyncInterval rather than a full
	// DefaultHealthCheckInterval on top of it - the disclosed, deliberate
	// choice this function's own doc comment's "nice-to-have, not
	// required" real-time-push alternative was weighed against.
	nodeSyncStopCh := make(chan struct{})
	go func() {
		ticker := time.NewTicker(nodeRegistrySyncInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				monitor.SetNodes(healthCheckAddrs())
			case <-nodeSyncStopCh:
				return
			}
		}
	}()

	monitor.Start()

	return monitor, func() {
		close(nodeSyncStopCh)
		monitor.Stop()
	}
}

// forwardClientRequestTimeout bounds the http.Client-level timeout for
// one forwarded HTTP/3+mTLS request (internal/api's NewNodeForwarder,
// T008) - distinct from internal/replication's own forwardRetryBudget
// (that one bounds the forwarder's OWN retry loop across potentially
// several attempts to one replica); kept generous relative to that
// budget so this client-level timeout is never what actually fires
// first for a healthy replica.
const forwardClientRequestTimeout = 10 * time.Second

// nodeRegistrySyncInterval bounds how stale wireHealthMonitor's own
// Monitor.SetNodes registry can be relative to real cluster membership
// (T072-FU6's design point 5) - see that function's own doc comment for
// why this is a dedicated, shorter interval than
// cluster.DefaultHealthCheckInterval rather than reusing it.
const nodeRegistrySyncInterval = 1 * time.Second

// newForwardingHTTPClient builds the real HTTP/3+mTLS client
// internal/replication.Forwarder posts forwarded appends/checkpoints
// over (T008) - the SAME quic-go/http3 transport + mTLS discipline every
// other node-to-node call in this codebase uses (api/client.go's own
// RequestJoin).
func newForwardingHTTPClient(clientTLS *tls.Config) *http.Client {
	return &http.Client{
		Transport: &http3.Transport{TLSClientConfig: clientTLS},
		Timeout:   forwardClientRequestTimeout,
	}
}

// selfRegisterOwnAPIAddr (003-kv-cache-replication's original T008
// bootstrap-self-registration mechanism) was REMOVED during the 002/003
// merge, not merely superseded in place: it solved the exact same
// problem as 002-cluster-model-scheduler's node.RegisterSelf (a
// bootstrap leader is otherwise absent from its own ClusterState.Nodes)
// via a strictly weaker mechanism - backgrounded (a real race window
// during which cluster.Place and internal/replication.Forwarder's
// AddrResolver would both see this node as absent), and its own
// RegisterNode(node.ID(), apiAddr) call carried NO Resources at all
// (RegisterNode only ever sets APIAddr, never Resources - see
// replication_commands.go's RegisterNode doc comment), which would have
// left this node permanently invisible to cluster.Place's capacity-based
// candidate filtering even once registration completed. RegisterSelf's
// synchronous, full (Addr+APIAddr+Resources) registration - already
// required by 002-cluster-model-scheduler and called immediately above -
// makes this function's entire purpose redundant, so it is deleted
// rather than kept as an unreachable alternative path.

// waitForShutdownSignal blocks until SIGINT or SIGTERM, so a
// llmctld cluster process stays up (serving Raft + the HTTP API) until
// explicitly told to stop - the real, killable-by-a-test-harness process
// shape T051/T054's real multi-process integration tests require.
func waitForShutdownSignal() {
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	<-sigCh
}

// waitForSelfLeadership polls node.IsLeader() until it reports true or
// timeout elapses (found via a genuine RED on a real 3-node integration
// test, 002-cluster-model-scheduler T013 - see this function's own call
// site in runClusterBootstrap for the full root-cause explanation): a
// single-node Bootstrap() genuinely self-elects almost immediately, but
// not synchronously within Bootstrap()'s own return, so a caller that
// needs n to already be leader (RegisterSelf's n.raft.Apply) must poll
// rather than assume. Bounded + fails loud on genuine non-election,
// never a blind sleep (Constitution §11.4.6 - "should be elected by
// now" is a guess, not a determination).
func waitForSelfLeadership(node *raft.Node, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if node.IsLeader() {
			return nil
		}
		time.Sleep(10 * time.Millisecond)
	}
	return fmt.Errorf("node %q never became its own single-node Raft leader within %s", node.ID(), timeout)
}

func runClusterBootstrap(args []string) {
	fs := flag.NewFlagSet("cluster bootstrap", flag.ExitOnError)
	f := parseClusterFlags(fs, args)

	ca, err := mtls.GenerateCA()
	if err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster bootstrap: generate CA:", err)
		os.Exit(1)
	}
	if err := os.WriteFile(f.caCert, ca.CertPEM, 0o600); err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster bootstrap: write CA cert:", err)
		os.Exit(1)
	}
	if err := os.WriteFile(f.caKey, ca.KeyPEM, 0o600); err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster bootstrap: write CA key:", err)
		os.Exit(1)
	}

	raftTLS, raftTrustStore, err := buildNodeTLSConfig(ca, f.nodeID)
	if err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster bootstrap:", err)
		os.Exit(1)
	}
	node, err := raft.Bootstrap(raft.Config{NodeID: f.nodeID, BindAddr: f.raftBind, TLSConfig: raftTLS})
	if err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster bootstrap: raft.Bootstrap:", err)
		os.Exit(1)
	}
	defer func() { _ = node.Shutdown() }()

	apiTLS, apiTrustStore, err := buildNodeTLSConfig(ca, f.nodeID+"-api")
	if err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster bootstrap:", err)
		os.Exit(1)
	}
	// rotationHolder (004-mtls-cert-rotation Phase 5) is THIS node's own
	// local holder of which CA it currently issues fresh certificates
	// from - see buildNodeTLSConfig/RegisterMTLSRoutes's own doc
	// comments. Constructed once, shared by wireRevocationHandler (the
	// FSM-notify-driven finalize sync) and registerAuthzRoutes's
	// RegisterMTLSRoutes call (the begin/renew handlers).
	rotationHolder := mtls.NewRotationCAHolder(ca)
	// mtlsForwardTLS/mtlsForwardStore (004-mtls-cert-rotation Phase 5)
	// back RegisterMTLSRoutes's OWN leader-forwarding fallback (POST
	// /v1/cluster/mtls/rotate/transition) - a DEDICATED client identity
	// + TrustStore, DISTINCT from the pre-existing forwardTLS built below
	// (002-cluster-model-scheduler's auto-placement forwarding, an
	// UNRELATED concern this feature deliberately does not touch).
	// mtlsForwardStore's own pools are kept in lockstep with
	// raftTrustStore/apiTrustStore below - without this, a FOLLOWER
	// forwarding its own CA-rotation transition to a leader that has
	// ALREADY renewed under the incoming CA would reject the leader's
	// now-incoming-CA-signed certificate on THIS client's own (otherwise
	// stale, CA-1-only) verification - a genuine RED found via this
	// exact scenario in T020's real multi-process test.
	mtlsForwardTLS, mtlsForwardStore, err := buildNodeTLSConfig(ca, f.nodeID+"-mtls-forward-client")
	if err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster bootstrap:", err)
		os.Exit(1)
	}
	wireRevocationHandler(node, rotationHolder, raftTrustStore, apiTrustStore, mtlsForwardStore)
	srv := api.NewServer(node, apiTLS)

	signingKey := os.Getenv(jwtSigningKeyEnvVar)
	if signingKey == "" {
		fmt.Fprintf(os.Stderr, "llmctld: cluster bootstrap: %s must be set (see .env.example)\n", jwtSigningKeyEnvVar)
		os.Exit(1)
	}
	decider, keys := newAuthzDecider(signingKey)

	stateDir := resolveStateDir(f.stateDir, f.caCert, f.nodeID)
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster bootstrap: create state dir:", err)
		os.Exit(1)
	}
	// StoreRegistry (T072-FU2) lazily opens one *replication.Store PER
	// TENANT rooted under stateDir, closing Clarification 18/FR-049's
	// disclosed gap - see internal/replication/registry.go's doc comment.
	// Unlike the single eager replication.OpenStore call this replaces,
	// no Store is opened here; the first genuine per-tenant open failure
	// (e.g. a permission problem specific to one tenant's subdirectory)
	// now surfaces on that tenant's first /v1/replication/* request
	// rather than at node startup - stateDir's own creation is still
	// verified eagerly above, exactly as before. decider is required
	// (T072-FU5): every /v1/replication/* route now requires RequireJWT
	// + tenant-ownership authorization, closing a real cross-tenant
	// data-access gap an independent review found in T072-FU2/FU3's own
	// diff - see routes_replication.go's package doc comment.
	storeRegistry := newStoreRegistry(stateDir, replication.CheckpointConfig{})
	defer func() { _ = storeRegistry.Close() }()
	// T008 (003-kv-cache-replication): the automatic cross-node forwarding
	// daemon - posts this node's own real appends/checkpoints to every
	// current replica's real /v1/replication/* routes over a real
	// HTTP/3+mTLS client, the moment they land locally.
	forwardClientTLS, _, err := buildNodeTLSConfig(ca, f.nodeID+"-forward-client")
	if err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster bootstrap:", err)
		os.Exit(1)
	}
	forwarder := api.NewNodeForwarder(node, newForwardingHTTPClient(forwardClientTLS))
	api.RegisterReplicationRoutes(srv.Router(), storeRegistry, decider, node, forwarder)
	api.RegisterEngineCacheRoute(srv.Router(), decider, slotSaveDirResolver())

	modelExecutor := executor.New(executor.Config{LLMCtlPath: f.llmctlPath})
	// forwardTLS (002-cluster-model-scheduler T017) is the real mTLS
	// client configuration this node's own auto-placement handler uses
	// to forward a start request to a DIFFERENT chosen node's cluster
	// API - a distinct cert from this node's own server-side apiTLS
	// (client vs. server role), mirroring joinClientTLS's identical
	// "-join-client"-suffixed cert pattern below.
	forwardTLS, _, err := buildNodeTLSConfig(ca, f.nodeID+"-forward-client")
	if err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster bootstrap:", err)
		os.Exit(1)
	}
	registerAuthzRoutes(srv, decider, keys, modelExecutor, node, forwardTLS, rotationHolder, mtlsForwardTLS, mtlsForwardStore, raftTrustStore, apiTrustStore)

	// healthCheckTLS (T072-FU6/T072-FU7) is THIS node's own DEDICATED mTLS
	// client identity for wireHealthMonitor's real HTTP health checks
	// against every other node - see that function's own doc comment for
	// why this purpose gets its own cert rather than reusing forwardTLS.
	healthCheckTLS, _, err := buildNodeTLSConfig(ca, f.nodeID+"-health-client")
	if err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster bootstrap:", err)
		os.Exit(1)
	}
	_, stopHealthMonitor := wireHealthMonitor(node, f.llmctlPath, healthCheckTLS, forwardTLS)
	defer stopHealthMonitor()

	if f.bootstrapAdmin {
		adminKeyID, adminKeySecret, err := keys.Create(bootstrapAdminOwnerID, []string{auth.RoleAdmin}, 0)
		if err != nil {
			fmt.Fprintln(os.Stderr, "llmctld: cluster bootstrap: seed bootstrap admin API key:", err)
			os.Exit(1)
		}
		// Printed BEFORE the READY line (and flushed the same way -
		// stdout is line-buffered by default for a pipe, and the
		// process's very next real output is READY, which every caller
		// of this flag already waits for) so a caller reading this
		// process's stdout line-by-line - exactly like
		// test/integration's waitForReady already does for the READY
		// line itself - captures this credential deterministically
		// before proceeding, never racing against it.
		fmt.Printf("BOOTSTRAP_ADMIN_KEY_ID=%s BOOTSTRAP_ADMIN_KEY_SECRET=%s\n", adminKeyID, adminKeySecret)
	}

	if err := srv.Listen(f.apiBind); err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster bootstrap: api.Listen:", err)
		os.Exit(1)
	}
	defer func() { _ = srv.Close() }()

	// waitForSelfLeadership (found via a genuine RED on a real 3-node
	// integration test, 002-cluster-model-scheduler T013): a freshly
	// Bootstrap()-ed node's single-node Raft leader election is NOT
	// instantaneous - node.raft.State() can still read Follower for a
	// handful of milliseconds after Bootstrap() returns, exactly as
	// internal/raft's own waitForLeader test helper documents ("a
	// single-node bootstrap can elect before the test ever reaches the
	// channel receive"). RegisterSelf immediately below calls
	// n.raft.Apply, which requires n to already be leader - calling it
	// before that election completes fails hard with "node is not the
	// leader" and the whole process exits before ever printing READY.
	// Bounded poll, not a blind sleep, and fails loud+fast (never a
	// silently-guessed "should be fine by now" delay - Constitution
	// §11.4.6) if a bootstrapping node somehow never self-elects.
	if err := waitForSelfLeadership(node, 10*time.Second); err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster bootstrap:", err)
		os.Exit(1)
	}

	// RegisterSelf (002-cluster-model-scheduler T017's prerequisite; also
	// satisfies 003-kv-cache-replication's T008 self-registration need -
	// see this function's doc comment for why the two features' separate
	// self-registration mechanisms were consolidated into this one during
	// the 002/003 merge) - a freshly-bootstrapped leader is otherwise
	// NEVER present in its own ClusterState.Nodes (Bootstrap only ever
	// makes it a Raft VOTER, never applies a CommandJoinNode for its own
	// ID - a real, found gap) - so without this, the bootstrap leader
	// itself is invisible to cluster.Place's candidate list, and to every
	// other node's cross-node-forwarding/replication-forwarding dial
	// target. Sourced from the SAME real hardware probe -join uses (never
	// a zero-value placeholder), and from srv's own real bound address
	// (never the requested -api-bind, which may be an ephemeral ":0" the
	// OS has since resolved). Run synchronously (unlike T008's original
	// backgrounded selfRegisterOwnAPIAddr, superseded here): this call
	// already fully sets Addr/APIAddr/Resources in one CommandJoinNode
	// after leadership is confirmed, so there is no election race left to
	// wait out in the background, and every consumer (cluster.Place AND
	// internal/replication.Forwarder's AddrResolver) sees a complete,
	// correct entry before READY prints - never a partial one a
	// backgrounded retry might still be filling in.
	selfResources, err := probeLocalResources(f.llmctlPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster bootstrap: probeLocalResources:", err)
		os.Exit(1)
	}
	if err := node.RegisterSelf(srv.Addr, selfResources); err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster bootstrap: RegisterSelf:", err)
		os.Exit(1)
	}

	// A single machine-readable READY line, emitted once and flushed, is
	// how a test harness spawning this as a real subprocess learns the
	// REAL bound addresses (both binds may use ":0" ephemeral ports) -
	// the same real-signal discipline as every other real-process test
	// in this project (never guess a port, read what was actually bound).
	fmt.Printf("READY node_id=%s raft_addr=%s api_addr=%s\n", f.nodeID, node.Addr(), srv.Addr)

	waitForShutdownSignal()
}

func runClusterJoin(args []string) {
	os.Exit(runClusterJoinReal(args))
}

// runClusterJoinReal is split out from runClusterJoin so the exit code is
// a return value, not a direct os.Exit deep in the flag-parsing path -
// flag.ExitOnError already handles malformed flags; this function handles
// genuine runtime failures uniformly. It does not reuse parseClusterFlags
// because "cluster join" needs one additional required flag
// (-leader-api) that "cluster bootstrap" does not.
func runClusterJoinReal(args []string) int {
	fs := flag.NewFlagSet("cluster join", flag.ExitOnError)
	var (
		nodeID     string
		raftBind   string
		apiBind    string
		caCert     string
		caKey      string
		leaderAPI  string
		stateDir   string
		llmctlPath string
	)
	fs.StringVar(&nodeID, "node-id", "", "this node's stable Raft/mTLS identity (required)")
	fs.StringVar(&raftBind, "raft-bind", "127.0.0.1:0", "address for this node's Raft QUIC+mTLS transport to listen on")
	fs.StringVar(&apiBind, "api-bind", "127.0.0.1:0", "address for this node's cluster HTTP/3 API to listen on")
	fs.StringVar(&caCert, "ca-cert", "", "path to the cluster's shared CA certificate PEM (required)")
	fs.StringVar(&caKey, "ca-key", "", "path to the cluster's shared CA private-key PEM (required)")
	fs.StringVar(&leaderAPI, "leader-api", "", "the existing cluster leader's api-bind address to join through (required)")
	fs.StringVar(&stateDir, "state-dir", "", "directory for this node's replication.Store (WAL + checkpoints); default: a per-node subdirectory next to -ca-cert")
	fs.StringVar(&llmctlPath, "llmctl-path", "", "path to the real bin/llmctl script this node's model-lifecycle routes (T072-FU4) shell out to; default: the bare \"llmctl\" name, PATH-resolved at call time (executor.Config.LLMCtlPath's own documented default)")
	if err := fs.Parse(args); err != nil {
		fmt.Fprintln(os.Stderr, "llmctld:", err)
		return 2
	}
	if nodeID == "" || caCert == "" || caKey == "" || leaderAPI == "" {
		fmt.Fprintln(os.Stderr, "llmctld: -node-id, -ca-cert, -ca-key, and -leader-api are required")
		return 2
	}

	certPEM, err := os.ReadFile(caCert)
	if err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster join: read CA cert:", err)
		return 1
	}
	keyPEM, err := os.ReadFile(caKey)
	if err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster join: read CA key:", err)
		return 1
	}
	ca, err := mtls.LoadCA(certPEM, keyPEM)
	if err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster join: load CA:", err)
		return 1
	}

	raftTLS, raftTrustStore, err := buildNodeTLSConfig(ca, nodeID)
	if err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster join:", err)
		return 1
	}
	node, err := raft.New(raft.Config{NodeID: nodeID, BindAddr: raftBind, TLSConfig: raftTLS})
	if err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster join: raft.New:", err)
		return 1
	}
	defer func() { _ = node.Shutdown() }()

	apiTLS, apiTrustStore, err := buildNodeTLSConfig(ca, nodeID+"-api")
	if err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster join:", err)
		return 1
	}
	// See runClusterBootstrap's identical rotationHolder/mtlsForwardTLS
	// comments above (004-mtls-cert-rotation Phase 5) - kept symmetric
	// across both subcommands.
	rotationHolder := mtls.NewRotationCAHolder(ca)
	mtlsForwardTLS, mtlsForwardStore, err := buildNodeTLSConfig(ca, nodeID+"-mtls-forward-client")
	if err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster join:", err)
		return 1
	}
	wireRevocationHandler(node, rotationHolder, raftTrustStore, apiTrustStore, mtlsForwardStore)
	srv := api.NewServer(node, apiTLS)

	signingKey := os.Getenv(jwtSigningKeyEnvVar)
	if signingKey == "" {
		fmt.Fprintf(os.Stderr, "llmctld: cluster join: %s must be set (see .env.example)\n", jwtSigningKeyEnvVar)
		return 1
	}
	decider, keys := newAuthzDecider(signingKey)

	resolvedStateDir := resolveStateDir(stateDir, caCert, nodeID)
	if err := os.MkdirAll(resolvedStateDir, 0o700); err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster join: create state dir:", err)
		return 1
	}
	// See runClusterBootstrap's identical StoreRegistry wiring comment
	// above (T072-FU2/T072-FU5) - kept symmetric across both subcommands.
	storeRegistry := newStoreRegistry(resolvedStateDir, replication.CheckpointConfig{})
	defer func() { _ = storeRegistry.Close() }()
	// See runClusterBootstrap's identical Forwarder wiring comment above
	// (T008) - kept symmetric across both subcommands.
	forwardClientTLS, _, err := buildNodeTLSConfig(ca, nodeID+"-forward-client")
	if err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster join:", err)
		return 1
	}
	forwarder := api.NewNodeForwarder(node, newForwardingHTTPClient(forwardClientTLS))
	api.RegisterReplicationRoutes(srv.Router(), storeRegistry, decider, node, forwarder)
	api.RegisterEngineCacheRoute(srv.Router(), decider, slotSaveDirResolver())
	modelExecutor := executor.New(executor.Config{LLMCtlPath: llmctlPath})
	// See runClusterBootstrap's identical forwardTLS comment above
	// (002-cluster-model-scheduler T017) - kept symmetric across both
	// subcommands.
	forwardTLS, _, err := buildNodeTLSConfig(ca, nodeID+"-forward-client")
	if err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster join:", err)
		return 1
	}
	registerAuthzRoutes(srv, decider, keys, modelExecutor, node, forwardTLS, rotationHolder, mtlsForwardTLS, mtlsForwardStore, raftTrustStore, apiTrustStore)

	// See runClusterBootstrap's identical healthCheckTLS/wireHealthMonitor
	// comment above (T072-FU6/T072-FU7) - kept symmetric across both
	// subcommands, so a joined follower node runs the SAME resource-
	// heartbeat + health-driven replication-role-failover mechanism a
	// bootstrap leader does.
	healthCheckTLS, _, err := buildNodeTLSConfig(ca, nodeID+"-health-client")
	if err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster join:", err)
		return 1
	}
	_, stopHealthMonitor := wireHealthMonitor(node, llmctlPath, healthCheckTLS, forwardTLS)
	defer stopHealthMonitor()

	if err := srv.Listen(apiBind); err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster join: api.Listen:", err)
		return 1
	}
	defer func() { _ = srv.Close() }()

	joinClientTLS, _, err := buildNodeTLSConfig(ca, nodeID+"-join-client")
	if err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster join:", err)
		return 1
	}
	resources, err := probeLocalResources(llmctlPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster join: probeLocalResources:", err)
		return 1
	}
	// srv.Addr (this node's own real bound cluster-API address, known only
	// after srv.Listen above) is forwarded as RequestJoin's apiAddr so the
	// leader's own Join call populates ClusterState.Nodes[nodeID].APIAddr -
	// the cross-node-forwarding dial target 002-cluster-model-scheduler's
	// T017 AND 003-kv-cache-replication's T008 (internal/replication.Forwarder's
	// AddrResolver) both need (see internal/raft/node.go's Join doc
	// comment for the distinction between this and node.Addr(), the Raft
	// transport address).
	if err := api.RequestJoin(joinClientTLS, leaderAPI, nodeID, node.Addr(), srv.Addr, resources); err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster join: RequestJoin:", err)
		return 1
	}

	fmt.Printf("READY node_id=%s raft_addr=%s api_addr=%s\n", nodeID, node.Addr(), srv.Addr)

	waitForShutdownSignal()
	return 0
}
