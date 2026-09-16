// Package raft (node.go): wires ClusterFSM (fsm.go), an in-memory Raft
// log/stable/snapshot store, and the QUIC+mTLS transport (transport.go)
// together into one running hashicorp/raft node (FR-019).
package raft

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"time"

	hraft "github.com/hashicorp/raft"

	"github.com/vasic-digital/llmctl/llmctld/internal/cluster"
)

const (
	transportMaxPool = 3
	transportTimeout = 10 * time.Second
	joinTimeout      = 10 * time.Second
	leaveTimeout     = 10 * time.Second
	// applyTimeout bounds Join/Leave's own post-membership-change
	// n.raft.Apply call (002-cluster-model-scheduler T004/T005) - the log
	// entry that actually populates/removes the joined/leaving node's
	// ClusterState.Nodes entry, distinct from joinTimeout/leaveTimeout
	// which bound hashicorp/raft's own AddVoter/RemoveServer membership
	// change.
	applyTimeout = 10 * time.Second
	// raftApplyTimeout bounds RevokeCertificate's Raft Apply call - a
	// dedicated constant (rather than reusing lock.go's lockApplyTimeout)
	// since revocation and distributed-lock commands are unrelated
	// concerns that happen to share the same reasonable default timeout
	// value, not the same semantic deadline.
	raftApplyTimeout = 5 * time.Second
)

// Config configures one cluster Node.
type Config struct {
	// NodeID is this node's stable Raft identity (hraft.ServerID) - the
	// same identity used to issue this node's mTLS certificate via
	// internal/mtls.IssueNodeCert.
	NodeID string
	// BindAddr is the address this node's QUIC+mTLS transport listens on
	// (e.g. "127.0.0.1:0" for an ephemeral test port).
	BindAddr string
	// TLSConfig is this node's mTLS configuration, built from
	// internal/mtls-issued certificates (Clarification 11) - see
	// transport_test.go's buildNodeTLSConfig for the reference shape.
	TLSConfig *tls.Config
}

// Node is one cluster member: a real hashicorp/raft instance backed by an
// in-memory store and this node's ClusterFSM, reachable over transport.go's
// QUIC+mTLS transport.
type Node struct {
	raft      *hraft.Raft
	fsm       *ClusterFSM
	transport *hraft.NetworkTransport
	localID   hraft.ServerID
}

// newRaftNode builds the shared plumbing (transport + FSM + in-memory
// store + hraft.Config) both Bootstrap and New need, without deciding
// whether to bootstrap a fresh single-node configuration - that decision
// is each caller's alone.
func newRaftNode(cfg Config) (transport *hraft.NetworkTransport, fsm *ClusterFSM, logStore hraft.LogStore, stableStore hraft.StableStore, snapStore hraft.SnapshotStore, raftConfig *hraft.Config, err error) {
	transport, err = NewTransport(cfg.BindAddr, cfg.TLSConfig, transportMaxPool, transportTimeout)
	if err != nil {
		return nil, nil, nil, nil, nil, nil, fmt.Errorf("raft: node %q: build transport: %w", cfg.NodeID, err)
	}

	fsm = NewClusterFSM()
	logStore = hraft.NewInmemStore()
	stableStore = hraft.NewInmemStore()
	snapStore = hraft.NewInmemSnapshotStore()

	raftConfig = hraft.DefaultConfig()
	raftConfig.LocalID = hraft.ServerID(cfg.NodeID)

	return transport, fsm, logStore, stableStore, snapStore, raftConfig, nil
}

// Bootstrap wires fsm.go + an in-memory store + transport.go together into
// a brand-new, single-node Raft cluster with cfg.NodeID as its only (and
// initially leading) voter. Call Bootstrap exactly once, for the very
// first node of a cluster; every subsequent node is created with New and
// brought in via the existing leader's Join(peerAddr).
func Bootstrap(cfg Config) (*Node, error) {
	transport, fsm, logStore, stableStore, snapStore, raftConfig, err := newRaftNode(cfg)
	if err != nil {
		return nil, err
	}

	bootstrapConfig := hraft.Configuration{
		Servers: []hraft.Server{
			{ID: raftConfig.LocalID, Address: transport.LocalAddr()},
		},
	}
	if err := hraft.BootstrapCluster(raftConfig, logStore, stableStore, snapStore, transport, bootstrapConfig); err != nil {
		_ = transport.Close()
		return nil, fmt.Errorf("raft: bootstrap %q: %w", cfg.NodeID, err)
	}

	r, err := hraft.NewRaft(raftConfig, fsm, logStore, stableStore, snapStore, transport)
	if err != nil {
		_ = transport.Close()
		return nil, fmt.Errorf("raft: bootstrap %q: start raft: %w", cfg.NodeID, err)
	}

	return &Node{raft: r, fsm: fsm, transport: transport, localID: raftConfig.LocalID}, nil
}

