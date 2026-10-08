package main

import (
	"bytes"
	"flag"
	"fmt"
	"io"
	"regexp"
	"sort"
	"strings"

	"github.com/vasic-digital/llmctl/internal/calibrate"
	"github.com/vasic-digital/llmctl/internal/schema"
)

// `llmctl-decide completions {bash|zsh}` prints a shell completion script for the REAL command set
// (contracts/cli.md, FR-081). Nothing is hand-listed that the binary can tell: the commands come
// from the registry (register()), the flags of every flag.FlagSet-based command are captured from
// the live flag sets (askNewFlagSet's hook) or, for commands with their own flag handling, read from
// the usage text the command itself prints for -h; subcommands of the commands that parse their own
// arguments (key, cert, port, registry, vantage) come from the same usage text. A command or flag
// added tomorrow is in the script without editing this file (tests prove it). No network, no key,
// no state: the script is pure text.
//
// Install:  eval "$(llmctl decide completions bash)"            (bash 3.2+)
//
//	source <(llmctl decide completions zsh)             (zsh, after compinit)
func init() {
	register("completions", func(a []string, o, e io.Writer) int { return runCompletions(a, o, e) })
}

// flagCapture, when set, receives every FlagSet that askNewFlagSet creates (test and completion seam).
var flagCapture func(*flag.FlagSet)

// completionShells are the supported shells (and the positional values of `completions`).
var completionShells = []string{"bash", "zsh"}

// completionShellOnly are the words `llmctl decide` handles in its shell front end (lib/decide.sh)
// rather than forwarding to this binary; a test keeps the list equal to the front end's case labels.
var completionShellOnly = []string{"capacity", "status", "interactive", "help"}

// completionDescriptions are cosmetic one-liners for zsh; a command without one gets a generic line.
var completionDescriptions = map[string]string{
	"ask": "ask one typed question", "batch": "newline-delimited batch of requests", "models": "list the served models",
	"schema": "emit the question schema as a tool definition", "serve": "run the HTTPS decision gateway",
	"key": "access key management", "cert": "certificate management", "mcp": "tool server for coding agents",
	"smoke": "one deterministic question against one engine", "calibrate": "fit a confidence calibration profile from labels",
	"probe-order": "measure answer sensitivity to option order", "completions": "print a shell completion script",
	"port": "port allocator", "registry": "service registry", "discover": "list published services", "vantage": "second network location",
	"capacity": "parallel-instance plan per decision profile", "status": "profiles, gateway and registry state",
	"interactive": "interactive wizard", "help": "usage",
}

func runCompletions(args []string, stdout, stderr io.Writer) int {
	fs := askNewFlagSet("completions")
	if err := fs.Parse(args); err != nil {
		if err == flag.ErrHelp {
			fmt.Fprintf(stderr, "usage: llmctl-decide completions {%s}\n", strings.Join(completionShells, "|"))
			return 0
		}
		fmt.Fprintf(stderr, "llmctl-decide completions: %v\n", err)
		return 2
	}
	switch {
	case fs.NArg() == 0:
		fmt.Fprintf(stderr, "llmctl-decide completions: a shell is required: {%s}\n", strings.Join(completionShells, "|"))
		return 2
	case fs.NArg() > 1:
		fmt.Fprintf(stderr, "llmctl-decide completions: unexpected argument %q (one shell only)\n", askShorten(fs.Arg(1)))
		return 2
	}
	specs := completionSpecs()
	switch fs.Arg(0) {
	case "bash":
		_, _ = io.WriteString(stdout, renderBashCompletion(specs))
	case "zsh":
		_, _ = io.WriteString(stdout, renderZshCompletion(specs))
	default:
		fmt.Fprintf(stderr, "llmctl-decide completions: unsupported shell %q (supported: %s)\n", askShorten(fs.Arg(0)), strings.Join(completionShells, ", "))
		return 2
	}
	return 0
}

// ---------------------------------------------------------------- introspection

type completionFlag struct {
	Name  string
	Usage string
	Bool  bool
}

