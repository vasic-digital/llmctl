package certs

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Exit codes of `llmctl cert`.
const (
	ExitOK    = 0
	ExitUsage = 2
	ExitCert  = 5
)

const usageText = `usage: llmctl cert [--home DIR] <command> [flags]

commands:
  ensure [--mode ca-leaf|selfsigned|byo] [--san dns:N,ip:A] [--offline-ca-key DEST [--force-overwrite-ca-export]]
  show [--json]
  export DEST
  renew [--reuse-key] [--san dns:N,ip:A] [--ca-key PATH] [--mode M]
  doctor [--json]

exit codes: 0 ok, 2 usage, 5 certificate/TLS problem`

// strVal / listVal are flag.Values that, unlike flag.StringVar, never reset
// their target when registered, so the same variables can be bound on the
// global and on the per-command flag sets.
type strVal struct {
	p   *string
	set *bool
}

func (v strVal) String() string { return "" }
func (v strVal) Set(s string) error {
	*v.p = s
	if v.set != nil {
		*v.set = true
	}
	return nil
}

type listVal struct{ p *[]string }

func (v listVal) String() string { return "" }
func (v listVal) Set(s string) error {
	*v.p = append(*v.p, s)
	return nil
}

type common struct {
	home, now        string
	hostnames, addrs []string
	hostSet, addrSet bool
}

func (c *common) bind(fs *flag.FlagSet) {
	fs.Var(strVal{p: &c.home}, "home", "directory holding cert/ (default $LLMCTL_HOME or $HOME/llmctl)")
	fs.Var(strVal{p: &c.now}, "now", "test hook: epoch seconds used as the clock for validity checks")
	fs.Var(listVal{p: &c.hostnames}, "hostname", "test hook: host name for the certificate (repeatable; default: detect)")
	fs.Var(listVal{p: &c.addrs}, "address", "test hook: address for the certificate (repeatable; default: detect)")
}

// Run executes `llmctl cert ...` and returns the process exit code.
func Run(args []string, stdout, stderr io.Writer) int {
	var c common
	g := newFlagSet("llmctl cert", stderr)
	c.bind(g)
	if err := g.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			fmt.Fprintln(stdout, usageText)
			return ExitOK
		}
		return ExitUsage
	}
	rest := g.Args()
	if len(rest) == 0 {
		fmt.Fprintln(stderr, usageText)
		return ExitUsage
	}
	cmd, rest := rest[0], rest[1:]
	fs := newFlagSet("llmctl cert "+cmd, stderr)
	c.bind(fs)
	var (
		mode, san, offline, caKey string
		reuse, asJSON, forceCA    bool
	)
	switch cmd {
	case "ensure":
		fs.Var(strVal{p: &mode}, "mode", "ca-leaf (default), selfsigned or byo")
		fs.Var(strVal{p: &san}, "san", "extra names: dns:NAME,ip:ADDR (default $LLMCTL_TLS_SAN)")
		fs.Var(strVal{p: &offline}, "offline-ca-key", "move the CA key to DEST and remove it from this host")
		fs.BoolVar(&forceCA, "force-overwrite-ca-export", false, "let --offline-ca-key replace an existing DEST (default: refuse)")
	case "renew":
		fs.Var(strVal{p: &mode}, "mode", "ca-leaf, selfsigned")
		fs.Var(strVal{p: &san}, "san", "extra names: dns:NAME,ip:ADDR (default $LLMCTL_TLS_SAN)")
		fs.BoolVar(&reuse, "reuse-key", false, "keep the current leaf private key")
		fs.Var(strVal{p: &caKey}, "ca-key", "the CA key when it is offline")
	case "show", "doctor":
		fs.BoolVar(&asJSON, "json", false, "machine-readable output")
	case "export":
	default:
		fmt.Fprintf(stderr, "llmctl cert: unknown command %q\n%s\n", cmd, usageText)
		return ExitUsage
	}
	if err := fs.Parse(rest); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return ExitOK
		}
		return ExitUsage
	}
	pos := fs.Args()
	want := 0
	if cmd == "export" {
		want = 1
	}
	if len(pos) != want {
		fmt.Fprintf(stderr, "llmctl cert %s: expected %d argument(s), got %d\n", cmd, want, len(pos))
		return ExitUsage
	}
	if mode != "" && !validMode(mode) {
		fmt.Fprintf(stderr, "llmctl cert %s: --mode must be one of %s\n", cmd, strings.Join(Modes, ", "))
		return ExitUsage
	}
	o := Options{Home: c.home, Mode: mode, SANs: san, Hostnames: c.hostnames, Addresses: c.addrs,
		OfflineCAKeyTo: offline, ReuseKey: reuse, CAKeyPath: caKey, ForceOverwriteCAExport: forceCA}
	if o.Home == "" {
		o.Home = os.Getenv("LLMCTL_HOME")
	}
	if o.Home == "" {
		h, err := os.UserHomeDir()
		if err != nil {
			fmt.Fprintln(stderr, "llmctl cert: cannot determine the home directory; use --home or LLMCTL_HOME")
			return ExitUsage
		}
		o.Home = filepath.Join(h, "llmctl")
	}
	if c.now != "" {
		f, err := strconv.ParseFloat(c.now, 64)
		if err != nil {
			fmt.Fprintf(stderr, "llmctl cert: invalid --now %q\n", c.now)
			return ExitUsage
		}
		o.Now = time.Unix(int64(f), 0)
	}
	return dispatch(cmd, o, pos, asJSON, stdout, stderr)
}

