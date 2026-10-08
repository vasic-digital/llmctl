package keyring

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

const usageText = `usage: llmctl-decide key [--root DIR] {doctor|show|path|rotate|export} [flags]

  doctor                       report key source/permissions without printing the key
  show --yes-print             print the key (deliberate)
  path                         print the env file path
  rotate [--grace N]           generate and store a new key (N seconds of overlap)
  export --file F [--shell S] [--inline --yes-print]
                               add a managed export block to the named startup file

exit codes: 0 ok, 2 usage, 4 key problem`

type cliCtx struct {
	root string
	env  Environ
	out  io.Writer
	err  io.Writer
}

func (c *cliCtx) outln(a ...any) { fmt.Fprintln(c.out, a...) }

func newFlags(name string, errW io.Writer) *flag.FlagSet {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	return fs
}

// Run executes the `key` command family and returns the process exit code
// (0 ok, 2 usage, 4 key problem). defaultRoot is the installation root used
// unless --root is given.
func Run(args []string, env Environ, defaultRoot string, stdout, stderr io.Writer) int {
	c := &cliCtx{root: defaultRoot, env: env, out: stdout, err: stderr}
	usage := func(msg string) int {
		if msg != "" {
			fmt.Fprintln(stderr, "error: "+msg)
		}
		fmt.Fprintln(stderr, usageText)
		return 2
	}
	// global --root
	for len(args) > 0 && (args[0] == "--root" || strings.HasPrefix(args[0], "--root=")) {
		if v, ok := strings.CutPrefix(args[0], "--root="); ok {
			c.root, args = v, args[1:]
			continue
		}
		if len(args) < 2 {
			return usage("--root needs a directory")
		}
		c.root, args = args[1], args[2:]
	}
	if len(args) == 0 {
		return usage("a subcommand is required")
	}
	if args[0] == "-h" || args[0] == "--help" || args[0] == "help" {
		fmt.Fprintln(stdout, usageText)
		return 0
	}
	cmd, rest := args[0], args[1:]
	var rc int
	var err error
	switch cmd {
	case "path":
		if rc, err = c.noFlags(cmd, rest); rc != -1 {
			break
		}
		c.outln(EnvFilePath(c.root, c.env))
		rc = 0
	case "doctor":
		if rc, err = c.noFlags(cmd, rest); rc != -1 {
			break
		}
		rc, err = c.doctor()
	case "show":
		rc, err = c.show(rest)
	case "rotate":
		rc, err = c.rotate(rest)
	case "export":
		rc, err = c.export(rest)
	default:
		return usage(fmt.Sprintf("unknown subcommand %q", cmd))
	}
	if err != nil {
		var ue usageError
		if errors.As(err, &ue) {
			return usage(ue.Error())
		}
		fmt.Fprintf(stderr, "error: %s\n", err)
		if IsKeyError(err) {
			return ExitCode
		}
		return 1
	}
	return rc
}

type usageError string

func (u usageError) Error() string { return string(u) }

// noFlags rejects any arguments; returns -1 when the command may proceed.
func (c *cliCtx) noFlags(name string, rest []string) (int, error) {
	fs := newFlags(name, c.err)
	if err := fs.Parse(rest); err != nil {
		return 2, usageError(name + ": " + err.Error())
	}
	if fs.NArg() > 0 {
		return 2, usageError(name + ": unexpected argument")
	}
	return -1, nil
}

func (c *cliCtx) doctor() (int, error) {
	info, err := Inspect(c.root, c.env)
	if err != nil {
		return 0, err
	}
	if info.Source != "none" {
		c.outln("key: available")
	} else {
		c.outln("key: not available (will be generated on first start)")
	}
	c.outln("source: " + info.Source)
	c.outln("env file: " + info.Path)
	if info.FileExists {
		c.outln("env file present: yes")
	} else {
		c.outln("env file present: no")
	}
	if info.Mode != "" {
		safe := "UNSAFE"
		if info.Mode == "600" {
			safe = "safe"
		}
		c.outln(fmt.Sprintf("env file mode: %s (%s)", info.Mode, safe))
	}
	if info.FileShadowed {
		c.outln("note: the .env key is shadowed by a different LLMCTL_API_KEY in the process environment")
	}
	if info.PreviousPresent {
		c.outln("rotation overlap: a previous key is stored in the env file")
	}
	if err := CheckPlacement(info.Path); err != nil {
		return 0, err
	}
	c.outln("placement: ok")
	return 0, nil
}