// New starts cfg's Raft instance WITHOUT bootstrapping a configuration -
// the node sits idle (a follower with no known peers) until an existing
// cluster's leader calls Join(peerAddr) naming this node's transport
// address, at which point it receives the resulting configuration change
// via normal Raft log replication, exactly like any other log entry.
func New(cfg Config) (*Node, error) {
	transport, fsm, logStore, stableStore, snapStore, raftConfig, err := newRaftNode(cfg)
	if err != nil {
		return nil, err
	}

	r, err := hraft.NewRaft(raftConfig, fsm, logStore, stableStore, snapStore, transport)
	if err != nil {
		_ = transport.Close()
		return nil, fmt.Errorf("raft: new node %q: start raft: %w", cfg.NodeID, err)
	}

	return &Node{raft: r, fsm: fsm, transport: transport, localID: raftConfig.LocalID}, nil
}

// Join adds peerID, reachable at peerAddr, as a voting member of n's Raft
// cluster, AND applies a real CommandJoinNode log entry so
// ClusterState.Nodes[peerID] genuinely reflects the join with resources as
// its Resources (002-cluster-model-scheduler T004) - before this, Join
// only ever changed hashicorp/raft's own membership configuration, and
// ClusterState.Nodes (the map cluster.Place's own candidate-selection
// reads) never observed ANY join, no matter how many peers had joined; a
// start request naming no node had zero real candidates to place onto
// regardless of cluster size. n must currently be the cluster leader -
// hashicorp/raft's AddVoter enforces that itself (returns
// hraft.ErrNotLeader otherwise), so Join is a thin, honestly-erroring
// wrapper around it; forwarding a Join request to the real leader over the
// network is a T058 HTTP-layer concern, not this package's.
//
// peerID MUST be the joining node's own real Config.NodeID (the same
// value it set as its own raft.Config.LocalID) - NOT derived from
// peerAddr. An earlier version of this function used peerAddr as BOTH the
// ServerID and ServerAddress; that is a real bug, found via a genuine
// end-to-end failover test (T054): a joined node's raft.Config.LocalID is
// its human-assigned NodeID (e.g. "node-b"), so hashicorp/raft's own
// internal "do I have a vote in the stable configuration?" check
// (hasVote(configurations.latest, r.localID), raft.go's heartbeat-timeout
// election-eligibility logic) compared the WRONG value against the
// configuration entry: the entry was keyed by the node's ADDRESS, while
// the node checks for ITS OWN NodeID. The mismatch meant a joined
// follower could NEVER recognize itself as having a vote, so it silently
// refused to ever start an election - invisible until the original leader
// actually died and a follower needed to take over, at which point every
// survivor logged "not part of stable configuration, aborting election"
// forever. Fixed by requiring the caller to supply the peer's real ID.
// apiAddr (002-cluster-model-scheduler T017's prerequisite) is the joining
// peer's own real HTTP/3+mTLS cluster-API bind address (internal/
// api.Server's bound address on that peer, NOT peerAddr - a distinct
// listener/port entirely, see cluster.Node.APIAddr's own doc comment) -
// stored into ClusterState.Nodes[peerID].APIAddr so cross-node
// model-lifecycle forwarding (routes_models.go) knows where to dial a
// chosen node that is not the one that received the original HTTP
// request. Before this, APIAddr was declared but never populated by
// anything - a real, found gap (every ClusterState.Nodes entry's APIAddr
// was silently "").
func (n *Node) Join(peerID, peerAddr, apiAddr string, resources cluster.Resources) error {
	future := n.raft.AddVoter(hraft.ServerID(peerID), hraft.ServerAddress(peerAddr), 0, joinTimeout)
	if err := future.Error(); err != nil {
		return err
	}

	cmd := Command{Type: CommandJoinNode, Node: &cluster.Node{ID: peerID, Addr: peerAddr, APIAddr: apiAddr, Health: "healthy", Resources: resources}}
	data, err := json.Marshal(cmd)
	if err != nil {
		return fmt.Errorf("raft: join %q: marshal CommandJoinNode: %w", peerID, err)
	}
	return n.raft.Apply(data, applyTimeout).Error()
}

