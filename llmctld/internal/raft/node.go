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
func (n *Node) Join(peerID, peerAddr string, resources cluster.Resources) error {
	future := n.raft.AddVoter(hraft.ServerID(peerID), hraft.ServerAddress(peerAddr), 0, joinTimeout)
	if err := future.Error(); err != nil {
		return err
	}

	cmd := Command{Type: CommandJoinNode, Node: &cluster.Node{ID: peerID, Addr: peerAddr, Health: "healthy", Resources: resources}}
	data, err := json.Marshal(cmd)
	if err != nil {
		return fmt.Errorf("raft: join %q: marshal CommandJoinNode: %w", peerID, err)
	}
	return n.raft.Apply(data, applyTimeout).Error()
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

// IsLeader reports whether n is currently the Raft leader - the real
// underlying hraft.Raft.State(), for callers outside this package (T058's
// HTTP layer) that cannot reach n's private *hraft.Raft field directly.
func (n *Node) IsLeader() bool {
	return n.raft.State() == hraft.Leader
}

// LastContact returns the time n (as a follower) last heard from a
// leader - exposed for cluster.PartitionWatcher's LastContactFunc, which
// cannot reach n's private *hraft.Raft field directly (internal/cluster
// cannot import internal/raft without an import cycle).
func (n *Node) LastContact() time.Time {
	return n.raft.LastContact()
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
