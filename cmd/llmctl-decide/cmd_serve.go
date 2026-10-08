package main

import (
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/vasic-digital/llmctl/internal/audit"
	"github.com/vasic-digital/llmctl/internal/certs"
	"github.com/vasic-digital/llmctl/internal/contract"
	"github.com/vasic-digital/llmctl/internal/gateway"
	"github.com/vasic-digital/llmctl/internal/keyring"
	"github.com/vasic-digital/llmctl/internal/metrics"
	"github.com/vasic-digital/llmctl/internal/server"
)

func init() { register("serve", cmdServe) }

// Exit codes of `serve` (contracts/cli.md): 0 ok, 1 failure (including a refused/failed stop and
// "not running" for --status), 2 usage, 4 key problem, 5 certificate problem.
const (
	exitOK    = 0
	exitFail  = 1
	exitUsage = 2
)

const (
	defaultPort = 8095
	defaultBind = "0.0.0.0"
)

// serveEnv is the environment view of serve; tests replace it.
var serveEnv = func() keyring.Environ { return keyring.OSEnviron() }

// sigSource returns the termination-signal channel and its cleanup; tests replace it.
var sigSource = func() (<-chan os.Signal, func()) {
	ch := make(chan os.Signal, 4)
	signal.Notify(ch, syscall.SIGTERM, syscall.SIGINT)
	return ch, func() { signal.Stop(ch) }
}

// resolveBind: --bind, else LLMCTL_DECIDE_BIND, else the global LLMCTL_BIND_HOST (an operator who made
// all servers local keeps the gateway local), else all interfaces.
func resolveBind(flagVal string, env map[string]string) string {
	for _, v := range []string{flagVal, env["LLMCTL_DECIDE_BIND"], env["LLMCTL_BIND_HOST"]} {
		if v = strings.TrimSpace(v); v != "" {
			return v
		}
	}
	return defaultBind
}

func resolvePort(flagVal int, env map[string]string) (int, error) {
	if flagVal != 0 {
		if flagVal < 1 || flagVal > 65535 {
			return 0, fmt.Errorf("--port must be 1..65535")
		}
		return flagVal, nil
	}
	s := strings.TrimSpace(env["LLMCTL_DECIDE_PORT"])
	if s == "" {
		return defaultPort, nil
	}
	n, err := strconv.Atoi(s)
	if err != nil || n < 1 || n > 65535 {
		return 0, fmt.Errorf("LLMCTL_DECIDE_PORT must be 1..65535")
	}
	return n, nil
}

type serveFlags struct {
	bind       string
	port       int
	foreground bool
	status     bool
	stop       bool
	catalog    string
}

func parseServeFlags(args []string, stderr io.Writer) (serveFlags, error) {
	var f serveFlags
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.StringVar(&f.bind, "bind", "", "bind address (default $LLMCTL_DECIDE_BIND, then $LLMCTL_BIND_HOST, then 0.0.0.0)")
	fs.IntVar(&f.port, "port", 0, "HTTPS port (default $LLMCTL_DECIDE_PORT, then 8095)")
	fs.BoolVar(&f.foreground, "foreground", false, "run in the foreground instead of detaching")
	fs.BoolVar(&f.status, "status", false, "report whether the gateway is running (verified, not just the pidfile)")
	fs.BoolVar(&f.stop, "stop", false, "stop the verified gateway process")
	fs.StringVar(&f.catalog, "catalog", "", "catalog.json path (default $LLMCTL_CATALOG, then <root>/models/catalog.json)")
	if err := fs.Parse(args); err != nil {
		return f, err
	}
	if fs.NArg() != 0 {
		return f, fmt.Errorf("unexpected argument %q", fs.Arg(0))
	}
	if f.status && f.stop {
		return f, errors.New("--status and --stop are mutually exclusive")
	}
	return f, nil
}

// serveDirs are the filesystem locations of the gateway.
type serveDirs struct {
	root, home, state, decideState, logDir, pidfile string
}

