package main

import (
	"bytes"
	"flag"
	"io"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"
)

func compRun(args ...string) (int, string, string) {
	var out, errb bytes.Buffer
	rc := run(append([]string{"completions"}, args...), &out, &errb)
	return rc, out.String(), errb.String()
}

func TestCompletionsRefuseOtherShellsAndBadUsageWithExit2(t *testing.T) {
	for _, c := range []struct {
		args []string
		want string
	}{
		{nil, "bash"},
		{[]string{"fish"}, "fish"},
		{[]string{"powershell"}, "powershell"},
		{[]string{"BASH"}, "BASH"},
		{[]string{"bash", "zsh"}, "unexpected argument"},
		{[]string{"--nope", "bash"}, "nope"},
	} {
		rc, out, errs := compRun(c.args...)
		if rc != 2 || out != "" || !strings.Contains(errs, c.want) {
			t.Errorf("%v: rc=%d stdout=%q stderr=%q", c.args, rc, out, errs)
		}
	}
}

func TestCompletionsAreDeterministicAndQuiet(t *testing.T) {
	for _, sh := range []string{"bash", "zsh"} {
		rc, a, e := compRun(sh)
		_, b, _ := compRun(sh)
		if rc != 0 || e != "" || a == "" || a != b {
			t.Errorf("%s: rc=%d stderr=%q deterministic=%v", sh, rc, e, a == b)
		}
		for _, secret := range []string{askTestKey, "LLMCTL_API_KEY=", "BEGIN PRIVATE"} {
			if strings.Contains(a, secret) {
				t.Errorf("%s: completion script contains %q", sh, secret)
			}
		}
	}
}

// ---- drift: the script is generated from the live registry and flag sets

// bashBlock returns the text of the `name)` case arm of the bash script.
func bashBlock(t *testing.T, script, name string) string {
	t.Helper()
	re := regexp.MustCompile(`(?m)^\s{4,}` + regexp.QuoteMeta(name) + `\)\n((?:.*\n)*?)\s{4,};;`)
	m := re.FindStringSubmatch(script)
	if m == nil {
		t.Fatalf("the bash script has no case arm for %q", name)
	}
	return m[1]
}

// independentFlags lists the flags of a flag.FlagSet-based command by running its own parser with
// -h under a capture hook installed by THIS test (not by the generator).
func independentFlags(name string) []string {
	var sets []*flag.FlagSet
	old := flagCapture
	flagCapture = func(fs *flag.FlagSet) { sets = append(sets, fs) }
	defer func() { flagCapture = old }()
	commands[name]([]string{"-h"}, io.Discard, io.Discard)
	var out []string
	for _, fs := range sets {
		fs.VisitAll(func(f *flag.Flag) { out = append(out, f.Name) })
	}
	sort.Strings(out)
	return out
}

func TestEveryRegisteredCommandAndFlagIsInBothScripts(t *testing.T) {
	_, bash, _ := compRun("bash")
	_, zsh, _ := compRun("zsh")
	checked := 0
	for _, name := range names() {
		if !strings.Contains(bash, name) {
			t.Errorf("bash script lacks command %q", name)
		}
		if !strings.Contains(zsh, "'"+name+":") {
			t.Errorf("zsh script lacks command %q", name)
		}
		blk := bashBlock(t, bash, name)
		for _, f := range independentFlags(name) {
			checked++
			if !strings.Contains(blk, "--"+f) {
				t.Errorf("bash arm of %q lacks --%s", name, f)
			}
			if !strings.Contains(zsh, "'--"+f+":") {
				t.Errorf("zsh script lacks --%s of %q", f, name)
			}
		}
	}
	if checked < 30 {
		t.Errorf("only %d flags cross-checked: the introspection found almost nothing", checked)
	}
}

// A command registered tomorrow, with a flag nobody told the completion code about, is in the script.
func TestNewlyRegisteredCommandAndFlagAppearWithoutAnyEdit(t *testing.T) {
	register("zz-drift-probe", func(a []string, o, e io.Writer) int {
		fs := askNewFlagSet("zz-drift-probe")
		fs.String("zz-new-flag", "", "a flag added after the completion code was written")
		fs.Bool("zz-bool", false, "a switch")
		if rc, ok := fs.parse(a, e); !ok {
			return rc
		}
		return 0
	})
	defer delete(commands, "zz-drift-probe")
	_, bash, _ := compRun("bash")
	_, zsh, _ := compRun("zsh")
	for name, s := range map[string]string{"bash": bash, "zsh": zsh} {
		for _, want := range []string{"zz-drift-probe", "--zz-new-flag", "--zz-bool"} {
			if !strings.Contains(s, want) {
				t.Errorf("%s script lacks %q", name, want)
			}
		}
	}
	if !strings.Contains(zsh, "a flag added after the completion code was written") {
		t.Error("the zsh description does not come from the flag's usage string")
	}
}

