package registry

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"
)

// Exit codes of the port / registry / discover commands (contracts/cli.md).
const (
	ExitOK      = 0
	ExitFailure = 1 // port taken / range exhausted / registry I/O failure / sets differ
	ExitUsage   = 2
)

const portUsage = `usage: llmctl-decide port <command> [flags]

commands:
  allocate NAME [--profile P] [--fixed N] [--strategy fixed|dynamic] [--json]
                 print a port for NAME (documented port N under the fixed strategy,
                 a bind-tested free port of LLMCTL_PORT_RANGE under dynamic);
                 an explicit numeric LLMCTL_PORT_<PROFILE> always wins, =auto selects dynamic
  release NAME   free NAME's port (idempotent)
  list [--json]  show current holds

common flags: --state-dir DIR (default $LLMCTL_STATE_DIR)
exit codes: 0 ok, 1 port taken / none free, 2 usage`

const registryUsage = `usage: llmctl-decide registry <command> [flags]

commands:
  register NAME --port N --pid P --token T [--host H] [--protocol http|https|tcp]
           [--health-path /p] [--kind K] [--profile P] [--instance I] [--label k=v]...
           [--loopback-only] [--json]
  unregister NAME
  list [--json]
  reconcile [--grace 30s] [--port-grace D] [--prune-unknown-after D] [--home DIR] [--strict] [--json]
  ack-corrupt                            acknowledge (clear) a "registry was corrupt" note
  diff --live NAME=PID[,NAME=PID...] [--prefix P] [--include NAME[,NAME]] [--no-tenant-rows]
                                         registry rows vs the live set (exit 1 if they differ); the
                                         scope flags restrict BOTH sides to one backend's names: --prefix
                                         "<tenant>--" keeps a tenant's rows (+ the --include names, e.g.
                                         the shared decide-gateway), --no-tenant-rows drops every
                                         "<tenant>--<profile>" row (a non-tenant backend)

reconcile verifies https entries against the CA named by the entry's ca_file label (when that file
is owned by you and not world-writable), else LLMCTL_CACERT, else $LLMCTL_HOME/cert/ca/ca.crt
(--home overrides LLMCTL_HOME). With no CA found an https entry is reported "unknown", kept (not
routable) and never removed unless --prune-unknown-after D is given (default off: forget an
https row that has stayed unknown for D); --strict then exits 1.
--port-grace D: how long an allocated but unbound port hold is kept (default 600s, at least
LLMCTL_REGISTER_WAIT when that is set - an engine may still be loading its model).
A registry found corrupt is moved aside once; the note stays and reconcile / list / diff report it
on every call (diff and reconcile --strict exit 1) until "registry ack-corrupt".

--token is the program name the pid must be running (matched against its argv, never a substring).
common flags: --state-dir DIR (default $LLMCTL_STATE_DIR)
exit codes: 0 ok, 1 failure / sets differ, 2 usage`

const discoverUsage = `usage: llmctl-decide discover [--json] [--kind K] [--label k=v]... [--healthy-only] [--state-dir DIR]

lists the published services: name, URL, health, pid, loopback-only flag, key-file state
(- none named, ok present, MISSING named but absent) and labels (never keys)`

type stringList []string

func (s *stringList) String() string     { return strings.Join(*s, ",") }
func (s *stringList) Set(v string) error { *s = append(*s, v); return nil }

// parseInterspersed lets positional arguments appear before or between flags.
func parseInterspersed(fs *flag.FlagSet, args []string) ([]string, error) {
	var pos []string
	for {
		if err := fs.Parse(args); err != nil {
			return nil, err
		}
		args = fs.Args()
		if len(args) == 0 {
			return pos, nil
		}
		pos = append(pos, args[0])
		args = args[1:]
	}
}

func newFS(name string) *flag.FlagSet {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	return fs
}

func configFor(get func(string) string, stateDir string) (Config, error) {
	g := get
	if stateDir != "" {
		g = func(k string) string {
			if k == "LLMCTL_STATE_DIR" {
				return stateDir
			}
			return get(k)
		}
	}
	return ConfigFromEnv(g)
}

func writeJSON(w io.Writer, v any) {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(v)
}

func usageFail(errw io.Writer, usage, msg string) int {
	if msg != "" {
		fmt.Fprintln(errw, "error: "+msg)
	}
	fmt.Fprintln(errw, usage)
	return ExitUsage
}

