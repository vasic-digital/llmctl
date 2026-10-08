// Package vantage provides the SECOND NETWORK LOCATION of FR-064/FR-069/FR-073:
// a tiny rootless container, booted through the Containers submodule
// (digital.vasic.containers/pkg/runtime), that has its own network address
// distinct from the host's loopback. The matrix runner issues calls "from the
// second vantage" by running the static vantage-probe binary inside it.
//
// Helix §11.4.76/§11.4.161: all container work goes through the submodule's
// ContainerRuntime (Run / Exec / Stop / Remove / List); this package never
// shells out to podman itself.
package vantage

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"digital.vasic.containers/pkg/runtime"

	"github.com/vasic-digital/llmctl/internal/vantage/probecore"
)

// NamePrefix is the unique prefix of every object this package creates; cleanup
// only ever touches objects carrying it (host-safety: never other containers).
const NamePrefix = "llmctl-vantage-"

// LabelKey marks containers created here.
const LabelKey = "llmctl.vantage"

// LabelOwner names WHICH state directory created a container: sha256(abs state dir)[:12]. Down
// sweeps only containers carrying its own owner label, so two state dirs (two test runs, the
// matrix plus a manual run) never remove each other's vantage (C-07).
const LabelOwner = "llmctl.vantage.owner"

// Network modes. pasta (the rootless default) copies the host's address into
// the container and is NOT a distinct vantage (measured, see docs/scripts/vantage.md).
const (
	NetSlirp  = "slirp4netns"
	NetBridge = "bridge" // netavark default rootless bridge network
)

// ErrUnavailable means rootless containers cannot run here (callers may skip,
// but must say why). It is never used for a defect.
var ErrUnavailable = errors.New("rootless container runtime unavailable")

// State is persisted at <stateDir>/vantage/state.json.
type State struct {
	Name      string    `json:"name"`
	ID        string    `json:"id"`
	Image     string    `json:"image"`
	Network   string    `json:"network"`
	IP        string    `json:"ip"`      // the container's own address
	Gateway   string    `json:"gateway"` // default gateway as seen from inside
	HostIP    string    `json:"host_ip"` // non-loopback host address reachable from inside
	ProbeDir  string    `json:"probe_dir"`
	CreatedAt time.Time `json:"created_at"`
}

// Options configure a Manager.
type Options struct {
	Runtime  runtime.ContainerRuntime
	StateDir string
	Network  string   // NetSlirp (default) or NetBridge
	Images   []string // candidate local images, tried in order with --pull=never
	ProbeBin string   // path to the static probe ("" = locate/build)
	HostIP   string   // override the detected host address
	Memory   string   // default 64m
	// BuildProbe builds the static probe into dir and returns its path (injectable).
	BuildProbe func(ctx context.Context, dir string) (string, error)
	Now        func() time.Time
}

// Manager drives one vantage container.
type Manager struct{ o Options }

// New returns a Manager.
func New(o Options) *Manager {
	if o.Network == "" {
		o.Network = NetSlirp
	}
	if o.Memory == "" {
		o.Memory = "64m"
	}
	if len(o.Images) == 0 {
		o.Images = DefaultImages()
	}
	if o.Now == nil {
		o.Now = time.Now
	}
	return &Manager{o: o}
}

// DefaultImages is the candidate list (smallest first); $LLMCTL_VANTAGE_IMAGE
// takes precedence. The probe is a static binary so any image works.
func DefaultImages() []string {
	var l []string
	if v := os.Getenv("LLMCTL_VANTAGE_IMAGE"); v != "" {
		l = append(l, v)
	}
	return append(l,
		"gcr.io/distroless/static-debian12:nonroot",
		"docker.io/library/alpine:3.20",
		"docker.io/library/alpine:3.19",
		"docker.io/library/alpine:latest",
		"docker.io/library/debian:trixie-slim",
		"docker.io/library/ubuntu:24.04",
	)
}