// RegisterSelf applies a real CommandJoinNode log entry for n's OWN
// localID, carrying apiAddr and resources - the bootstrap-leader
// equivalent of Join's peer-registration (002-cluster-model-scheduler
// T017's prerequisite). This is required because Bootstrap's own
// single-node hraft.BootstrapCluster call only ever establishes n as a
// Raft VOTER; it never applies a CommandJoinNode entry for n's own ID, so
// a freshly-bootstrapped leader was genuinely, silently absent from its
// own ClusterState.Nodes - invisible to cluster.Place's candidate list
// (which reads State().Nodes directly) even though it is a perfectly
// legitimate placement target. Callers invoke this exactly once, after
// their own real API server has bound its real address (so apiAddr is
// never a placeholder) and their own real hardware probe has run (so
// resources is never a zero value).
func (n *Node) RegisterSelf(apiAddr string, resources cluster.Resources) error {
	cmd := Command{Type: CommandJoinNode, Node: &cluster.Node{ID: string(n.localID), Addr: n.Addr(), APIAddr: apiAddr, Health: "healthy", Resources: resources}}
	data, err := json.Marshal(cmd)
	if err != nil {
		return fmt.Errorf("raft: register self %q: marshal CommandJoinNode: %w", n.localID, err)
	}
	return n.raft.Apply(data, applyTimeout).Error()
}

// UpdateResources refreshes nodeID's already-known Resources in the
// cluster's Raft-replicated state (fsm.go's CommandUpdateResources,
// 002-cluster-model-scheduler's resource-freshness heartbeat) - the
// Node-level proposer T072-FU6 wires cluster.Monitor.SetResourceReporting
// against (cmd/llmctld's main.go's wireHealthMonitor), closing this
// project's own disclosed gap that the heartbeat mechanism had zero
// non-test callers repo-wide (docs/CONTINUATION.md §10f).
//
// Uses the shared applyCommand helper (replication_commands.go) rather
// than Join/RegisterSelf's own inline marshal+Apply, matching
// AssignReplicationRole/ReassignReplicationRole's identical "decide
// elsewhere, durably commit here" shape - fsm.go's own Apply case
// additionally refuses an unknown nodeID (errUpdateResourcesUnknownNode)
// rather than silently creating a new, incomplete Nodes entry, so a
// caller updating resources for a node that has not yet completed
// Join/RegisterSelf gets an honest error, never a partial record.
//
// Like every other Apply-backed method in this package, this MUST run
// against the current Raft leader - hashicorp/raft's own Apply enforces
// that itself (hraft.ErrNotLeader otherwise); a caller on a follower node
// forwards the SAME update to the leader instead (internal/api's
// ForwardUpdateResources).
func (n *Node) UpdateResources(nodeID string, resources cluster.Resources) error {
	return n.applyCommand(Command{Type: CommandUpdateResources, NodeID: nodeID, Resources: resources})
}