// failCode maps an error to an exit code: usage errors -> 2, others -> 1.
func failCode(errw io.Writer, err error) int {
	fmt.Fprintln(errw, "error: "+err.Error())
	var ue *UsageError
	if errors.As(err, &ue) {
		return ExitUsage
	}
	return ExitFailure
}

// ---- port --------------------------------------------------------------------

// RunPort implements `llmctl-decide port ...`.
func RunPort(args []string, get func(string) string, out, errw io.Writer) int {
	if len(args) == 0 {
		return usageFail(errw, portUsage, "a command is required")
	}
	cmd, rest := args[0], args[1:]
	fs := newFS("port " + cmd)
	var stateDir, profile, strategy string
	var fixed int
	var asJSON bool
	fs.StringVar(&stateDir, "state-dir", "", "")
	switch cmd {
	case "allocate":
		fs.StringVar(&profile, "profile", "", "")
		fs.IntVar(&fixed, "fixed", 0, "")
		fs.StringVar(&strategy, "strategy", "", "")
		fs.BoolVar(&asJSON, "json", false, "")
	case "release":
	case "list":
		fs.BoolVar(&asJSON, "json", false, "")
	default:
		return usageFail(errw, portUsage, fmt.Sprintf("unknown command %q", cmd))
	}
	pos, err := parseInterspersed(fs, rest)
	if err != nil {
		return usageFail(errw, portUsage, err.Error())
	}
	cfg, err := configFor(get, stateDir)
	if err != nil {
		return usageFail(errw, portUsage, err.Error())
	}
	p := NewPorts(cfg, get)
	switch cmd {
	case "allocate":
		if len(pos) != 1 {
			return usageFail(errw, portUsage, "allocate takes exactly one NAME")
		}
		if fixed < 0 || fixed > 65535 {
			return usageFail(errw, portUsage, "--fixed must be a port number")
		}
		req := PortRequest{Name: pos[0], Profile: profile, Documented: fixed}
		switch strategy {
		case "":
		case "fixed", "dynamic":
			req.Strategy = Strategy(strategy)
		default:
			return usageFail(errw, portUsage, fmt.Sprintf("--strategy %q: want fixed or dynamic", strategy))
		}
		res, err := p.Allocate(req)
		if err != nil {
			return failCode(errw, err)
		}
		if asJSON {
			writeJSON(out, res)
		} else {
			fmt.Fprintln(out, res.Port)
		}
	case "release":
		if len(pos) != 1 {
			return usageFail(errw, portUsage, "release takes exactly one NAME")
		}
		had, err := p.Release(pos[0])
		if err != nil {
			return failCode(errw, err)
		}
		if had {
			fmt.Fprintf(out, "released %s\n", pos[0])
		} else {
			fmt.Fprintf(out, "%s held no port\n", pos[0])
		}
	case "list":
		if len(pos) != 0 {
			return usageFail(errw, portUsage, "list takes no arguments")
		}
		held, err := p.Held()
		if err != nil {
			return failCode(errw, err)
		}
		if asJSON {
			writeJSON(out, map[string]any{"held": held})
			break
		}
		names := make([]string, 0, len(held))
		for n := range held {
			names = append(names, n)
		}
		sort.Strings(names)
		for _, n := range names {
			fmt.Fprintf(out, "%s\t%d\n", n, held[n])
		}
	}
	return ExitOK
}

// ---- registry ----------------------------------------------------------------

type entryView struct {
	Entry
	URL string `json:"url"`
	// KeyFileNamed / KeyFilePresent say whether the entry names an internal-key file and whether it
	// exists; the key itself is never shown.
	KeyFileNamed   bool `json:"key_file_named"`
	KeyFilePresent bool `json:"key_file_present"`
}

func views(es []Entry) []entryView {
	v := make([]entryView, len(es))
	for i, e := range es {
		n, p := e.KeyFileState()
		v[i] = entryView{e, e.URL(), n, p}
	}
	return v
}

func yesNo(b bool) string {
	if b {
		return "yes"
	}
	return "no"
}

// keyWord is the KEY column: "-" no key file named, "ok" named and present, "MISSING" named but absent.
func keyWord(e Entry) string {
	named, present := e.KeyFileState()
	switch {
	case !named:
		return "-"
	case present:
		return "ok"
	}
	return "MISSING"
}