// ownerID derives this manager's owner label value from its state directory.
func (m *Manager) ownerID() string {
	abs, err := filepath.Abs(m.o.StateDir)
	if err != nil {
		abs = m.o.StateDir
	}
	sum := sha256.Sum256([]byte(filepath.Clean(abs)))
	return hex.EncodeToString(sum[:])[:12]
}

func (m *Manager) dir() string       { return filepath.Join(m.o.StateDir, "vantage") }
func (m *Manager) statePath() string { return filepath.Join(m.dir(), "state.json") }

// Load reads the state; (nil, nil) when there is none.
func (m *Manager) Load() (*State, error) {
	b, err := os.ReadFile(m.statePath())
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var s State
	if err := json.Unmarshal(b, &s); err != nil {
		return nil, fmt.Errorf("vantage state %s: %w", m.statePath(), err)
	}
	return &s, nil
}

func (m *Manager) save(s *State) error {
	if err := os.MkdirAll(m.dir(), 0o700); err != nil {
		return err
	}
	b, _ := json.MarshalIndent(s, "", "  ")
	tmp := m.statePath() + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, m.statePath())
}

// running reports whether the named container is up (via the submodule).
func (m *Manager) running(ctx context.Context, name string) bool {
	l, err := m.o.Runtime.List(ctx, runtime.ListFilter{Names: []string{name}})
	if err != nil {
		return false
	}
	for _, c := range l {
		if strings.TrimPrefix(c.Name, "/") == name && c.State == runtime.StateRunning {
			return true
		}
	}
	return false
}

// Up boots the vantage (idempotent: a healthy one is returned as is).
func (m *Manager) Up(ctx context.Context) (*State, error) {
	if m.o.StateDir == "" {
		return nil, errors.New("vantage: state dir is required (LLMCTL_STATE_DIR or --state-dir)")
	}
	if !m.o.Runtime.IsAvailable(ctx) {
		return nil, fmt.Errorf("%w: %s runtime reports unavailable (no rootless podman?)", ErrUnavailable, m.o.Runtime.Name())
	}
	if st, err := m.Load(); err != nil {
		return nil, err
	} else if st != nil {
		if m.running(ctx, st.Name) {
			return st, nil
		}
		if err := m.Down(ctx); err != nil { // stale state: clean before recreating
			return nil, fmt.Errorf("vantage: cleaning stale state: %w", err)
		}
	}
	if m.o.Network != NetSlirp && m.o.Network != NetBridge {
		return nil, fmt.Errorf("vantage: unsupported network mode %q (use %s or %s; pasta is not a distinct vantage)", m.o.Network, NetSlirp, NetBridge)
	}
	if err := os.MkdirAll(m.dir(), 0o700); err != nil {
		return nil, err
	}
	probeDir := filepath.Join(m.dir(), "probe")
	if err := os.MkdirAll(probeDir, 0o755); err != nil {
		return nil, err
	}
	if err := os.Chmod(probeDir, 0o755); err != nil {
		return nil, err
	}
	bin, err := m.stageProbe(ctx, probeDir)
	if err != nil {
		return nil, err
	}
	_ = bin
	hostIP := m.o.HostIP
	if hostIP == "" {
		if hostIP, err = HostIP(); err != nil {
			return nil, err
		}
	}
	name := NamePrefix + randHex(4)
	var id, image string
	var errs []string
	for _, img := range m.o.Images {
		res, err := m.o.Runtime.Run(ctx, img, []string{"hold", "--max", "30m"},
			runtime.WithRunName(name),
			runtime.WithRunRemove(true),
			runtime.WithRunUser("0:0"),
			runtime.WithRunEntrypoint("/vantage/vantage-probe"),
			runtime.WithRunNetwork(m.o.Network),
			runtime.WithRunVolumes(probeDir+":/vantage:ro"),
			runtime.WithRunExtraArgs("-d", "--pull=never", "--memory", m.o.Memory, "--memory-swap", m.o.Memory,
				"--pids-limit", "64", "--cap-drop", "all", "--read-only", "--label", LabelKey+"=1", "--label", LabelOwner+"="+m.ownerID()),
		)
		if err != nil {
			errs = append(errs, fmt.Sprintf("%s: %v", img, err))
			continue
		}
		if res.ExitCode != 0 {
			errs = append(errs, fmt.Sprintf("%s: exit %d: %s", img, res.ExitCode, firstLine(res.Stderr)))
			continue
		}
		id, image = strings.TrimSpace(res.Stdout), img
		break
	}
	if id == "" {
		return nil, fmt.Errorf("vantage: no usable local image (offline, --pull=never): %s", strings.Join(errs, "; "))
	}
	st := &State{Name: name, ID: id, Image: image, Network: m.o.Network, HostIP: hostIP, ProbeDir: probeDir, CreatedAt: m.o.Now().UTC()}
	if err := m.save(st); err != nil { // persist BEFORE inspecting so Down can always clean
		_ = m.removeContainer(ctx, name)
		return nil, err
	}
	info, err := m.waitInfo(ctx, st)
	if err != nil {
		_ = m.Down(ctx)
		return nil, err
	}
	st.IP, st.Gateway = firstOr(info.Addrs), info.DefaultGateway
	if st.IP == "" {
		_ = m.Down(ctx)
		return nil, errors.New("vantage: container reports no non-loopback IPv4 address")
	}
	if err := m.save(st); err != nil {
		_ = m.Down(ctx)
		return nil, err
	}
	return st, nil
}