func newFlagSet(name string, stderr io.Writer) *flag.FlagSet {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(stderr)
	return fs
}

func fail(stderr io.Writer, err error) int {
	fmt.Fprintf(stderr, "error: %v\n", err)
	return ExitCert
}

func dispatch(cmd string, o Options, pos []string, asJSON bool, stdout, stderr io.Writer) int {
	var info *CertInfo
	var err error
	switch cmd {
	case "ensure":
		info, err = Ensure(o)
	case "renew":
		info, err = Renew(o)
	case "show":
		d, err := Show(o)
		if err != nil {
			return fail(stderr, err)
		}
		if asJSON {
			b, _ := json.MarshalIndent(d, "", " ")
			fmt.Fprintln(stdout, string(b))
		} else {
			printShow(stdout, d)
		}
		return ExitOK
	case "export":
		out, err := ExportCA(o.Home, pos[0])
		if err != nil {
			return fail(stderr, err)
		}
		fmt.Fprintln(stdout, out)
		return ExitOK
	case "doctor":
		rep, _ := Doctor(o)
		if asJSON {
			b, _ := json.MarshalIndent(rep, "", " ")
			fmt.Fprintln(stdout, string(b))
		} else {
			for _, c := range rep.Checks {
				fmt.Fprintf(stdout, "%-5s %-17s %s\n", strings.ToUpper(c.Status), c.Name, c.Detail)
			}
		}
		if rep.OK {
			return ExitOK
		}
		return ExitCert
	}
	if err != nil {
		return fail(stderr, err)
	}
	for _, w := range info.Warnings {
		fmt.Fprintf(stderr, "WARNING: %s\n", w)
	}
	verb := "ok"
	if info.Created {
		verb = "issued"
	}
	ver := "none"
	if info.Version > 0 {
		ver = strconv.Itoa(info.Version)
	}
	fmt.Fprintf(stdout, "%s mode=%s version=%s created=%t\n", verb, info.Mode, ver, info.Created)
	fmt.Fprintf(stdout, "leaf_sha256 %s\n", info.LeafFingerprint)
	return ExitOK
}

func printShow(w io.Writer, d *ShowInfo) {
	ver := "none"
	if d.Version > 0 {
		ver = strconv.Itoa(d.Version)
	}
	rows := [][2]string{
		{"mode", d.Mode}, {"dir", d.Dir}, {"version", ver}, {"ca_cert", d.CACert},
		{"leaf_cert", d.LeafCert}, {"leaf_key", d.LeafKey}, {"chain", d.Chain},
		{"ca_sha256", d.CASHA256}, {"leaf_sha256", d.LeafSHA256}, {"sans", strings.Join(d.SANs, ",")},
		{"not_before", d.NotBefore}, {"not_after", d.NotAfter}, {"days_left", strconv.Itoa(d.DaysLeft)},
		{"ca_key_on_host", strconv.FormatBool(d.CAKeyOnHost)},
	}
	for _, r := range rows {
		fmt.Fprintf(w, "%-14s %s\n", r[0], r[1])
	}
}