func labelString(l map[string]string) string {
	keys := make([]string, 0, len(l))
	for k := range l {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, len(keys))
	for i, k := range keys {
		parts[i] = k + "=" + l[k]
	}
	return strings.Join(parts, ",")
}

func healthWord(e Entry) string {
	if e.Healthy {
		return "healthy"
	}
	return "unhealthy"
}

func printTable(out io.Writer, es []Entry) {
	tw := tabwriter.NewWriter(out, 0, 4, 2, ' ', 0)
	fmt.Fprintln(tw, "NAME\tURL\tHEALTH\tPID\tLOOPBACK\tKEY\tLABELS")
	for _, e := range es {
		fmt.Fprintf(tw, "%s\t%s\t%s\t%d\t%s\t%s\t%s\n", e.Name, e.URL(), healthWord(e), e.PID, yesNo(e.LoopbackOnly), keyWord(e), labelString(e.Labels))
	}
	_ = tw.Flush()
}

func parseLabels(pairs []string) (map[string]string, error) {
	m := map[string]string{}
	for _, p := range pairs {
		k, v, ok := strings.Cut(p, "=")
		if !ok || k == "" {
			return nil, fmt.Errorf("--label %q: want key=value", p)
		}
		m[k] = v
	}
	return m, nil
}

// RunRegistry implements `llmctl-decide registry ...`.
func RunRegistry(args []string, get func(string) string, out, errw io.Writer) int {
	if len(args) == 0 {
		return usageFail(errw, registryUsage, "a command is required")
	}
	cmd, rest := args[0], args[1:]
	fs := newFS("registry " + cmd)
	var stateDir, host, protocol, healthPath, token, kind, profile, instance, grace, portGrace, pruneUnknown, live, diffPrefix, diffInclude string
	var port, pid int
	var loopback, asJSON, liveSet, strict, noTenantRows bool
	var home string
	var labels stringList
	fs.StringVar(&stateDir, "state-dir", "", "")
	switch cmd {
	case "register":
		fs.IntVar(&port, "port", 0, "")
		fs.IntVar(&pid, "pid", 0, "")
		fs.StringVar(&token, "token", "", "")
		fs.StringVar(&host, "host", "", "")
		fs.StringVar(&protocol, "protocol", "", "")
		fs.StringVar(&healthPath, "health-path", "", "")
		fs.StringVar(&kind, "kind", "", "")
		fs.StringVar(&profile, "profile", "", "")
		fs.StringVar(&instance, "instance", "", "")
		fs.Var(&labels, "label", "")
		fs.BoolVar(&loopback, "loopback-only", false, "")
		fs.BoolVar(&asJSON, "json", false, "")
	case "unregister", "ack-corrupt":
	case "list":
		fs.BoolVar(&asJSON, "json", false, "")
	case "reconcile":
		fs.StringVar(&grace, "grace", "30s", "")
		fs.StringVar(&portGrace, "port-grace", "", "")
		fs.StringVar(&pruneUnknown, "prune-unknown-after", "0s", "")
		fs.StringVar(&home, "home", "", "")
		fs.BoolVar(&strict, "strict", false, "")
		fs.BoolVar(&asJSON, "json", false, "")
	case "diff":
		fs.StringVar(&live, "live", "", "")
		fs.StringVar(&diffPrefix, "prefix", "", "")
		fs.StringVar(&diffInclude, "include", "", "")
		fs.BoolVar(&noTenantRows, "no-tenant-rows", false, "")
		fs.BoolVar(&asJSON, "json", false, "")
	default:
		return usageFail(errw, registryUsage, fmt.Sprintf("unknown command %q", cmd))
	}
	pos, err := parseInterspersed(fs, rest)
	if err != nil {
		return usageFail(errw, registryUsage, err.Error())
	}
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "live" {
			liveSet = true
		}
	})
	if home != "" {
		inner := get
		get = func(k string) string {
			if k == "LLMCTL_HOME" {
				return home
			}
			return inner(k)
		}
	}
	cfg, err := configFor(get, stateDir)
	if err != nil {
		return usageFail(errw, registryUsage, err.Error())
	}
	r := New(cfg)
	switch cmd {
	case "register":
		if len(pos) != 1 {
			return usageFail(errw, registryUsage, "register takes exactly one NAME")
		}
		if port == 0 || pid == 0 || token == "" {
			return usageFail(errw, registryUsage, "register needs --port, --pid and --token")
		}
		lm, err := parseLabels(labels)
		if err != nil {
			return usageFail(errw, registryUsage, err.Error())
		}
		for k, v := range map[string]string{"kind": kind, "profile": profile, "instance": instance} {
			if v != "" {
				lm[k] = v
			}
		}
		if protocol == "" {
			protocol = "http"
		}
		lm["protocol"] = protocol
		e := Entry{Name: pos[0], Host: host, Port: port, Protocol: protocol, HealthPath: healthPath, Labels: lm,
			PID: pid, LoopbackOnly: loopback, CmdToken: token}
		if err := r.Register(e); err != nil {
			return failCode(errw, err)
		}
		got, _, _ := r.Get(e.Name)
		if asJSON {
			writeJSON(out, views([]Entry{got})[0])
		} else {
			fmt.Fprintf(out, "registered %s %s\n", got.Name, got.URL())
		}
	case "unregister":
		if len(pos) != 1 {
			return usageFail(errw, registryUsage, "unregister takes exactly one NAME")
		}
		had, err := r.Unregister(pos[0])
		if err != nil {
			return failCode(errw, err)
		}
		if had {
			fmt.Fprintf(out, "unregistered %s\n", pos[0])
		} else {
			fmt.Fprintf(out, "%s was not registered\n", pos[0])
		}
	case "list":
		if len(pos) != 0 {
			return usageFail(errw, registryUsage, "list takes no arguments")
		}
		es, err := r.List()
		if err != nil {
			return failCode(errw, err)
		}
		if n := r.CorruptNotice(); n != "" {
			fmt.Fprintf(errw, "WARNING: the service registry was found corrupt and moved aside (%s); acknowledge with `registry ack-corrupt`\n", n)
		}
		if asJSON {
			writeJSON(out, map[string]any{"services": views(es)})
		} else {
			printTable(out, es)
		}
	case "reconcile":
		g, e1 := time.ParseDuration(grace)
		var pg time.Duration
		var e2 error
		if portGrace != "" {
			pg, e2 = time.ParseDuration(portGrace)
		} else if w, werr := strconv.Atoi(get("LLMCTL_REGISTER_WAIT")); werr == nil && time.Duration(w)*time.Second > DefaultPortGrace {
			pg = time.Duration(w) * time.Second // an engine may load its model for the whole register wait
		}
		pu, e3 := time.ParseDuration(pruneUnknown)
		if e1 != nil || e2 != nil || e3 != nil || g < 0 || pg < 0 || pu < 0 {
			return usageFail(errw, registryUsage, "--grace, --port-grace and --prune-unknown-after take durations such as 30s")
		}
		rep, err := r.Reconcile(context.Background(), ReconcileOptions{Grace: g, PortGrace: pg, PruneUnknownAfter: pu})
		if err != nil {
			return failCode(errw, err)
		}
		if rep.Corrupt != "" {
			fmt.Fprintf(errw, "WARNING: the service registry was found corrupt and moved aside (%s); acknowledge with `registry ack-corrupt`\n", rep.Corrupt)
		}
		if asJSON {
			writeJSON(out, map[string]any{"removed": rep.Removed, "unhealthy": nonNil(rep.Unhealthy), "healthy": nonNil(rep.Healthy), "unknown": nonNilRemovals(rep.Unknown), "ports_pruned": rep.PortsPruned, "corrupt": rep.Corrupt})
			if strict && (len(rep.Unknown) > 0 || rep.Corrupt != "") {
				return ExitFailure
			}
			break
		}
		for _, rm := range rep.Removed {
			fmt.Fprintf(out, "removed %s: %s\n", rm.Name, rm.Reason)
		}
		for _, n := range rep.Unhealthy {
			fmt.Fprintf(out, "unhealthy %s\n", n)
		}
		for _, u := range rep.Unknown {
			fmt.Fprintf(out, "unknown %s: %s\n", u.Name, u.Reason)
		}
		fmt.Fprintf(out, "reconciled: %d healthy, %d unhealthy, %d unknown, %d removed, %d port holds pruned\n", len(rep.Healthy), len(rep.Unhealthy), len(rep.Unknown), len(rep.Removed), rep.PortsPruned)
		if strict && len(rep.Unknown) > 0 {
			fmt.Fprintln(errw, "error: CA not found: set LLMCTL_CACERT (--strict)")
			return ExitFailure
		}
		if strict && rep.Corrupt != "" {
			fmt.Fprintln(errw, "error: unacknowledged registry corruption (--strict)")
			return ExitFailure
		}
	case "ack-corrupt":
		if len(pos) != 0 {
			return usageFail(errw, registryUsage, "ack-corrupt takes no arguments")
		}
		had, err := r.AckCorrupt()
		if err != nil {
			return failCode(errw, err)
		}
		if had {
			fmt.Fprintln(out, "registry corruption acknowledged")
		} else {
			fmt.Fprintln(out, "no registry corruption note")
		}
	case "diff":
		if !liveSet || len(pos) != 0 {
			return usageFail(errw, registryUsage, "diff needs --live NAME=PID[,NAME=PID...] (an empty value means no live services)")
		}
		var ls []LiveService
		for _, item := range strings.Split(live, ",") {
			if item = strings.TrimSpace(item); item == "" {
				continue
			}
			n, p, ok := strings.Cut(item, "=")
			pidv, perr := strconv.Atoi(p)
			if !ok || n == "" || perr != nil {
				return usageFail(errw, registryUsage, fmt.Sprintf("--live item %q: want NAME=PID", item))
			}
			ls = append(ls, LiveService{n, pidv})
		}
		scope := DiffScope{Prefix: diffPrefix, NoTenantRows: noTenantRows}
		for _, n := range strings.Split(diffInclude, ",") {
			if n = strings.TrimSpace(n); n != "" {
				scope.Include = append(scope.Include, n)
			}
		}
		d, err := r.DiffScoped(ls, scope)
		if err != nil {
			return failCode(errw, err)
		}
		if n := r.CorruptNotice(); n != "" {
			fmt.Fprintf(errw, "error: the service registry was found corrupt and moved aside (%s): its rows are lost, services must re-register; acknowledge with `registry ack-corrupt`\n", n)
			return ExitFailure
		}
		if asJSON {
			writeJSON(out, map[string]any{"registry_only": nonNil(d.RegistryOnly), "live_only": nonNil(d.LiveOnly), "pid_mismatch": nonNil(d.PIDMismatch)})
		} else if d.Empty() {
			fmt.Fprintln(out, "registry == live set")
		} else {
			for _, n := range d.RegistryOnly {
				fmt.Fprintf(out, "registry row without a live service: %s\n", n)
			}
			for _, n := range d.LiveOnly {
				fmt.Fprintf(out, "live service without a registry row: %s\n", n)
			}
			for _, n := range d.PIDMismatch {
				fmt.Fprintf(out, "pid mismatch for %s\n", n)
			}
		}
		if !d.Empty() {
			return ExitFailure
		}
	}
	return ExitOK
}