func (m *Manager) waitInfo(ctx context.Context, st *State) (probecore.Info, error) {
	var last error
	for i := 0; i < 30; i++ {
		var in probecore.Info
		if err := m.execJSON(ctx, st, []string{"/vantage/vantage-probe", "info"}, &in); err == nil {
			return in, nil
		} else {
			last = err
		}
		select {
		case <-ctx.Done():
			return probecore.Info{}, ctx.Err()
		case <-time.After(200 * time.Millisecond):
		}
	}
	return probecore.Info{}, fmt.Errorf("vantage: container did not become ready: %w", last)
}

// Exec runs argv inside the container.
func (m *Manager) Exec(ctx context.Context, argv []string) (*runtime.ExecResult, error) {
	st, err := m.mustState(ctx)
	if err != nil {
		return nil, err
	}
	return m.o.Runtime.Exec(ctx, st.Name, argv)
}

func (m *Manager) mustState(ctx context.Context) (*State, error) {
	st, err := m.Load()
	if err != nil {
		return nil, err
	}
	if st == nil {
		return nil, errors.New("vantage: not up (run `llmctl-decide vantage up`)")
	}
	if !m.running(ctx, st.Name) {
		return nil, fmt.Errorf("vantage: container %s is not running (run `vantage down` then `vantage up`)", st.Name)
	}
	return st, nil
}

func (m *Manager) execJSON(ctx context.Context, st *State, argv []string, out any) error {
	r, err := m.o.Runtime.Exec(ctx, st.Name, argv)
	if err != nil {
		return err
	}
	if r.ExitCode != 0 {
		return fmt.Errorf("exit %d: %s", r.ExitCode, firstLine(r.Stderr))
	}
	if err := json.Unmarshal([]byte(r.Stdout), out); err != nil {
		return fmt.Errorf("probe output is not JSON: %w (%.200q)", err, r.Stdout)
	}
	return nil
}

// ProbeRequest is one call issued from the second vantage.
type ProbeRequest struct {
	URL        string
	CAFile     string
	Method     string
	Headers    []string // Name:Value
	Body       string
	Timeout    time.Duration
	ServerName string
}

