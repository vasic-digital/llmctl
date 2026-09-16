// Package integration holds real-process, no-mocks integration tests for
// llmctld's cluster mode (Constitution §11.4.27: every non-unit test type
// interacts with the real, fully implemented system). Every test in this
// package builds the REAL llmctld binary and spawns REAL OS processes -
// never an in-process fake, never a mocked subprocess.
package integration

import (
	"bufio"
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"syscall"
	"testing"
	"time"

	"github.com/quic-go/quic-go/http3"

	"github.com/vasic-digital/llmctl/llmctld/internal/mtls"
	"github.com/vasic-digital/llmctl/llmctld/internal/raft"
)

// buildLLMCtld compiles the REAL llmctld binary once per test run into a
// scratch directory, returning its path. Every test in this package
// spawns THIS exact binary as a real OS process - there is no
// alternative in-process code path being exercised.
func buildLLMCtld(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	binPath := filepath.Join(dir, "llmctld")

	// llmctld/test/integration -> llmctld (the module root, where
	// ./cmd/llmctld lives) - resolved relative to this test file's own
	// working directory (`go test` always runs with cwd = the package
	// directory), never hardcoded to an absolute path that would only
	// work from one specific checkout location.
	cmd := exec.Command("go", "build", "-o", binPath, "../../cmd/llmctld")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("go build ./cmd/llmctld: %v\n%s", err, out)
	}
	return binPath
}

// readyLine matches the real "READY node_id=... raft_addr=... api_addr=..."
// line cmd/llmctld's main.go prints once a node is genuinely up - the
// mechanism this test uses to learn each process's REAL ephemeral-port
// bound addresses, never a guessed or fixed port.
var readyLine = regexp.MustCompile(`^READY node_id=(\S+) raft_addr=(\S+) api_addr=(\S+)$`)

// spawnedNode is one real, running llmctld OS process this test owns.
type spawnedNode struct {
	nodeID   string
	cmd      *exec.Cmd
	raftAddr string
	apiAddr  string
	logBuf   *bytes.Buffer
}

// waitForReady scans proc's stdout for the real READY line cmd/llmctld's
// main.go prints, populating raftAddr/apiAddr from what the process
// ACTUALLY bound (never assumed), or fails the test if the process exits
// or times out first.
func waitForReady(t *testing.T, n *spawnedNode, stdout *bufio.Scanner, timeout time.Duration) {
	t.Helper()
	done := make(chan struct{})
	go func() {
		defer close(done)
		for stdout.Scan() {
			line := stdout.Text()
			n.logBuf.WriteString(line + "\n")
			if m := readyLine.FindStringSubmatch(line); m != nil {
				n.raftAddr = m[2]
				n.apiAddr = m[3]
				return
			}
		}
	}()

	select {
	case <-done:
		if n.raftAddr == "" {
			t.Fatalf("node %q's stdout ended before printing a READY line; captured output:\n%s", n.nodeID, n.logBuf.String())
		}
	case <-time.After(timeout):
		t.Fatalf("node %q never printed a READY line within %s; captured output so far:\n%s", n.nodeID, timeout, n.logBuf.String())
	}
}

// testCluster owns the CA + scratch dir + spawned processes for one test,
// and guarantees every real process is killed and every temp file is
// cleaned up via t.Cleanup - no leftover llmctld processes survive a
// test, per this project's host-safety discipline.
type testCluster struct {
	t             *testing.T
	binPath       string
	dir           string
	ca            *mtls.CA
	nodes         map[string]*spawnedNode
	jwtSigningKey string
}

func newTestCluster(t *testing.T) *testCluster {
	t.Helper()
	tc := &testCluster{
		t:       t,
		binPath: buildLLMCtld(t),
		dir:     t.TempDir(),
		nodes:   make(map[string]*spawnedNode),
		// Every spawned node needs a real LLMCTLD_JWT_SIGNING_KEY
		// (Phase 11, T074's main.go wiring makes it required) - a fixed
		// per-test-cluster value, not derived from the host's ambient
		// environment, so this test's real process spawns are hermetic
		// regardless of whatever .env the operator's shell happens to
		// have sourced.
		jwtSigningKey: "test-cluster-jwt-signing-key-not-for-production-use",
	}
	t.Cleanup(tc.killAll)
	return tc
}

func (tc *testCluster) killAll() {
	for _, n := range tc.nodes {
		if n.cmd.Process != nil {
			_ = n.cmd.Process.Signal(syscall.SIGTERM)
		}
	}
	for _, n := range tc.nodes {
		_, _ = n.cmd.Process.Wait()
	}
}