func nonNil(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

// ---- discover ----------------------------------------------------------------

// RunDiscover implements `llmctl-decide discover` (the user-facing `llmctl discover`).
func RunDiscover(args []string, get func(string) string, out, errw io.Writer) int {
	fs := newFS("discover")
	var stateDir, kind string
	var asJSON, healthyOnly bool
	var labels stringList
	fs.StringVar(&stateDir, "state-dir", "", "")
	fs.StringVar(&kind, "kind", "", "")
	fs.BoolVar(&asJSON, "json", false, "")
	fs.BoolVar(&healthyOnly, "healthy-only", false, "")
	fs.Var(&labels, "label", "")
	pos, err := parseInterspersed(fs, args)
	if err != nil {
		return usageFail(errw, discoverUsage, err.Error())
	}
	if len(pos) != 0 {
		return usageFail(errw, discoverUsage, "discover takes no arguments")
	}
	want, err := parseLabels(labels)
	if err != nil {
		return usageFail(errw, discoverUsage, err.Error())
	}
	if kind != "" {
		want["kind"] = kind
	}
	cfg, err := configFor(get, stateDir)
	if err != nil {
		return usageFail(errw, discoverUsage, err.Error())
	}
	all, err := New(cfg).List()
	if err != nil {
		return failCode(errw, err)
	}
	var es []Entry
	for _, e := range all {
		if (!healthyOnly || e.Healthy) && matchLabels(e, want) {
			es = append(es, e)
		}
	}
	if asJSON {
		writeJSON(out, map[string]any{"services": views(es)})
	} else {
		printTable(out, es)
	}
	return ExitOK
}

func nonNilRemovals(r []Removal) []Removal {
	if r == nil {
		return []Removal{}
	}
	return r
}