type completionCmd struct {
	Name  string
	Flags []completionFlag
	Subs  []string
}

var (
	// flag.PrintDefaults format: "  -name [type]\n    \tusage"
	textFlagRE  = regexp.MustCompile(`(?m)^  -{1,2}([A-Za-z0-9][A-Za-z0-9_-]*)(?: (\S+))?\n    \t(.*)$`)
	proseFlagRE = regexp.MustCompile(`--([a-z][a-z0-9-]*)`)
	subWordRE   = regexp.MustCompile(`(?m)^  ([a-z][a-z0-9-]*)\b`)
)

// introspect runs a registered command with -h and returns the FlagSets it created and the text it
// printed. -h is a pure help request in every command (it returns before any work).
func introspect(name string) (sets []*flag.FlagSet, text string) {
	old := flagCapture
	flagCapture = func(fs *flag.FlagSet) { sets = append(sets, fs) }
	defer func() {
		flagCapture = old
		if r := recover(); r != nil {
			text = ""
		}
	}()
	var buf bytes.Buffer
	commands[name]([]string{"-h"}, &buf, &buf)
	return sets, buf.String()
}

// completionSubcommands lists the subcommands a command's own usage text names (two-space-indented
// lowercase words), sorted; empty for commands that have none.
func completionSubcommands(name string) []string {
	if _, ok := commands[name]; !ok {
		return nil
	}
	_, text := introspect(name)
	seen := map[string]bool{}
	var out []string
	for _, m := range subWordRE.FindAllStringSubmatch(text, -1) {
		if !seen[m[1]] {
			seen[m[1]] = true
			out = append(out, m[1])
		}
	}
	sort.Strings(out)
	return out
}

func completionSpecs() []completionCmd {
	var specs []completionCmd
	for _, name := range names() {
		c := completionCmd{Name: name}
		sets, text := introspect(name)
		have := map[string]*completionFlag{}
		add := func(f completionFlag) {
			if f.Name == "h" || f.Name == "help" {
				return
			}
			if old, ok := have[f.Name]; ok {
				if old.Usage == "" {
					old.Usage = f.Usage
				}
				return
			}
			have[f.Name] = &f
		}
		for _, fs := range sets {
			fs.VisitAll(func(f *flag.Flag) {
				isBool := false
				if bf, ok := f.Value.(interface{ IsBoolFlag() bool }); ok {
					isBool = bf.IsBoolFlag()
				}
				add(completionFlag{Name: f.Name, Usage: f.Usage, Bool: isBool})
			})
		}
		for _, m := range textFlagRE.FindAllStringSubmatch(text, -1) {
			add(completionFlag{Name: m[1], Usage: strings.TrimSpace(m[3]), Bool: m[2] == ""})
		}
		for _, m := range proseFlagRE.FindAllStringSubmatch(text, -1) {
			add(completionFlag{Name: m[1]})
		}
		for _, f := range have {
			c.Flags = append(c.Flags, *f)
		}
		sort.Slice(c.Flags, func(i, j int) bool { return c.Flags[i].Name < c.Flags[j].Name })
		c.Subs = completionSubcommands(name)
		if name == "completions" {
			c.Subs = nil
		}
		specs = append(specs, c)
	}
	return specs
}

// completionValues are flag values enumerated by the code itself (never retyped here).
func completionValues(cmd, flagName string) []string {
	switch {
	case cmd == "calibrate" && flagName == "method":
		return calibrate.Methods
	case cmd == "schema" && flagName == "format":
		var out []string
		for _, f := range schema.Formats() {
			out = append(out, string(f))
		}
		return out
	}
	return nil
}

// ---------------------------------------------------------------- bash