// bootstrap spawns the REAL first node of the cluster via
// `llmctld cluster bootstrap`, which generates a fresh CA and writes it
// to this testCluster's scratch dir - every subsequent joined node reads
// that SAME CA from disk, and this test process itself loads it back
// (via mtls.LoadCA) to make real, independently-authenticated HTTP status
// calls against the running cluster.
func (tc *testCluster) bootstrap(nodeID string) *spawnedNode {
	tc.t.Helper()
	caCert := filepath.Join(tc.dir, "ca.crt")
	caKey := filepath.Join(tc.dir, "ca.key")

	n := tc.spawn(nodeID, "bootstrap", nil,
		"-node-id="+nodeID,
		"-raft-bind=127.0.0.1:0",
		"-api-bind=127.0.0.1:0",
		"-ca-cert="+caCert,
		"-ca-key="+caKey,
		// -llmctl-path (002-cluster-model-scheduler T017's RegisterSelf
		// prerequisite, c68ae5d): a real "cluster bootstrap" process now
		// ALWAYS probes real local hardware via bin/llmctl before it can
		// print its READY line - a bare, PATH-resolved "llmctl" is not
		// guaranteed to exist on the host running this test suite (a
		// genuine, previously-undiscovered regression this exact gap
		// caused: every test in this file failed with "executable file
		// not found in $PATH" the moment RegisterSelf's own
		// probeLocalResources call landed), so every spawned bootstrap
		// process needs the REAL repo-root bin/llmctl's path explicitly,
		// exactly like cluster_placement_test.go's own bootstrapWithHW.
		"-llmctl-path="+llmctlBinPath(tc.t),
	)

	certPEM, err := os.ReadFile(caCert)
	if err != nil {
		tc.t.Fatalf("read CA cert written by bootstrap node %q: %v", nodeID, err)
	}
	keyPEM, err := os.ReadFile(caKey)
	if err != nil {
		tc.t.Fatalf("read CA key written by bootstrap node %q: %v", nodeID, err)
	}
	ca, err := mtls.LoadCA(certPEM, keyPEM)
	if err != nil {
		tc.t.Fatalf("mtls.LoadCA on the bootstrap node's own CA output: %v", err)
	}
	tc.ca = ca

	return n
}

// join spawns a REAL additional node via `llmctld cluster join`,
// pointing it at leader's real, already-bound api_addr.
func (tc *testCluster) join(nodeID string, leader *spawnedNode) *spawnedNode {
	tc.t.Helper()
	return tc.spawn(nodeID, "join", nil,
		"-node-id="+nodeID,
		"-raft-bind=127.0.0.1:0",
		"-api-bind=127.0.0.1:0",
		"-ca-cert="+filepath.Join(tc.dir, "ca.crt"),
		"-ca-key="+filepath.Join(tc.dir, "ca.key"),
		"-leader-api="+leader.apiAddr,
		// -llmctl-path: a "cluster join" process ALSO probes real local
		// hardware (its own resources, forwarded via RequestJoin) before
		// printing READY - the same bare-PATH-resolution gap bootstrap()
		// above has, fixed identically.
		"-llmctl-path="+llmctlBinPath(tc.t),
	)
}

// extraEnv (002-cluster-model-scheduler T013/T014's own prerequisite) is
// appended after this process's ambient environment + the mandatory
// LLMCTLD_JWT_SIGNING_KEY - additional "KEY=value" pairs a caller needs
// set on the spawned process (e.g. LLMCTL_DRY_RUN=1 +
// LLMCTL_FAKE_HW=<per-node fixture path>, so each real node's real
// bin/llmctl subprocess reports a DIFFERENT real hardware capacity - the
// exact mechanism a cluster-placement test needs to make only one node
// genuinely fit a workload). nil for every pre-existing caller
// (bootstrap/join/bootstrapWithAdmin), which need no additional env.
func (tc *testCluster) spawn(nodeID, subcommand string, extraEnv []string, extraArgs ...string) *spawnedNode {
	tc.t.Helper()
	args := append([]string{"cluster", subcommand}, extraArgs...)
	cmd := exec.Command(tc.binPath, args...)
	cmd.Env = append(os.Environ(), "LLMCTLD_JWT_SIGNING_KEY="+tc.jwtSigningKey)
	cmd.Env = append(cmd.Env, extraEnv...)

	stdoutPipe, err := cmd.StdoutPipe()
	if err != nil {
		tc.t.Fatalf("StdoutPipe for %q: %v", nodeID, err)
	}
	cmd.Stderr = os.Stderr // real stderr (raft's own hclog output) surfaced directly for debugging, not swallowed

	n := &spawnedNode{nodeID: nodeID, cmd: cmd, logBuf: &bytes.Buffer{}}
	if err := cmd.Start(); err != nil {
		tc.t.Fatalf("start real llmctld process for %q: %v", nodeID, err)
	}
	tc.nodes[nodeID] = n

	waitForReady(tc.t, n, bufio.NewScanner(stdoutPipe), 10*time.Second)
	return n
}