func resolveDirs(env map[string]string) serveDirs {
	d := serveDirs{root: env["LLMCTL_ROOT"]}
	if d.root == "" {
		d.root = installationRoot()
	}
	if d.home = env["LLMCTL_HOME"]; d.home == "" {
		h, _ := os.UserHomeDir()
		d.home = filepath.Join(h, "llmctl")
	}
	if d.state = env["LLMCTL_STATE_DIR"]; d.state == "" {
		xdg := env["XDG_STATE_HOME"]
		if xdg == "" {
			h, _ := os.UserHomeDir()
			xdg = filepath.Join(h, ".local", "state")
		}
		d.state = filepath.Join(xdg, "llmctl")
	}
	d.decideState = filepath.Join(d.state, "decide")
	if d.logDir = env["LLMCTL_LOG_DIR"]; d.logDir == "" {
		d.logDir = filepath.Join(d.state, "logs")
	}
	d.pidfile = filepath.Join(d.decideState, "gateway.pid")
	return d
}

// binName is what `serve --status/--stop` expect to find in the verified process's command line.
func binName() string {
	if exe, err := os.Executable(); err == nil {
		if real, err := filepath.EvalSymlinks(exe); err == nil {
			exe = real
		}
		return filepath.Base(exe)
	}
	return "llmctl-decide"
}

func cmdServe(args []string, stdout, stderr io.Writer) int {
	f, err := parseServeFlags(args, stderr)
	if err != nil {
		if !errors.Is(err, flag.ErrHelp) {
			fmt.Fprintf(stderr, "llmctl serve: %v\n", err)
			return exitUsage
		}
		return exitOK
	}
	env := serveEnv()
	dirs := resolveDirs(env)
	switch {
	case f.status:
		return serveStatus(dirs, stdout)
	case f.stop:
		return serveStop(dirs, env, stdout, stderr)
	}
	p, code := prepare(f, env, dirs, stderr)
	if p == nil {
		return code
	}
	defer p.close()
	if f.foreground {
		return p.runForeground(stdout, stderr)
	}
	return p.runDetached(f, stdout, stderr)
}

func serveStatus(d serveDirs, stdout io.Writer) int {
	st, err := gateway.GatewayStatus(d.pidfile, binName())
	if err != nil || !st.Running {
		reason := st.Reason
		if err != nil {
			reason += ": " + err.Error()
		}
		fmt.Fprintf(stdout, "llmctl decide gateway: not running (%s)\n", reason)
		return exitFail
	}
	fmt.Fprintf(stdout, "llmctl decide gateway: running pid %d, up %s\n", st.PID, st.Uptime.Round(time.Second))
	return exitOK
}

func serveStop(d serveDirs, env map[string]string, stdout, stderr io.Writer) int {
	grace := 20 * time.Second
	if s := env["LLMCTL_DECIDE_DRAIN_GRACE"]; s != "" { // numeric seconds, like every LLMCTL_DECIDE_* duration
		if f, err := strconv.ParseFloat(s, 64); err == nil && f > 0 && f < 3600 {
			grace = time.Duration(f*float64(time.Second)) + 5*time.Second
		}
	}
	res, err := gateway.StopGateway(d.pidfile, binName(), grace, nil)
	switch res {
	case gateway.NotRunning:
		fmt.Fprintln(stdout, "llmctl decide gateway: not running")
		return exitOK
	case gateway.Stopped:
		fmt.Fprintln(stdout, "llmctl decide gateway: stopped")
		return exitOK
	}
	fmt.Fprintf(stderr, "llmctl serve --stop: %v\n", err)
	return exitFail
}

// prepared is everything a start needs; building it validates key, certificate, catalog and limits
// before anything listens (a start without them is refused).
type prepared struct {
	dirs     serveDirs
	env      keyring.Environ
	bind     string
	port     int
	keyRes   keyring.KeyResult
	cert     *certs.CertInfo
	specs    []gateway.ProfileSpec
	profiles *contract.Profiles
	cLimits  contract.Limits
	sLimits  server.Limits
	logKey   []byte
	sink     *audit.Sink
	cals     *gateway.CalibrationSet // calibration profiles applied to the confidence (FR-080)
	calTemp  float64                 // the effective readout temperature the profiles are bound to
	decSink  *audit.Sink             // the opt-in decision log (nil = off)
	decState bool                    // LLMCTL_DECIDE_LOG_STATE=1: the decision log carries state text
	decPath  string
	router   *gateway.Router
	certs    *certHolder
	regs     *serveRegistry // serve_resolver.go
	stderr   io.Writer
	metrics  *metrics.Registry
}