// Leave removes n's own node from its Raft cluster (RemoveServer against
// n's own localID), AND applies a real CommandLeaveNode log entry so
// ClusterState.Nodes no longer carries n's own entry after it leaves
// (002-cluster-model-scheduler T005 - the removal-side mirror of Join's
// T004 fix; before this, a left node's stale entry stayed in
// ClusterState.Nodes forever, so cluster.Place could still choose a node
// that had genuinely left). Like Join, this must run against the leader -
// a follower calling Leave on itself gets hraft.ErrNotLeader back,
// honestly; a follower wanting to leave gracefully asks the leader to
// remove it via the T058 HTTP layer instead of calling this locally.
//
// The CommandLeaveNode Apply runs BEFORE RemoveServer, deliberately the
// REVERSE of Join's Apply-after-AddVoter order: hashicorp/raft's own
// RemoveServer, when the target IS the calling leader itself (exactly
// Leave's only case - n always removes n.localID), triggers that
// leader's IMMEDIATE self-shutdown the instant the configuration-removal
// entry commits ("removed ourself, shutting down" - raft.go's
// leaderLoop). Discovered as a genuine RED via this exact TDD cycle
// (T005): the literal "Apply after RemoveServer" order this task
// initially specified reproducibly failed with "raft is already
// shutdown" on every run, because by the time Apply ran, n's own raft
// instance had already torn itself down. Applying first, while n is
// still the fully-operational leader, then removing the voter (whose
// resulting self-shutdown is now harmless because the state mutation
// already committed) is the only ordering that can succeed.
func (n *Node) Leave() error {
	cmd := Command{Type: CommandLeaveNode, NodeID: string(n.localID)}
	data, err := json.Marshal(cmd)
	if err != nil {
		return fmt.Errorf("raft: leave %q: marshal CommandLeaveNode: %w", n.localID, err)
	}
	if err := n.raft.Apply(data, applyTimeout).Error(); err != nil {
		return err
	}

	return n.raft.RemoveServer(n.localID, 0, leaveTimeout).Error()
}

// LeaderCh reports true when n becomes leader and false when it steps
// down, exactly as the underlying hraft.Raft.LeaderCh does.
func (n *Node) LeaderCh() <-chan bool {
	return n.raft.LeaderCh()
}

// Shutdown stops n's Raft instance and closes its transport.
func (n *Node) Shutdown() error {
	if err := n.raft.Shutdown().Error(); err != nil {
		return err
	}
	return n.transport.Close()
}

// State returns a deep-copied snapshot of n's replicated cluster state,
// safe for callers to read without racing the FSM's own apply goroutine.
func (n *Node) State() *cluster.ClusterState {
	return n.fsm.State()
}

// Addr returns n's own real transport bind address (hraft.ServerAddress
// as a plain string) - the value another node's Join(peerAddr) needs to
// bring n into its cluster. Valid regardless of whether n has bootstrapped
// or joined anything yet, since it reads the transport's own listen
// address, not the Raft configuration (an unjoined node's configuration
// is empty until a leader's AddVoter reaches it).
func (n *Node) Addr() string {
	return string(n.transport.LocalAddr())
}

// ID returns n's own stable cluster identity (the same value passed as
// Config.NodeID) - callers outside this package need this to tell
// whether a chosen cluster.Node IS this process, or a different one work
// must be forwarded to: 002-cluster-model-scheduler's T015/T016
// auto-placement handler (client.go's ForwardModelStart) and
// 003-kv-cache-replication's T008 forwarder wiring (replication_commands.go)
// both depend on this exact method for the identical reason.
func (n *Node) ID() string {
	return string(n.localID)
}

// IsLeader reports whether n is currently the Raft leader - the real
// underlying hraft.Raft.State(), for callers outside this package (T058's
// HTTP layer) that cannot reach n's private *hraft.Raft field directly.
func (n *Node) IsLeader() bool {
	return n.raft.State() == hraft.Leader
}

// LeaderAddr returns n's real, current view of the cluster's Raft leader's
// TRANSPORT address (the same value each cluster.Node.Addr carries, set
// from Node.Addr() at Join/RegisterSelf time) - "" when n does not
// currently know of a leader (mid-election, or a genuine partition).
//
// Found necessary as a real, previously-undiscovered gap
// (002-cluster-model-scheduler T013's own real 3-node integration test):
// a Raft write (n.raft.Apply, which CommandRecordRunningProfile's
// RecordRunningProfile needs) can ONLY ever succeed on the current
// leader - a FOLLOWER node's own /start HTTP handler cannot record a
// running-profile reservation locally no matter which cluster node
// cluster.Place() chooses, and must instead forward the WHOLE
// auto-placement decision to the leader (routes_models.go's
// dispatchAutoPlacedStart), exactly mirroring the pre-existing
// RequestJoin/Join split for cluster membership changes (node.go's own
// Join doc comment: "hraft.ErrNotLeader otherwise, so Join is a thin,
// honestly-erroring [wrapper]" - the SAME "writes only work on the
// leader" constraint this method exists to let a caller route around by
// address rather than by trial-and-error).
func (n *Node) LeaderAddr() string {
	return string(n.raft.Leader())
}