func renderBashCompletion(specs []completionCmd) string {
	var b strings.Builder
	var bin, front []string
	for _, s := range specs {
		bin = append(bin, s.Name)
	}
	front = append(front, bin...)
	front = append(front, completionShellOnly...)
	sort.Strings(front)
	b.WriteString("# bash completion for llmctl-decide and `llmctl decide` (bash 3.2+).\n")
	b.WriteString("# Generated by `llmctl-decide completions bash` from the registered commands and their flags;\n")
	b.WriteString("# do not edit. Enable with:  eval \"$(llmctl decide completions bash)\"\n")
	b.WriteString("_llmctl_decide_complete() {\n")
	b.WriteString("    local cur prev start cmd\n")
	b.WriteString("    COMPREPLY=()\n")
	b.WriteString("    cur=\"${COMP_WORDS[COMP_CWORD]}\"\n")
	b.WriteString("    prev=\"\"\n")
	b.WriteString("    if [ \"$COMP_CWORD\" -gt 0 ]; then prev=\"${COMP_WORDS[COMP_CWORD-1]}\"; fi\n")
	b.WriteString("    start=1\n")
	b.WriteString("    case \"${COMP_WORDS[0]##*/}\" in\n")
	b.WriteString("        llmctl)\n")
	b.WriteString("            if [ \"${COMP_WORDS[1]}\" != \"decide\" ]; then return 0; fi\n")
	b.WriteString("            start=2\n")
	b.WriteString("            ;;\n")
	b.WriteString("    esac\n")
	b.WriteString("    if [ \"$COMP_CWORD\" -le \"$start\" ]; then\n")
	b.WriteString("        if [ \"$start\" -eq 2 ]; then\n")
	fmt.Fprintf(&b, "            COMPREPLY=( $(compgen -W \"%s\" -- \"$cur\") )\n", strings.Join(front, " "))
	b.WriteString("        else\n")
	fmt.Fprintf(&b, "            COMPREPLY=( $(compgen -W \"%s\" -- \"$cur\") )\n", strings.Join(bin, " "))
	b.WriteString("        fi\n")
	b.WriteString("        return 0\n")
	b.WriteString("    fi\n")
	b.WriteString("    cmd=\"${COMP_WORDS[$start]}\"\n")
	b.WriteString("    case \"$cmd\" in\n")
	for _, s := range specs {
		fmt.Fprintf(&b, "        %s)\n", s.Name)
		for _, f := range s.Flags {
			if vals := completionValues(s.Name, f.Name); len(vals) > 0 {
				fmt.Fprintf(&b, "            if [ \"$prev\" = \"--%s\" ]; then COMPREPLY=( $(compgen -W \"%s\" -- \"$cur\") ); return 0; fi\n", f.Name, strings.Join(vals, " "))
			}
		}
		if s.Name == "completions" {
			fmt.Fprintf(&b, "            COMPREPLY=( $(compgen -W \"%s\" -- \"$cur\") )\n", strings.Join(completionShells, " "))
			b.WriteString("            ;;\n")
			continue
		}
		if len(s.Subs) > 0 {
			b.WriteString("            if [ \"$COMP_CWORD\" -eq $((start+1)) ] && [ \"${cur#-}\" = \"$cur\" ]; then\n")
			fmt.Fprintf(&b, "                COMPREPLY=( $(compgen -W \"%s\" -- \"$cur\") )\n", strings.Join(s.Subs, " "))
			b.WriteString("                return 0\n")
			b.WriteString("            fi\n")
		}
		var fl []string
		for _, f := range s.Flags {
			fl = append(fl, "--"+f.Name)
		}
		b.WriteString("            if [ \"${cur#-}\" != \"$cur\" ]; then\n")
		fmt.Fprintf(&b, "                COMPREPLY=( $(compgen -W \"%s\" -- \"$cur\") )\n", strings.Join(fl, " "))
		b.WriteString("            fi\n")
		b.WriteString("            ;;\n")
	}
	b.WriteString("    esac\n")
	b.WriteString("    return 0\n")
	b.WriteString("}\n")
	b.WriteString("complete -o default -F _llmctl_decide_complete llmctl-decide\n")
	b.WriteString("# `llmctl decide ...`: claimed only when llmctl has no completion of its own\n")
	b.WriteString("if ! complete -p llmctl >/dev/null 2>&1; then complete -o default -F _llmctl_decide_complete llmctl; fi\n")
	return b.String()
}