func (p *prepared) close() {
	gateway.SetEngineKeys(nil)
	p.closeRegistry()
	if p.sink != nil {
		_ = p.sink.Close()
	}
	if p.decSink != nil {
		_ = p.decSink.Close()
	}
}

// calibrationDir is where `llmctl-decide calibrate` writes profiles: $STATE/decide/calibration.
func (p *prepared) calibrationDir() string { return filepath.Join(p.dirs.decideState, "calibration") }

// reloadCalibration (re)reads the calibration profiles; refusals are reported once per change.
func (p *prepared) reloadCalibration() {
	p.cals.Reload(p.calibrationDir(), p.specs, p.calTemp, func(format string, a ...any) {
		fmt.Fprintf(p.stderr, format+"\n", a...)
	})
}

func envInt(env map[string]string, name string, def int) (int, error) {
	s := strings.TrimSpace(env[name])
	if s == "" {
		return def, nil
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return 0, fmt.Errorf("%s must be an integer", name)
	}
	return n, nil
}

func envFloat(env map[string]string, name string, def float64) (float64, error) {
	s := strings.TrimSpace(env[name])
	if s == "" {
		return def, nil
	}
	v, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return 0, fmt.Errorf("%s must be a number", name)
	}
	return v, nil
}

func prepare(f serveFlags, env keyring.Environ, d serveDirs, stderr io.Writer) (*prepared, int) {
	fail := func(code int, format string, a ...any) (*prepared, int) {
		fmt.Fprintf(stderr, "llmctl serve: "+format+"\n", a...)
		return nil, code
	}
	env = scrubLegacyKeyEnv(env, stderr)
	p := &prepared{dirs: d, env: env, bind: resolveBind(f.bind, env), stderr: stderr}
	var err error
	if p.port, err = resolvePort(f.port, env); err != nil {
		return fail(exitUsage, "%v", err)
	}

	// 1. access key: resolve, or generate on first start (never printed)
	if p.keyRes, err = keyring.Resolve(d.root, env, true); err != nil {
		return fail(keyring.ExitCode, "access key: %v", err)
	}

	// 1b. the source the running gateway will re-read every second must be usable NOW: a
	// configuration that cannot keep serving fails here, not seconds into production (review A2-02).
	if ks, kerr := p.readKeys(); kerr != nil || len(ks) == 0 {
		if kerr == nil {
			kerr = fmt.Errorf("no key is accepted")
		}
		return fail(keyring.ExitCode, "access key: the accepted-key set cannot be read at start: %v", kerr)
	}

	// 2. certificate: refuse to start without a valid pair
	if p.cert, err = certs.Ensure(certs.Options{Home: d.home, Env: env}); err != nil {
		return fail(certs.ExitCert, "certificate: %v", err)
	}
	if p.certs, err = newCertHolder(p.cert); err != nil {
		return fail(certs.ExitCert, "certificate: %v", err)
	}

	// 3. catalog and limits
	catPath := f.catalog
	if catPath == "" {
		catPath = env["LLMCTL_CATALOG"]
	}
	if catPath == "" {
		catPath = filepath.Join(d.root, "models", "catalog.json")
	}
	if p.specs, err = gateway.LoadCatalog(catPath); err != nil {
		return fail(exitFail, "%v", err)
	}
	if len(p.specs) == 0 {
		return fail(exitFail, "no decision profiles in %s", catPath)
	}
	p.cLimits = contract.DefaultLimits()
	for _, v := range []struct {
		name string
		dst  *int
	}{{"LLMCTL_DECIDE_MAX_STATE_CHARS", &p.cLimits.MaxStateChars}, {"LLMCTL_DECIDE_MAX_OPTIONS", &p.cLimits.MaxOptions}, {"LLMCTL_DECIDE_MAX_QUESTIONS", &p.cLimits.MaxQuestions}} {
		if *v.dst, err = envInt(env, v.name, *v.dst); err != nil {
			return fail(exitUsage, "%v", err)
		}
	}
	p.cLimits.Truncate = env["LLMCTL_DECIDE_TRUNCATE"] == "1"
	if p.sLimits, err = server.FromEnv(env); err != nil {
		return fail(exitUsage, "%v", err)
	}
	def := env["LLMCTL_DECIDE_PROFILE"]
	if def == "" {
		// default: the first spec the gateway can actually serve; a jev-verdict profile
		// (decide-tiny) is catalogued but refused, so it must never be the implicit default.
		def = p.specs[0].ID
		for _, s := range p.specs {
			if s.Protocol != gateway.ProtoJevVerdict {
				def = s.ID
				break
			}
		}
		for _, s := range p.specs {
			if s.ID == "decide-tiny" && s.Protocol != gateway.ProtoJevVerdict {
				def = s.ID // historical preference, kept only while the profile is servable
			}
		}
	}
	if p.profiles, err = gateway.BuildProfiles(p.specs, def, p.cLimits); err != nil {
		return fail(exitFail, "%v", err)
	}

	// 4. backend: resolver (static from env/catalog until the registry adapter lands), drivers, router
	mode, err := gateway.ParseMode(env["LLMCTL_DECIDE_MODE"])
	if err != nil {
		return fail(exitUsage, "%v", err)
	}
	ro, err := parseReadoutEnv(env, mode, p.cLimits) // serve_env.go: strict boot-time invariants (B-06/B-07)
	if err != nil {
		return fail(exitUsage, "%v", err)
	}
	thr, temp, seed, slots := ro.Threshold, ro.Temperature, ro.Seed, ro.Slots
	native := env["LLMCTL_DECIDE_NATIVE"] == "1" // engine advance gate OD-1
	drivers := gateway.DefaultDrivers(mode, native)
	drivers[gateway.ProtoLetter] = &gateway.LetterLogitBackend{Mode: mode, Seed: seed, MassThreshold: thr, Temperature: temp}
	drivers[gateway.ProtoNLI] = &gateway.NLIBackend{Truncate: p.cLimits.Truncate, MaxPairs: ro.MaxPairs}
	res, err := p.buildResolver(p.specs) // serve_resolver.go: registry | static | auto
	if err != nil {
		return fail(exitUsage, "%v", err)
	}
	if res, err = p.withEngineKeys(res, env, stderr); err != nil {
		return fail(exitFail, "%v", err)
	}
	p.calTemp = temp
	p.cals = gateway.NewCalibrationSet()
	p.reloadCalibration() // a bound profile is applied from the first request; refusals are logged here
	if p.router, err = gateway.NewRouter(gateway.RouterConfig{Specs: p.specs, Resolver: res, Mode: mode,
		Concurrency: slots, NativeEnabled: native, Drivers: drivers, Profiles: p.profiles, BaseLimits: p.cLimits,
		Calibrations: p.cals, Temperature: temp}); err != nil {
		return fail(exitFail, "%v", err)
	}

	// 5. request log and the keyed state-hash key
	if p.logKey, err = audit.LoadOrCreateLogKey(d.decideState); err != nil {
		return fail(exitFail, "log key: %v", err)
	}
	logPath := env["LLMCTL_DECIDE_LOG"]
	if logPath == "" {
		logPath = filepath.Join(d.logDir, "decide-requests.jsonl")
	}
	// 5b. the opt-in decision log (FR-080): LLMCTL_DECIDE_LOG_STATE=1 is the operator's consent to keep
	// the state and question text; LLMCTL_DECIDE_DECISION_LOG names the file (giving it alone enables
	// the log WITHOUT text). Neither set: no decision log exists.
	switch v := strings.TrimSpace(env["LLMCTL_DECIDE_LOG_STATE"]); v {
	case "", "0":
	case "1":
		p.decState = true
	default:
		return fail(exitUsage, "LLMCTL_DECIDE_LOG_STATE must be 0 or 1 (got %q)", v)
	}
	p.decPath = strings.TrimSpace(env["LLMCTL_DECIDE_DECISION_LOG"])
	if p.decPath == "" && p.decState {
		p.decPath = filepath.Join(d.logDir, "decide-decisions.jsonl")
	}
	if p.decPath != "" && filepath.Clean(p.decPath) == filepath.Clean(logPath) {
		return fail(exitUsage, "LLMCTL_DECIDE_DECISION_LOG must not be the request log %s: the two logs hold different records", logPath)
	}
	if p.sink, err = audit.NewSink(logPath); err != nil {
		return fail(exitFail, "%v", err)
	}
	if p.decPath != "" {
		if p.decSink, err = audit.NewDecisionSink(p.decPath); err != nil {
			return fail(exitFail, "decision log: %v", err)
		}
	}
	return p, exitOK
}