func (c *cliCtx) show(rest []string) (int, error) {
	fs := newFlags("show", c.err)
	yes := fs.Bool("yes-print", false, "")
	if err := fs.Parse(rest); err != nil || fs.NArg() > 0 {
		return 2, usageError("show: invalid arguments")
	}
	if !*yes {
		fmt.Fprintln(c.err, "refusing to print the key without --yes-print")
		return 2, nil
	}
	res, err := Resolve(c.root, c.env, false)
	if err != nil {
		return 0, err
	}
	if res.Source == "none" {
		return 0, newErr(kindGeneric, "no access key is available yet; run 'rotate' or start the gateway to create one")
	}
	c.outln(res.Key.Reveal())
	return 0, nil
}

func (c *cliCtx) rotate(rest []string) (int, error) {
	fs := newFlags("rotate", c.err)
	grace := fs.Int("grace", 0, "")
	if err := fs.Parse(rest); err != nil || fs.NArg() > 0 {
		return 2, usageError("rotate: invalid arguments")
	}
	if *grace < 0 {
		return 2, usageError("--grace must be >= 0")
	}
	r, err := Rotate(c.root, c.env, *grace, time.Now())
	if err != nil {
		return 0, err
	}
	c.outln(fmt.Sprintf("new access key stored in %s (mode 0600)", r.Path))
	if r.PreviousExpires != 0 {
		c.outln(fmt.Sprintf("previous key stays valid until epoch %d (%ds grace)", r.PreviousExpires, *grace))
	}
	if r.GraceSkipped {
		c.outln("note: --grace was NOT applied: the old file key was not an accepted key (a different LLMCTL_API_KEY in the process environment shadows it, or it is too weak to have been accepted), so keeping it as an overlap key would have widened the accepted set")
	}
	// The CLI cannot see the environment of the running gateway (a service unit, a supervisor): it only
	// knows its own. Always say so (review A3-03).
	c.outln("scope: this rotation changes the key in the env file only. It does not affect a gateway that takes LLMCTL_API_KEY from its own environment: that gateway keeps accepting its environment key and ignores this file.")
	c.outln("  to revoke that key, change or unset LLMCTL_API_KEY where the gateway gets it and restart the gateway.")
	c.outln("update checklist:")
	c.outln("  1. restart the decision gateway so it loads the new key")
	c.outln("  2. update every client / other machine that supplies LLMCTL_API_KEY")
	c.outln("  3. refresh any shell rc line that holds a literal key (reference-form lines need no change)")
	c.outln("  4. show it deliberately when needed: key show --yes-print")
	if r.EnvShadows {
		c.outln("warning: LLMCTL_API_KEY is set in the process environment and still wins over the file; update or unset it")
	}
	return 0, nil
}

func (c *cliCtx) export(rest []string) (int, error) {
	fs := newFlags("export", c.err)
	file := fs.String("file", "", "")
	shell := fs.String("shell", "bash", "")
	inline := fs.Bool("inline", false, "")
	yes := fs.Bool("yes-print", false, "")
	if err := fs.Parse(rest); err != nil || fs.NArg() > 0 {
		return 2, usageError("export: invalid arguments")
	}
	switch *shell {
	case "bash", "zsh", "sh", "fish":
	default:
		return 2, usageError("--shell must be one of bash, zsh, sh, fish")
	}
	if *file == "" {
		fmt.Fprintln(c.err, "export needs --file <startup file>; llmctl never guesses one")
		return 2, nil
	}
	if *inline && !*yes {
		fmt.Fprintln(c.err, "--inline writes the literal key; add --yes-print to confirm")
		return 2, nil
	}
	path := EnvFilePath(c.root, c.env)
	var key *Secret
	if *inline {
		res, err := Resolve(c.root, c.env, false)
		if err != nil {
			return 0, err
		}
		if res.Source == "none" {
			return 0, newErr(kindGeneric, "no access key is available yet; run 'rotate' first")
		}
		key = &res.Key
	}
	line, err := ExportLine(*shell, path, key)
	if err != nil {
		return 0, err
	}
	c.outln("will write to " + *file + ":")
	c.outln(BlockBegin)
	c.outln(line) // inline form shows the key: the operator confirmed with --yes-print
	c.outln(BlockEnd)
	res, err := InstallExportBlock(*file, line, true)
	if err != nil {
		return 0, err
	}
	if res.Changed {
		c.outln("written")
	} else {
		c.outln("already up to date (no change)")
	}
	if res.Backup != "" {
		c.outln("backup: " + res.Backup)
	}
	for _, w := range res.Warnings {
		c.outln("warning: " + w)
	}
	return 0, nil
}