// Probe runs one HTTP(S) call from inside the container.
func (m *Manager) Probe(ctx context.Context, p ProbeRequest) (probecore.HTTPResult, error) {
	st, err := m.mustState(ctx)
	if err != nil {
		return probecore.HTTPResult{}, err
	}
	argv := []string{"/vantage/vantage-probe", "http", "--url", p.URL}
	if p.CAFile != "" {
		b, err := os.ReadFile(p.CAFile)
		if err != nil {
			return probecore.HTTPResult{}, fmt.Errorf("vantage: reading --cacert: %w", err)
		}
		argv = append(argv, "--ca-pem-hex", fmt.Sprintf("%x", b))
	}
	if p.Method != "" {
		argv = append(argv, "--method", p.Method)
	}
	// Headers (an Authorization bearer, say) and the body never travel on argv - `ps` shows every
	// argv to other host users. They go through a 0600 request file in the bind-mounted probe dir,
	// which is removed as soon as the call returns (C-16).
	if len(p.Headers) > 0 || p.Body != "" {
		name, err := m.writeRequestFile(st, p)
		if err != nil {
			return probecore.HTTPResult{}, err
		}
		defer os.Remove(filepath.Join(st.ProbeDir, name))
		argv = append(argv, "--request-file", "/vantage/"+name)
	}
	if p.ServerName != "" {
		argv = append(argv, "--server-name", p.ServerName)
	}
	if p.Timeout > 0 {
		argv = append(argv, "--timeout", p.Timeout.String())
	}
	var res probecore.HTTPResult
	if err := m.execJSON(ctx, st, argv, &res); err != nil {
		return res, fmt.Errorf("vantage probe: %w", err)
	}
	return res, nil
}

// writeRequestFile stores the headers and body of p as 0600 JSON in the probe directory and returns
// its file name.
func (m *Manager) writeRequestFile(st *State, p ProbeRequest) (string, error) {
	hdr := map[string]string{}
	for _, h := range p.Headers {
		k, v, ok := strings.Cut(h, ":")
		if !ok {
			return "", fmt.Errorf("vantage: header %q: want Name:Value", h)
		}
		hdr[strings.TrimSpace(k)] = strings.TrimSpace(v)
	}
	b, _ := json.Marshal(probecore.RequestFile{Headers: hdr, Body: p.Body})
	name := "req-" + randHex(8) + ".json"
	f, err := os.OpenFile(filepath.Join(st.ProbeDir, name), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return "", fmt.Errorf("vantage: request file: %w", err)
	}
	if _, err := f.Write(b); err != nil {
		f.Close()
		_ = os.Remove(filepath.Join(st.ProbeDir, name))
		return "", err
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(filepath.Join(st.ProbeDir, name))
		return "", err
	}
	return name, nil
}

// ProbePorts reports which TCP ports of host are reachable from inside.
func (m *Manager) ProbePorts(ctx context.Context, host string, ports []int) (probecore.DialResult, error) {
	st, err := m.mustState(ctx)
	if err != nil {
		return probecore.DialResult{}, err
	}
	ps := make([]string, len(ports))
	for i, p := range ports {
		ps[i] = fmt.Sprint(p)
	}
	var res probecore.DialResult
	err = m.execJSON(ctx, st, []string{"/vantage/vantage-probe", "dial", "--host", host, "--ports", strings.Join(ps, ","), "--timeout", "2s"}, &res)
	return res, err
}

func (m *Manager) removeContainer(ctx context.Context, name string) error {
	if !strings.HasPrefix(name, NamePrefix) { // safety: only ever our own objects
		return fmt.Errorf("vantage: refusing to remove %q (not %s*)", name, NamePrefix)
	}
	_ = m.o.Runtime.Stop(ctx, name, runtime.WithStopTimeout(2*time.Second))
	err := m.o.Runtime.Remove(ctx, name, runtime.WithForceRemove(true))
	if err != nil && m.exists(ctx, name) { // --rm may already have removed it: that is success
		return err
	}
	return nil
}

func (m *Manager) exists(ctx context.Context, name string) bool {
	l, err := m.o.Runtime.List(ctx, runtime.ListFilter{All: true, Names: []string{name}})
	if err != nil {
		return true // cannot tell: report the removal error rather than hide it
	}
	for _, c := range l {
		if strings.TrimPrefix(c.Name, "/") == name {
			return true
		}
	}
	return false
}