// httpClient builds a real HTTP/3+mTLS client this TEST process can use
// to independently query a running node's cluster API - certified by the
// SAME CA every spawned process trusts, so the requests are genuinely
// authenticated, not merely "requests that happen to work because
// verification is off".
func (tc *testCluster) httpClient() *http.Client {
	tc.t.Helper()
	nodeCert, err := tc.ca.IssueNodeCert("test-observer")
	if err != nil {
		tc.t.Fatalf("issue observer cert: %v", err)
	}
	cert, err := mtls.LoadTLSCertificate(nodeCert.CertPEM, nodeCert.KeyPEM)
	if err != nil {
		tc.t.Fatalf("load observer cert: %v", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(tc.ca.CertPEM) {
		tc.t.Fatalf("add CA cert to observer pool")
	}
	tlsConf := &tls.Config{
		Certificates:          []tls.Certificate{cert},
		RootCAs:               pool,
		InsecureSkipVerify:    true,
		VerifyPeerCertificate: raft.VerifyPeerCertificateAgainstCA(pool),
	}
	return &http.Client{Transport: &http3.Transport{TLSClientConfig: tlsConf}, Timeout: 5 * time.Second}
}

type nodesResponse struct {
	Servers []raft.ServerInfo `json:"servers"`
}

type statusResponse struct {
	IsLeader bool `json:"is_leader"`
}

func (tc *testCluster) getNodes(client *http.Client, apiAddr string) (nodesResponse, error) {
	resp, err := client.Get("https://" + apiAddr + "/v1/cluster/nodes")
	if err != nil {
		return nodesResponse{}, err
	}
	defer func() { _ = resp.Body.Close() }()
	var got nodesResponse
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		return nodesResponse{}, fmt.Errorf("decode /v1/cluster/nodes response: %w", err)
	}
	return got, nil
}

func (tc *testCluster) getStatus(client *http.Client, apiAddr string) (statusResponse, error) {
	resp, err := client.Get("https://" + apiAddr + "/v1/cluster/status")
	if err != nil {
		return statusResponse{}, err
	}
	defer func() { _ = resp.Body.Close() }()
	var got statusResponse
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		return statusResponse{}, fmt.Errorf("decode /v1/cluster/status response: %w", err)
	}
	return got, nil
}

