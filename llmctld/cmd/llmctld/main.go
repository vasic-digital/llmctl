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
// T072-FU4's model-lifecycle dispatch routes, onto srv's router, backed
// by decider, keys, and modelExecutor - the one call site both
// runClusterBootstrap and runClusterJoinReal use, so the two subcommands'
// wiring can never drift apart.
func registerAuthzRoutes(srv *api.Server, decider *authz.Decider, keys *auth.Store, modelExecutor *executor.LocalExecutor) {
	api.RegisterAuthRoutes(srv.Router(), decider, keys)
	api.RegisterTenantRoutes(srv.Router(), decider)
	api.RegisterAuditRoutes(srv.Router(), decider)
	api.RegisterModelRoutes(srv.Router(), decider, modelExecutor)
}

// version is the llmctld build version. It is bumped alongside the bash
// CLI's LLMCTL_VERSION in bin/llmctl, but tracked independently since the
// two components ship on separate lifecycles (Constitution §11.4.264).
const version = "0.1.0"

func main() {
	if len(os.Args) > 1 && (os.Args[1] == "version" || os.Args[1] == "--version") {
		fmt.Println("llmctld " + version)
		return
	}

	if len(os.Args) > 2 && os.Args[1] == "cluster" {
		switch os.Args[2] {
		case "bootstrap":
			runClusterBootstrap(os.Args[3:])
			return
		case "join":
			runClusterJoin(os.Args[3:])
			return
		}
	}

	fmt.Fprintln(os.Stderr, "llmctld: cluster mode is not yet implemented (Phase 1 scaffold only)")
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
func buildNodeTLSConfig(ca *mtls.CA, nodeID string) (*tls.Config, error) {
	nodeCert, err := ca.IssueNodeCert(nodeID)
	if err != nil {
		return nil, fmt.Errorf("issue node cert for %q: %w", nodeID, err)
	}
	cert, err := mtls.LoadTLSCertificate(nodeCert.CertPEM, nodeCert.KeyPEM)
	if err != nil {
		return nil, fmt.Errorf("load node cert for %q: %w", nodeID, err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(ca.CertPEM) {
		return nil, fmt.Errorf("add CA cert to pool for %q", nodeID)
	}
	return &tls.Config{
		Certificates:          []tls.Certificate{cert},
		RootCAs:               pool,
		ClientCAs:             pool,
		ClientAuth:            tls.RequireAndVerifyClientCert,
		InsecureSkipVerify:    true,
		VerifyPeerCertificate: raft.VerifyPeerCertificateAgainstCA(pool),
	}, nil
}

// forwardClientRequestTimeout bounds the http.Client-level timeout for
// one forwarded HTTP/3+mTLS request (internal/api's NewNodeForwarder,
// T008) - distinct from internal/replication's own forwardRetryBudget
// (that one bounds the forwarder's OWN retry loop across potentially
// several attempts to one replica); kept generous relative to that
// budget so this client-level timeout is never what actually fires
// first for a healthy replica.
const forwardClientRequestTimeout = 10 * time.Second

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

// selfRegisterRetryInterval/selfRegisterRetryBudget bound
// selfRegisterOwnAPIAddr's background retry loop - see its own doc
// comment for why a bootstrap node needs this at all.
const (
	selfRegisterRetryInterval = 100 * time.Millisecond
	selfRegisterRetryBudget   = 10 * time.Second
)

// selfRegisterOwnAPIAddr registers node's own real HTTP API address
// (apiAddr) into the cluster's Raft-replicated node registry under
// node's own ID, once node has become its own Raft leader (T008,
// 003-kv-cache-replication): a freshly-bootstrapped single-node cluster
// is NOT its own leader instantly (the same real hashicorp/raft
// randomized election-timeout race api/client.go's RequestJoin doc
// comment already documents for a JOINING node), so a naive immediate
// RegisterNode call would fail with hraft.ErrNotLeader on every real
// bootstrap. Unlike a joining node - whose registration is driven by the
// EXISTING leader's own /v1/cluster/join handler
// (routes_cluster.go) - the BOOTSTRAP node has no other leader to
// register it, so it must register itself the moment it becomes leader.
// Callers run this in the background (a goroutine) so it never blocks
// runClusterBootstrap's own startup - the election race is bounded but
// not instant, and this node's own append/checkpoint routes already work
// (against its own local Store) before this completes; only cross-node
// forwarding depends on it.
func selfRegisterOwnAPIAddr(node *raft.Node, apiAddr string) {
	deadline := time.Now().Add(selfRegisterRetryBudget)
	for {
		if node.IsLeader() {
			if err := node.RegisterNode(node.ID(), apiAddr); err == nil {
				return
			}
		}
		if time.Now().After(deadline) {
			fmt.Fprintf(os.Stderr, "llmctld: cluster bootstrap: self-register own API address %q: gave up after %s\n", apiAddr, selfRegisterRetryBudget)
			return
		}
		time.Sleep(selfRegisterRetryInterval)
	}
}

// waitForShutdownSignal blocks until SIGINT or SIGTERM, so a
// llmctld cluster process stays up (serving Raft + the HTTP API) until
// explicitly told to stop - the real, killable-by-a-test-harness process
// shape T051/T054's real multi-process integration tests require.
func waitForShutdownSignal() {
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	<-sigCh
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

	raftTLS, err := buildNodeTLSConfig(ca, f.nodeID)
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

	apiTLS, err := buildNodeTLSConfig(ca, f.nodeID+"-api")
	if err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster bootstrap:", err)
		os.Exit(1)
	}
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
	forwardClientTLS, err := buildNodeTLSConfig(ca, f.nodeID+"-forward-client")
	if err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster bootstrap:", err)
		os.Exit(1)
	}
	forwarder := api.NewNodeForwarder(node, newForwardingHTTPClient(forwardClientTLS))
	api.RegisterReplicationRoutes(srv.Router(), storeRegistry, decider, node, forwarder)

	modelExecutor := executor.New(executor.Config{LLMCtlPath: f.llmctlPath})
	registerAuthzRoutes(srv, decider, keys, modelExecutor)

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

	// T008: a bootstrap node has no other leader to register it into the
	// node registry (unlike a joining node - routes_cluster.go's own
	// /v1/cluster/join handler does that for it) - it must register
	// itself, once it becomes its own Raft leader (selfRegisterOwnAPIAddr's
	// own doc comment). Backgrounded so it never blocks this process's own
	// startup/READY line.
	go selfRegisterOwnAPIAddr(node, srv.Addr)

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

	raftTLS, err := buildNodeTLSConfig(ca, nodeID)
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

	apiTLS, err := buildNodeTLSConfig(ca, nodeID+"-api")
	if err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster join:", err)
		return 1
	}
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
	forwardClientTLS, err := buildNodeTLSConfig(ca, nodeID+"-forward-client")
	if err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster join:", err)
		return 1
	}
	forwarder := api.NewNodeForwarder(node, newForwardingHTTPClient(forwardClientTLS))
	api.RegisterReplicationRoutes(srv.Router(), storeRegistry, decider, node, forwarder)
	modelExecutor := executor.New(executor.Config{LLMCtlPath: llmctlPath})
	registerAuthzRoutes(srv, decider, keys, modelExecutor)

	if err := srv.Listen(apiBind); err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster join: api.Listen:", err)
		return 1
	}
	defer func() { _ = srv.Close() }()

	joinClientTLS, err := buildNodeTLSConfig(ca, nodeID+"-join-client")
	if err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster join:", err)
		return 1
	}
	if err := api.RequestJoin(joinClientTLS, leaderAPI, nodeID, node.Addr(), srv.Addr); err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster join: RequestJoin:", err)
		return 1
	}

	fmt.Printf("READY node_id=%s raft_addr=%s api_addr=%s\n", nodeID, node.Addr(), srv.Addr)

	waitForShutdownSignal()
	return 0
}