func TestCompletionOfTheNewCommandsThemselves(t *testing.T) {
	_, bash, _ := compRun("bash")
	for cmd, flags := range map[string][]string{
		"calibrate":   {"--profile", "--labels", "--method", "--catalog", "--state-dir", "--model-sha", "--template-hash", "--unbound", "--dry-run", "--json"},
		"probe-order": {"--questions", "--profile", "--permute", "--state-file", "--json", "--endpoint", "--cacert"},
		"completions": nil,
	} {
		blk := bashBlock(t, bash, cmd)
		for _, f := range flags {
			if !strings.Contains(blk, f) {
				t.Errorf("%s: %s missing", cmd, f)
			}
		}
	}
}

// Subcommands of the commands that parse their own arguments are taken from their real usage text;
// the pinned lists fail when a usage text and therefore the completion changes.
func TestSubcommandsOfCustomParsedCommandsMatchTheirUsage(t *testing.T) {
	want := map[string][]string{
		"key":      {"doctor", "export", "path", "rotate", "show"},
		"cert":     {"doctor", "ensure", "export", "renew", "show"},
		"port":     {"allocate", "list", "release"},
		"registry": {"ack-corrupt", "diff", "list", "reconcile", "register", "unregister"},
		"vantage":  {"down", "exec", "probe", "probe-ports", "selfcheck", "status", "up"},
	}
	_, bash, _ := compRun("bash")
	for cmd, subs := range want {
		blk := bashBlock(t, bash, cmd)
		for _, s := range subs {
			if !strings.Contains(blk, s) {
				t.Errorf("%s: subcommand %q missing from %q", cmd, s, blk)
			}
		}
		got := completionSubcommands(cmd)
		sort.Strings(got)
		if strings.Join(got, ",") != strings.Join(subs, ",") {
			t.Errorf("%s: usage-derived subcommands %v, pinned %v (a usage text changed: update the pin deliberately)", cmd, got, subs)
		}
	}
}

// `llmctl decide <TAB>` also offers the words handled by the shell front end; the case labels of
// lib/decide.sh cmd_decide are the source of truth.
func TestFrontEndWordsMatchLibDecideSh(t *testing.T) {
	b, err := os.ReadFile("../../lib/decide.sh")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i := strings.Index(src, "cmd_decide() {")
	if i < 0 {
		t.Fatal("cmd_decide not found in lib/decide.sh")
	}
	body := src[i:]
	labelRE := regexp.MustCompile(`(?m)^    ([a-z][a-z|-]*)\)`)
	_, bash, _ := compRun("bash")
	declared := map[string]bool{}
	for _, m := range labelRE.FindAllStringSubmatch(body, -1) {
		for _, w := range strings.Split(m[1], "|") {
			declared[w] = true
		}
	}
	// words the shell front end serves itself, or forwards to a binary subcommand
	for w := range declared {
		if strings.HasPrefix(w, "-") || w == "help" || w == "scale" { // help is documented text; scale is forwarded but not yet registered
			continue
		}
		if !strings.Contains(bash, w) {
			t.Errorf("lib/decide.sh handles %q but the completion script does not offer it", w)
		}
	}
	for _, w := range completionShellOnly {
		if !declared[w] {
			t.Errorf("completion offers the front-end word %q that lib/decide.sh no longer handles", w)
		}
	}
}

func TestBashScriptIsBash32Compatible(t *testing.T) {
	_, s, _ := compRun("bash")
	for _, bad := range []string{"[[", "declare -A", "typeset -A", "mapfile", "readarray", ",,}", "^^}", "&>>", "|&", "coproc", "${!", "local -n", "compopt"} {
		if strings.Contains(s, bad) {
			t.Errorf("bash script uses %q, which bash 3.2 lacks", bad)
		}
	}
	if !strings.Contains(s, "complete -o default -F") {
		t.Error("no complete -F registration")
	}
	if bash, err := exec.LookPath("bash"); err == nil {
		cmd := exec.Command(bash, "-n")
		cmd.Stdin = strings.NewReader(s)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Errorf("bash -n: %v %s", err, out)
		}
	}
}