// LastContact returns the time n (as a follower) last heard from a
// leader - exposed for cluster.PartitionWatcher's LastContactFunc, which
// cannot reach n's private *hraft.Raft field directly (internal/cluster
// cannot import internal/raft without an import cycle).
func (n *Node) LastContact() time.Time {
	return n.raft.LastContact()
}

// RevokeCertificate submits rec as a real, linearized CommandRevokeCertificate
// Raft log entry (Feature 004, T011) - the same Apply-and-check-the-
// response pattern lock.go's Acquire/Release already establish for this
// package's other FSM commands. Because hashicorp/raft's log commit order
// is total across the whole cluster, once this call returns nil every
// node's ClusterFSM.Apply (or, for a node still catching up via snapshot,
// its Restore) will - now or the moment it replays/restores past this
// entry - invoke the registered revocation handler (SetRevocationHandler)
// with the FSM's mu held, so no node ever observes a torn or
// partially-applied revocation set.
func (n *Node) RevokeCertificate(rec cluster.RevocationRecord) error {
	cmd := Command{Type: CommandRevokeCertificate, Revocation: &rec}
	data, err := json.Marshal(cmd)
	if err != nil {
		return fmt.Errorf("raft: revoke certificate %q: marshal command: %w", rec.SerialNumber, err)
	}

	future := n.raft.Apply(data, raftApplyTimeout)
	if err := future.Error(); err != nil {
		return fmt.Errorf("raft: revoke certificate %q: %w", rec.SerialNumber, err)
	}
	if resp := future.Response(); resp != nil {
		if respErr, isErr := resp.(error); isErr {
			return fmt.Errorf("raft: revoke certificate %q: %w", rec.SerialNumber, respErr)
		}
		// A non-nil, non-error Response would be a fsm.go contract
		// violation (CommandRevokeCertificate only ever returns nil or an
		// error - see fsm.go's Apply) - treat it as a hard failure rather
		// than silently proceeding as if it were success, matching
		// lock.go's Acquire/Release's own identical defensive check.
		return fmt.Errorf("raft: revoke certificate %q: unexpected FSM response type %T", rec.SerialNumber, resp)
	}
	return nil
}

// SetRevocationHandler registers fn to be called on THIS node whenever its
// ClusterFSM applies (or restores) revocation-replicated state (Feature
// 004, T011) - see fsm.go's ClusterFSM.onRevocationApplied doc comment
// for the exact firing points and why fn takes no arguments. Feature 004
// Phase 5 (T023) extends the SAME firing points to
// CommandBeginCARotation/CommandFinalizeCARotation too.
func (n *Node) SetRevocationHandler(fn func()) {
	n.fsm.SetRevocationHandler(fn)
}

// BeginCARotation submits rec as a real, linearized
// CommandBeginCARotation Raft log entry (Feature 004 Phase 5, User Story
// 3, T022) - the SAME Apply-and-check-the-response pattern
// RevokeCertificate above already establishes. Refused by the FSM
// (fsm.go's errCARotationAlreadyInProgress) if a DIFFERENT rotation is
// already in progress; a repeated call carrying the IDENTICAL outgoing/
// incoming fingerprints as an already-in-progress rotation succeeds
// idempotently (fsm.go's own doc comment on that Apply case) - the
// mechanism that lets every node in the cluster call its own local
// "begin rotation" API action without a second/third caller's own Raft
// submission being treated as a conflict.
func (n *Node) BeginCARotation(rec cluster.CARotationEvent) error {
	cmd := Command{Type: CommandBeginCARotation, CARotation: &rec}
	data, err := json.Marshal(cmd)
	if err != nil {
		return fmt.Errorf("raft: begin CA rotation: marshal command: %w", err)
	}
	future := n.raft.Apply(data, raftApplyTimeout)
	if err := future.Error(); err != nil {
		return fmt.Errorf("raft: begin CA rotation: %w", err)
	}
	if resp := future.Response(); resp != nil {
		if respErr, isErr := resp.(error); isErr {
			return fmt.Errorf("raft: begin CA rotation: %w", respErr)
		}
		return fmt.Errorf("raft: begin CA rotation: unexpected FSM response type %T", resp)
	}
	return nil
}