// ---------------------------------------------------------------- zsh

// zshQuote single-quotes s for zsh (a single quote becomes '\”).
func zshQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

func renderZshCompletion(specs []completionCmd) string {
	var b strings.Builder
	b.WriteString("#compdef llmctl-decide\n")
	b.WriteString("# zsh completion for llmctl-decide and `llmctl decide`.\n")
	b.WriteString("# Generated by `llmctl-decide completions zsh` from the registered commands and their flags;\n")
	b.WriteString("# do not edit. Enable with:  source <(llmctl decide completions zsh)   (after compinit)\n")
	b.WriteString("_llmctl_decide() {\n")
	b.WriteString("  local off=1 cmd prev\n")
	b.WriteString("  local -a cmds opts subs\n")
	b.WriteString("  if [[ ${words[1]:t} == llmctl ]]; then\n")
	b.WriteString("    [[ ${words[2]} == decide ]] || return 1\n")
	b.WriteString("    off=2\n")
	b.WriteString("  fi\n")
	b.WriteString("  cmds=(\n")
	var all []string
	for _, s := range specs {
		all = append(all, s.Name)
	}
	all = append(all, completionShellOnly...)
	sort.Strings(all)
	for _, n := range all {
		d := completionDescriptions[n]
		if d == "" {
			d = "llmctl-decide " + n
		}
		fmt.Fprintf(&b, "    %s\n", zshQuote(n+":"+d))
	}
	b.WriteString("  )\n")
	b.WriteString("  if (( CURRENT <= off + 1 )); then\n")
	b.WriteString("    _describe -t commands 'llmctl decide command' cmds\n")
	b.WriteString("    return\n")
	b.WriteString("  fi\n")
	b.WriteString("  cmd=${words[off+1]}\n")
	b.WriteString("  prev=${words[CURRENT-1]}\n")
	b.WriteString("  case $cmd in\n")
	for _, s := range specs {
		fmt.Fprintf(&b, "    %s)\n", s.Name)
		if s.Name == "completions" {
			fmt.Fprintf(&b, "      compadd -- %s\n", strings.Join(completionShells, " "))
			b.WriteString("      ;;\n")
			continue
		}
		b.WriteString("      opts=(\n")
		for _, f := range s.Flags {
			d := f.Usage
			if d == "" {
				d = "--" + f.Name
			}
			fmt.Fprintf(&b, "        %s\n", zshQuote("--"+f.Name+":"+d))
		}
		b.WriteString("      )\n")
		if len(s.Subs) > 0 {
			fmt.Fprintf(&b, "      subs=(%s)\n", strings.Join(s.Subs, " "))
		} else {
			b.WriteString("      subs=()\n")
		}
		for _, f := range s.Flags {
			if vals := completionValues(s.Name, f.Name); len(vals) > 0 {
				fmt.Fprintf(&b, "      if [[ $prev == --%s ]]; then compadd -- %s; return; fi\n", f.Name, strings.Join(vals, " "))
			}
		}
		b.WriteString("      ;;\n")
	}
	b.WriteString("  esac\n")
	b.WriteString("  if [[ ${words[CURRENT]} == -* ]]; then\n")
	b.WriteString("    (( ${#opts} )) && _describe -t options 'option' opts\n")
	b.WriteString("  elif (( ${#subs} && CURRENT == off + 2 )); then\n")
	b.WriteString("    _describe -t commands 'subcommand' subs\n")
	b.WriteString("  else\n")
	b.WriteString("    _files\n")
	b.WriteString("  fi\n")
	b.WriteString("}\n")
	b.WriteString("(( $+functions[compdef] )) || { autoload -Uz compinit && compinit; }\n")
	b.WriteString("compdef _llmctl_decide llmctl-decide\n")
	b.WriteString("[[ -n ${_comps[llmctl]} ]] || compdef _llmctl_decide llmctl\n")
	return b.String()
}