// Down removes THIS state directory's container and state; idempotent and always attempts all steps.
// It sweeps untracked stragglers (a crash between run and save) only when they carry this manager's
// owner label, and it never removes a directory it cannot prove is its own: only the files it wrote
// (state.json, state.json.tmp, the staged probe, request files) are deleted and the directories are
// removed only when that leaves them empty (C-07, C-15).
func (m *Manager) Down(ctx context.Context) error { return m.down(ctx, false) }

// DownAll is Down plus an explicit sweep of EVERY vantage container on the host (any owner), for
// recovery after a lost state directory.
func (m *Manager) DownAll(ctx context.Context) error { return m.down(ctx, true) }

func (m *Manager) down(ctx context.Context, all bool) error {
	var errs []error
	st, err := m.Load()
	if err != nil {
		errs = append(errs, err)
	}
	if st != nil {
		if err := m.removeContainer(ctx, st.Name); err != nil {
			errs = append(errs, err)
		}
	}
	labels := map[string]string{LabelKey: "1", LabelOwner: m.ownerID()}
	if all {
		labels = map[string]string{LabelKey: "1"}
	}
	if l, err := m.o.Runtime.List(ctx, runtime.ListFilter{All: true, Labels: labels}); err == nil {
		for _, c := range l {
			n := strings.TrimPrefix(c.Name, "/")
			if strings.HasPrefix(n, NamePrefix) {
				if err := m.removeContainer(ctx, n); err != nil {
					errs = append(errs, err)
				}
			}
		}
	}
	if len(errs) == 0 {
		errs = append(errs, m.removeStateFiles()...)
	}
	return errors.Join(errs...)
}

// removeStateFiles deletes exactly the files this package creates under <state>/vantage and then the
// (now empty) directories; anything else found there is left alone.
func (m *Manager) removeStateFiles() []error {
	var errs []error
	rm := func(p string) {
		if err := os.Remove(p); err != nil && !errors.Is(err, os.ErrNotExist) {
			errs = append(errs, err)
		}
	}
	rm(m.statePath())
	rm(m.statePath() + ".tmp")
	probeDir := filepath.Join(m.dir(), "probe")
	rm(filepath.Join(probeDir, ProbeName))
	if ents, err := os.ReadDir(probeDir); err == nil {
		for _, e := range ents {
			if strings.HasPrefix(e.Name(), "req-") && strings.HasSuffix(e.Name(), ".json") {
				rm(filepath.Join(probeDir, e.Name()))
			}
		}
	}
	for _, d := range []string{probeDir, m.dir()} {
		if err := os.Remove(d); err != nil && !errors.Is(err, os.ErrNotExist) && !isNotEmpty(err) {
			errs = append(errs, err)
		}
	}
	return errs
}

func isNotEmpty(err error) bool {
	return errors.Is(err, syscall.ENOTEMPTY) || errors.Is(err, syscall.EEXIST)
}

// Status is the data of `vantage status`.
type Status struct {
	Up    bool   `json:"up"`
	State *State `json:"state,omitempty"`
}

// Status reports the live state.
func (m *Manager) Status(ctx context.Context) (Status, error) {
	st, err := m.Load()
	if err != nil || st == nil {
		return Status{}, err
	}
	return Status{Up: m.running(ctx, st.Name), State: st}, nil
}

// HostIP returns this host's primary non-loopback IPv4 (the address a
// container with its own network reaches the host on).
func HostIP() (string, error) {
	if c, err := net.Dial("udp4", "192.0.2.1:9"); err == nil { // no packet is sent
		defer c.Close()
		if a, ok := c.LocalAddr().(*net.UDPAddr); ok && !a.IP.IsLoopback() && !a.IP.IsUnspecified() {
			return a.IP.String(), nil
		}
	}
	as, err := net.InterfaceAddrs()
	if err != nil {
		return "", err
	}
	for _, a := range as {
		if ipn, ok := a.(*net.IPNet); ok && !ipn.IP.IsLoopback() && ipn.IP.To4() != nil {
			return ipn.IP.String(), nil
		}
	}
	return "", errors.New("vantage: host has no non-loopback IPv4 address")
}

func firstOr(l []string) string {
	if len(l) > 0 {
		return l[0]
	}
	return ""
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	return s
}