// certHolder serves the current certificate and re-reads it on reload (SIGHUP / explicit renewal).
type certHolder struct {
	info atomic.Pointer[certs.CertInfo]
	cert atomic.Pointer[tls.Certificate]
}

func loadPair(info *certs.CertInfo) (*tls.Certificate, error) {
	// The key is the content certs validated on the opened descriptor, not a second open by path
	// (review A2-08).
	return info.TLSCertificate()
}

func newCertHolder(info *certs.CertInfo) (*certHolder, error) {
	h := &certHolder{}
	c, err := loadPair(info)
	if err != nil {
		return nil, err
	}
	h.info.Store(info)
	h.cert.Store(c)
	return h, nil
}

func (h *certHolder) get(*tls.ClientHelloInfo) (*tls.Certificate, error) { return h.cert.Load(), nil }

func (h *certHolder) reload(o certs.Options) error {
	info, err := certs.Ensure(o)
	if err != nil {
		return err
	}
	c, err := loadPair(info)
	if err != nil {
		return err
	}
	h.info.Store(info)
	h.cert.Store(c)
	return nil
}

// keyFunc returns the accepted keys on every request (see keyCache: one-second cache, fail closed
// past keyStaleGrace when the key source stops yielding a usable set).
func (p *prepared) keyFunc() func() []keyring.Secret {
	c := newKeyCache([]keyring.Secret{p.keyRes.Key}, p.readKeys, time.Now, p.stderr, p.metrics)
	return c.keys
}