// TestClusterBootstrap_ThreeRealProcessesElectLeaderWithin5s is T051: spin
// up 3 REAL llmctld processes on real loopback ports (real OS processes,
// real QUIC+mTLS transports, real HTTP/3 API servers - nothing mocked or
// run in-process), and assert Raft leader election completes within 5s
// (SC-013), verified via a real, independently-authenticated HTTP status
// call against the bootstrap node, and cross-checked via a real
// GET /v1/cluster/nodes call showing all 3 nodes in the replicated
// configuration.
func TestClusterBootstrap_ThreeRealProcessesElectLeaderWithin5s(t *testing.T) {
	tc := newTestCluster(t)

	nodeA := tc.bootstrap("node-a")
	nodeB := tc.join("node-b", nodeA)
	nodeC := tc.join("node-c", nodeA)

	client := tc.httpClient()

	deadline := time.Now().Add(5 * time.Second)
	var lastErr error
	for time.Now().Before(deadline) {
		status, err := tc.getStatus(client, nodeA.apiAddr)
		if err == nil && status.IsLeader {
			nodes, err := tc.getNodes(client, nodeA.apiAddr)
			if err == nil && len(nodes.Servers) == 3 {
				t.Logf("leader election + full 3-node configuration confirmed within %s", 5*time.Second-time.Until(deadline))
				return
			}
			lastErr = err
		} else {
			lastErr = err
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("SC-013 violated: leader election with a full 3-node configuration did not complete within 5s (last error: %v); node-a log:\n%s\nnode-b log:\n%s\nnode-c log:\n%s",
		lastErr, nodeA.logBuf.String(), nodeB.logBuf.String(), nodeC.logBuf.String())
}

// TestClusterFailover_KillingLeaderElectsNewRealLeaderAmongSurvivors is
// this project's honest scope for T054 against the CURRENT codebase.
//
// Honest boundary (Constitution §11.4.223 provenance markers, disclosed
// rather than silently narrowed): T054's literal text asks to prove "its
// models are rescheduled onto a healthy node within 30s with zero data
// loss" after killing a process. That specific claim requires (a) a real
// workload/model actually PLACED onto a cluster node, and (b) an
// automatic health-check-driven rescheduling loop wired into the RUNNING
// llmctld binary. Neither exists yet: internal/cluster/health.go's
// Monitor/Reconcile and internal/executor/local.go's LocalExecutor are
// real, TDD-tested LIBRARY functions (T053/T052a/T056), but
// cmd/llmctld's main.go does not yet invoke them on a schedule against
// live cluster membership, and no test fixture "model" is ever placed
// anywhere in this test - fabricating a rescheduling assertion against
// behavior that isn't wired into the real running binary would be
// exactly the anti-bluff violation Constitution §11.4/§11.4.6 forbid.
//
// What IS real and IS proven here: killing the current REAL Raft leader
// process causes the two REAL surviving processes to elect a NEW real
// leader among themselves within a bounded time - the actual mechanism
// FR-025's "detect within 10s" / SC-015's failover timing bounds on
// (leader-driven rescheduling would build ON TOP of this same detection
// signal once wired). The model-rescheduling half is tracked as an
// honest gap for a future round, not claimed done.
func TestClusterFailover_KillingLeaderElectsNewRealLeaderAmongSurvivors(t *testing.T) {
	tc := newTestCluster(t)

	nodeA := tc.bootstrap("node-a")
	nodeB := tc.join("node-b", nodeA)
	nodeC := tc.join("node-c", nodeA)

	client := tc.httpClient()

	// Confirm the initial 3-node configuration is DURABLY replicated to
	// EVERY node - not merely accepted by the leader - before killing
	// anything. This is a genuine precondition, found as a real bug: an
	// earlier version of this test killed node-a immediately after its
	// own /v1/cluster/nodes reported 3 servers, but a leader's own
	// configuration reflects the change the instant it appends the log
	// entry locally, well before that entry is actually replicated to
	// (and durably held by) a majority of followers. Killing the leader
	// in that narrow window left the survivors "not part of a stable
	// configuration" (a real hashicorp/raft safety mechanism against
	// election during a pending configuration change), and they correctly
	// refused to elect - exactly reproduced and observed via the real
	// log line "not part of stable configuration, aborting election"
	// before this fix. Waiting for EACH survivor to independently confirm
	// 3 servers proves the configuration change is durable everywhere,
	// not merely locally on the leader.
	deadline := time.Now().Add(5 * time.Second)
	for _, n := range []*spawnedNode{nodeA, nodeB, nodeC} {
		for {
			nodes, err := tc.getNodes(client, n.apiAddr)
			if err == nil && len(nodes.Servers) == 3 {
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("precondition failed: node %q never observed the full 3-node configuration before the failover test began", n.nodeID)
			}
			time.Sleep(50 * time.Millisecond)
		}
	}

	// Kill the real leader process - a genuine OS-level SIGKILL, not a
	// graceful shutdown, so the survivors experience a real
	// heartbeat-timeout-driven election exactly as a real crash would.
	if err := nodeA.cmd.Process.Kill(); err != nil {
		t.Fatalf("kill node-a: %v", err)
	}
	_, _ = nodeA.cmd.Process.Wait()
	delete(tc.nodes, "node-a") // already dead; killAll must not try to signal it again

	// Assert one of the two REAL survivors becomes the new real leader
	// within 30s (SC-015's failover-completion bound, applied here to
	// leader re-election specifically, since that is the mechanism this
	// codebase genuinely implements).
	deadline = time.Now().Add(30 * time.Second)
	var lastErr error
	for time.Now().Before(deadline) {
		for _, n := range []*spawnedNode{nodeB, nodeC} {
			status, err := tc.getStatus(client, n.apiAddr)
			if err == nil && status.IsLeader {
				t.Logf("new real leader %q elected among the survivors within %s of node-a's kill", n.nodeID, 30*time.Second-time.Until(deadline))
				return
			}
			lastErr = err
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("no new leader was elected among the surviving real processes within 30s of killing the leader (last error: %v); node-b log:\n%s\nnode-c log:\n%s",
		lastErr, nodeB.logBuf.String(), nodeC.logBuf.String())
}