// FinalizeCARotation submits rec as a real CommandFinalizeCARotation
// Raft log entry (Feature 004 Phase 5, T022) - refused by the FSM unless
// a rotation carrying the IDENTICAL outgoing/incoming fingerprints is
// currently in_progress (fsm.go's errCARotationNotInProgress/
// errCARotationFingerprintMismatch). Callers (internal/api/
// routes_mtls.go's POST /v1/cluster/mtls/rotate/finalize) MUST perform
// the FR-010 quorum-protection refusal check BEFORE calling this - the
// FSM itself has no visibility into the current Raft voter configuration
// (that lives in n.raft.GetConfiguration, orthogonal to ClusterState),
// so it cannot perform that check on its own.
func (n *Node) FinalizeCARotation(rec cluster.CARotationEvent) error {
	cmd := Command{Type: CommandFinalizeCARotation, CARotation: &rec}
	data, err := json.Marshal(cmd)
	if err != nil {
		return fmt.Errorf("raft: finalize CA rotation: marshal command: %w", err)
	}
	future := n.raft.Apply(data, raftApplyTimeout)
	if err := future.Error(); err != nil {
		return fmt.Errorf("raft: finalize CA rotation: %w", err)
	}
	if resp := future.Response(); resp != nil {
		if respErr, isErr := resp.(error); isErr {
			return fmt.Errorf("raft: finalize CA rotation: %w", respErr)
		}
		return fmt.Errorf("raft: finalize CA rotation: unexpected FSM response type %T", resp)
	}
	return nil
}

// RecordCARotationTransition submits a real CommandRecordCARotationTransition
// Raft log entry naming nodeID as having confirmed re-issuance under the
// currently in_progress rotation's incoming CA (Feature 004 Phase 5,
// T022/FR-009) - submitted by internal/api/routes_mtls.go's POST
// /v1/cluster/mtls/renew handler the moment ITS OWN local renewal
// completes while this node's own RotationCAHolder shows a rotation is
// locally in progress. A no-op (never an error) if no rotation is
// currently in_progress on whichever node's Raft log this Apply lands on
// (fsm.go's own doc comment) - a stale/late-arriving transition report
// after finalize has nothing left to record.
func (n *Node) RecordCARotationTransition(nodeID string) error {
	cmd := Command{Type: CommandRecordCARotationTransition, NodeID: nodeID}
	data, err := json.Marshal(cmd)
	if err != nil {
		return fmt.Errorf("raft: record CA rotation transition %q: marshal command: %w", nodeID, err)
	}
	future := n.raft.Apply(data, raftApplyTimeout)
	if err := future.Error(); err != nil {
		return fmt.Errorf("raft: record CA rotation transition %q: %w", nodeID, err)
	}
	if resp := future.Response(); resp != nil {
		if respErr, isErr := resp.(error); isErr {
			return fmt.Errorf("raft: record CA rotation transition %q: %w", nodeID, respErr)
		}
		return fmt.Errorf("raft: record CA rotation transition %q: unexpected FSM response type %T", nodeID, resp)
	}
	return nil
}

// ServerInfo describes one member of n's Raft cluster configuration - a
// DTO for callers (T058's GET /v1/cluster/nodes) that cannot reach n's
// private *hraft.Raft field directly.
type ServerInfo struct {
	ID       string
	Address  string
	Suffrage string // "Voter" | "Nonvoter" | "Staging", from hraft.ServerSuffrage.String()
}

// Servers returns n's current real Raft cluster configuration.
func (n *Node) Servers() ([]ServerInfo, error) {
	future := n.raft.GetConfiguration()
	if err := future.Error(); err != nil {
		return nil, fmt.Errorf("raft: get configuration: %w", err)
	}
	cfg := future.Configuration()
	infos := make([]ServerInfo, 0, len(cfg.Servers))
	for _, s := range cfg.Servers {
		infos = append(infos, ServerInfo{ID: string(s.ID), Address: string(s.Address), Suffrage: s.Suffrage.String()})
	}
	return infos, nil
}