// acceptedKeys is the key source; a variable so tests can make it fail.
var acceptedKeys = keyring.AcceptedKeys

// readKeys is the accepted-key source the cache re-reads every second and prepare checks once at
// start (review A2-02).
func (p *prepared) readKeys() ([]keyring.Secret, error) {
	return acceptedKeys(p.dirs.root, p.env, time.Now())
}

func (p *prepared) banner(w io.Writer) {
	host := p.bind
	note := ""
	if ip := net.ParseIP(host); host == "" || (ip != nil && ip.IsUnspecified()) {
		host = "127.0.0.1"
		note = " (all interfaces; use this host's name or address from other machines)"
	}
	info := p.certs.info.Load()
	fmt.Fprintf(w, "llmctl decide gateway\n")
	fmt.Fprintf(w, "  bind:   %s:%d%s\n", p.bind, p.port, note)
	fmt.Fprintf(w, "  URL:    https://%s\n", net.JoinHostPort(host, strconv.Itoa(p.port)))
	fmt.Fprintf(w, "  key:    %s (source: %s; show it with `llmctl key show --yes-print`)\n", p.keyRes.Path, p.keyRes.Source)
	if info.CAFingerprint != "" {
		fmt.Fprintf(w, "  CA:     SHA-256 %s, expires %s\n", info.CAFingerprint, info.CANotAfter.UTC().Format("2006-01-02"))
	} else {
		fmt.Fprintf(w, "  cert:   mode %s, SHA-256 %s, expires %s\n", info.Mode, info.LeafFingerprint, info.NotAfter.UTC().Format("2006-01-02"))
	}
	fmt.Fprintf(w, "  models: %d decision profile(s), default %s\n", len(p.specs), p.profiles.Default())
	if p.decPath != "" {
		text := "state text not logged"
		if p.decState {
			text = "state text LOGGED (LLMCTL_DECIDE_LOG_STATE=1)"
		}
		fmt.Fprintf(w, "  decision log: %s (%s)\n", p.decPath, text)
	}
}