// Real TAB behaviour: source the script in bash, fake COMP_WORDS and read COMPREPLY.
func TestBashCompletionBehaviourInARealShell(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash is not installed")
	}
	_, script, _ := compRun("bash")
	complete := func(words ...string) []string {
		cur := ""
		cw := len(words) - 1
		if cw >= 0 {
			cur = words[cw]
		}
		_ = cur
		var q []string
		for _, w := range words {
			q = append(q, "'"+strings.ReplaceAll(w, "'", `'\''`)+"'")
		}
		prog := script + "\nCOMP_WORDS=(" + strings.Join(q, " ") + ")\nCOMP_CWORD=" + strconv.Itoa(cw) + "\n_llmctl_decide_complete\nprintf '%s\\n' \"${COMPREPLY[@]}\"\n"
		out, err := exec.Command(bash, "-c", prog).CombinedOutput()
		if err != nil {
			t.Fatalf("bash failed for %v: %v\n%s", words, err, out)
		}
		var res []string
		for _, l := range strings.Split(strings.TrimSpace(string(out)), "\n") {
			if l != "" {
				res = append(res, l)
			}
		}
		sort.Strings(res)
		return res
	}
	eq := func(got []string, want ...string) bool {
		sort.Strings(want)
		return strings.Join(got, " ") == strings.Join(want, " ")
	}
	if got := complete("llmctl-decide", "ca"); !eq(got, "calibrate") {
		t.Errorf("ca<TAB> = %v", got)
	}
	if got := complete("llmctl-decide", "c"); !eq(got, "calibrate", "cert", "completions") {
		t.Errorf("c<TAB> = %v", got)
	}
	if got := complete("llmctl-decide", "probe"); !eq(got, "probe-order") {
		t.Errorf("probe<TAB> = %v", got)
	}
	if got := complete("llmctl-decide", "calibrate", "--me"); !eq(got, "--method") {
		t.Errorf("--me<TAB> = %v", got)
	}
	if got := complete("llmctl-decide", "calibrate", "--method", ""); !eq(got, "temperature", "platt", "isotonic") {
		t.Errorf("--method <TAB> = %v", got)
	}
	if got := complete("llmctl-decide", "completions", ""); !eq(got, "bash", "zsh") {
		t.Errorf("completions <TAB> = %v", got)
	}
	if got := complete("llmctl-decide", "schema", "--format", ""); !eq(got, "json-schema", "openai-tool", "mcp") {
		t.Errorf("--format <TAB> = %v", got)
	}
	if got := complete("llmctl-decide", "cert", ""); !eq(got, "doctor", "ensure", "export", "renew", "show") {
		t.Errorf("cert <TAB> = %v", got)
	}
	// the shell front end: `llmctl decide <TAB>` includes the words only the front end handles
	got := complete("llmctl", "decide", "")
	for _, w := range []string{"ask", "capacity", "status", "calibrate", "probe-order", "completions"} {
		found := false
		for _, g := range got {
			found = found || g == w
		}
		if !found {
			t.Errorf("llmctl decide <TAB> lacks %q: %v", w, got)
		}
	}
	if got := complete("llmctl", "plan", ""); len(got) != 0 {
		t.Errorf("llmctl plan <TAB> must complete nothing here (default file completion): %v", got)
	}
	if got := complete("llmctl", "decide", "ask", "--js"); !eq(got, "--json") {
		t.Errorf("llmctl decide ask --js<TAB> = %v", got)
	}
}

func TestZshScriptShape(t *testing.T) {
	_, s, _ := compRun("zsh")
	for _, want := range []string{"#compdef llmctl-decide", "_describe", "compdef _llmctl_decide llmctl-decide", "'calibrate:", "'probe-order:", "'completions:", "'--method:"} {
		if !strings.Contains(s, want) {
			t.Errorf("zsh script lacks %q", want)
		}
	}
	if zsh, err := exec.LookPath("zsh"); err == nil {
		cmd := exec.Command(zsh, "-n")
		cmd.Stdin = strings.NewReader(s)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Errorf("zsh -n: %v %s", err, out)
		}
	} else {
		t.Log("zsh is not installed on this host: the zsh script is checked structurally only, never executed")
	}
}

// Descriptions with quotes and brackets must not break zsh quoting.
func TestZshQuoting(t *testing.T) {
	if got := zshQuote("it's [a] test: ok"); got != `'it'\''s [a] test: ok'` {
		t.Errorf("zshQuote = %s", got)
	}
}