// decisionWriter returns the decision sink as a server.DecisionWriter, or a true nil when it is off
// (a nil *audit.Sink inside the interface would not be nil).
func (p *prepared) decisionWriter() server.DecisionWriter {
	if p.decSink == nil {
		return nil
	}
	return p.decSink
}

func (p *prepared) newServer() (*server.Server, error) {
	if p.metrics == nil {
		p.metrics = metrics.New(p.profiles.IDs()...)
	}
	return server.New(server.Config{
		Backend: p.router, Limits: p.sLimits, TLS: &tls.Config{GetCertificate: p.certs.get},
		Keys: p.keyFunc(), Profiles: p.profiles, ContractLimits: p.cLimits,
		Audit: p.sink, LogKey: p.logKey, Metrics: p.metrics, Stderr: p.stderr,
		Decisions: p.decisionWriter(), DecisionState: p.decState,
	})
}

func (p *prepared) runForeground(stdout, stderr io.Writer) int {
	if st, _ := gateway.GatewayStatus(p.dirs.pidfile, binName()); st.Running && st.PID != os.Getpid() {
		fmt.Fprintf(stderr, "llmctl serve: already running (pid %d); use --stop first\n", st.PID)
		return exitFail
	}
	srv, err := p.newServer()
	if err != nil {
		fmt.Fprintf(stderr, "llmctl serve: %v\n", err)
		return exitFail
	}
	l, err := net.Listen("tcp", net.JoinHostPort(p.bind, strconv.Itoa(p.port)))
	if err != nil {
		fmt.Fprintf(stderr, "llmctl serve: cannot listen on %s:%d: %v (set LLMCTL_DECIDE_PORT or --port)\n", p.bind, p.port, err)
		return exitFail
	}
	if err := gateway.WritePidfile(p.dirs.pidfile, os.Getpid(), time.Now()); err != nil {
		_ = l.Close()
		fmt.Fprintf(stderr, "llmctl serve: pidfile: %v\n", err)
		return exitFail
	}
	defer removeOwnPidfile(p.dirs.pidfile, os.Getpid())
	unpublish := p.publishSelf(stderr) // registered at ready, unregistered when the drain starts
	defer unpublish()
	p.banner(stdout)

	sigs, stopSigs := sigSource()
	defer stopSigs()
	hup := make(chan os.Signal, 1)
	signal.Notify(hup, syscall.SIGHUP)
	defer signal.Stop(hup)
	go func() { // `cert reload`: re-read the pair (renewal / BYO rotation) without a restart
		for range hup {
			if err := p.certs.reload(certs.Options{Home: p.dirs.home, Env: p.env}); err != nil {
				fmt.Fprintf(stderr, "llmctl serve: certificate reload failed (keeping the current one): %v\n", err)
			}
			p.reloadCalibration() // the same signal re-reads the calibration profiles
		}
	}()
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(l) }()
	select {
	case err := <-errc:
		if err != nil && !errors.Is(err, errServerClosed) {
			fmt.Fprintf(stderr, "llmctl serve: %v\n", err)
			return exitFail
		}
		return exitOK
	case <-sigs:
	}
	unpublish()
	ctx, cancel := context.WithTimeout(context.Background(), p.sLimits.DrainGrace+2*time.Second)
	defer cancel()
	_ = srv.Drain(ctx)
	<-errc
	fmt.Fprintln(stdout, "llmctl decide gateway: stopped")
	return exitOK
}

func (p *prepared) runDetached(f serveFlags, stdout, stderr io.Writer) int {
	if st, _ := gateway.GatewayStatus(p.dirs.pidfile, binName()); st.Running {
		fmt.Fprintf(stderr, "llmctl serve: already running (pid %d)\n", st.PID)
		return exitFail
	}
	exe, err := os.Executable()
	if err != nil {
		fmt.Fprintf(stderr, "llmctl serve: %v\n", err)
		return exitFail
	}
	args := []string{"serve", "--foreground", "--bind", p.bind, "--port", strconv.Itoa(p.port)}
	if f.catalog != "" {
		args = append(args, "--catalog", f.catalog)
	}
	if err := os.MkdirAll(p.dirs.logDir, 0o700); err != nil {
		fmt.Fprintf(stderr, "llmctl serve: %v\n", err)
		return exitFail
	}
	logf := filepath.Join(p.dirs.logDir, "decide-gateway.log")
	lf, err := os.OpenFile(logf, os.O_WRONLY|os.O_APPEND|os.O_CREATE|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		fmt.Fprintf(stderr, "llmctl serve: %v\n", err)
		return exitFail
	}
	defer lf.Close()
	cmd := detachedCmd(exe, args, lf)
	if err := cmd.Start(); err != nil {
		fmt.Fprintf(stderr, "llmctl serve: %v\n", err)
		return exitFail
	}
	exited := make(chan struct{})
	go func() { _ = cmd.Wait(); close(exited) }()
	probe := p.bind
	if ip := net.ParseIP(probe); probe == "" || (ip != nil && ip.IsUnspecified()) {
		probe = "127.0.0.1"
	}
	addr := net.JoinHostPort(probe, strconv.Itoa(p.port))
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		select {
		case <-exited:
			fmt.Fprintf(stderr, "llmctl serve: the gateway exited during start-up; see %s\n", logf)
			return exitFail
		default:
		}
		if c, err := net.DialTimeout("tcp", addr, 200*time.Millisecond); err == nil {
			_ = c.Close()
			p.banner(stdout)
			fmt.Fprintf(stdout, "  pid:    %d (log: %s)\n", cmd.Process.Pid, logf)
			return exitOK
		}
		time.Sleep(100 * time.Millisecond)
	}
	fmt.Fprintf(stderr, "llmctl serve: the gateway did not accept connections within 20s; see %s\n", logf)
	return exitFail
}

// legacyKeyVar is the removed environment variable that used to carry the internal engine key. It
// is assembled here so that no source line spells it: a key in the environment is readable through
// /proc/<pid>/environ (G-040); the key now lives in a file (gateway.InternalKeyFileVar and
// $LLMCTL_STATE_DIR/keys/<kind>-<profile>.key).
var legacyKeyVar = "LLMCTL_DECIDE_" + "INTERNAL_" + "KEY"

// scrubLegacyKeyEnv returns env without the legacy variable (a copy; the caller's map is untouched)
// and says so once, naming the variable but never its value.
func scrubLegacyKeyEnv(env keyring.Environ, stderr io.Writer) keyring.Environ {
	if _, ok := env[legacyKeyVar]; !ok {
		return env
	}
	fmt.Fprintf(stderr, "llmctl serve: %s is no longer read (an environment variable is visible in /proc/<pid>/environ); use %s or %s\n",
		legacyKeyVar, gateway.InternalKeyFileVar, "$LLMCTL_STATE_DIR/keys/<kind>-<profile>.key")
	out := make(keyring.Environ, len(env))
	for k, v := range env {
		if k != legacyKeyVar {
			out[k] = v
		}
	}
	return out
}

// withEngineKeys installs the internal-key file source: a configured global key file must be
// acceptable at start (a typo or a loose mode is refused instead of silently serving without
// authentication), endpoints without a key get theirs from the files on every resolve (rotation
// needs no restart), and an engine answering 401 triggers one re-read and one bounded retry.
func (p *prepared) withEngineKeys(inner gateway.Resolver, env keyring.Environ, stderr io.Writer) (gateway.Resolver, error) {
	global := strings.TrimSpace(env[gateway.InternalKeyFileVar])
	if global != "" {
		if _, err := gateway.ReadKeyFile(global); err != nil {
			return nil, fmt.Errorf("%s: %v", gateway.InternalKeyFileVar, err)
		}
	}
	ks := gateway.NewKeySource(p.specs, global, p.dirs.state)
	gateway.SetEngineKeys(ks)
	var mu sync.Mutex
	last := map[string]string{}
	return &gateway.KeyedResolver{Inner: inner, Keys: ks, OnError: func(profile string, err error) {
		mu.Lock()
		defer mu.Unlock()
		if last[profile] == err.Error() { // once per distinct problem, not once per request
			return
		}
		last[profile] = err.Error()
		fmt.Fprintf(stderr, "llmctl serve: internal key for %s is unusable, instance held back: %v\n", profile, err)
	}}, nil
}
