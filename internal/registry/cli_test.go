package registry

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"testing"
)

type cliRun struct {
	out, err string
	code     int
}

func portCLI(args []string, env map[string]string) cliRun {
	var o, e bytes.Buffer
	c := RunPort(args, envOf(env), &o, &e)
	return cliRun{o.String(), e.String(), c}
}
func regCLI(args []string, env map[string]string) cliRun {
	var o, e bytes.Buffer
	c := RunRegistry(args, envOf(env), &o, &e)
	return cliRun{o.String(), e.String(), c}
}
func discCLI(args []string, env map[string]string) cliRun {
	var o, e bytes.Buffer
	c := RunDiscover(args, envOf(env), &o, &e)
	return cliRun{o.String(), e.String(), c}
}

func cliEnv(t *testing.T, extra map[string]string) map[string]string {
	env := map[string]string{"LLMCTL_STATE_DIR": t.TempDir()}
	for k, v := range extra {
		env[k] = v
	}
	return env
}

func TestPortCLIUsage(t *testing.T) {
	env := cliEnv(t, nil)
	for _, args := range [][]string{
		{}, {"bogus"}, {"allocate"}, {"allocate", "x", "--strategy", "random"}, {"allocate", "x", "--fixed", "abc"},
		{"release"}, {"allocate", "x", "--nosuchflag"}, {"allocate", "x"}, // fixed strategy without --fixed
	} {
		r := portCLI(args, env)
		if r.code != 2 {
			t.Errorf("%v: exit %d (stderr %q), want 2", args, r.code, r.err)
		}
		if !strings.Contains(r.err, "usage") && !strings.Contains(r.err, "error") {
			t.Errorf("%v: stderr should explain: %q", args, r.err)
		}
	}
}

func TestPortCLIAllocateAndRelease(t *testing.T) {
	env := cliEnv(t, nil)
	port := freePort(t)
	r := portCLI([]string{"allocate", "chat-fast", "--fixed", strconv.Itoa(port)}, env)
	if r.code != 0 || strings.TrimSpace(r.out) != strconv.Itoa(port) {
		t.Fatalf("%+v", r)
	}
	r = portCLI([]string{"allocate", "chat-fast", "--fixed", strconv.Itoa(port), "--json"}, env)
	var j PortResult
	if err := json.Unmarshal([]byte(r.out), &j); err != nil || j.Port != port || j.Strategy != "fixed" || j.Var != "LLMCTL_PORT_CHAT_FAST" {
		t.Fatalf("json: %v %+v", err, r)
	}
	if r = portCLI([]string{"release", "chat-fast"}, env); r.code != 0 {
		t.Fatalf("%+v", r)
	}
	if r = portCLI([]string{"release", "chat-fast"}, env); r.code != 0 {
		t.Fatalf("release must be idempotent: %+v", r)
	}
}

func TestPortCLITakenPortExitsWithNumberAndVariable(t *testing.T) {
	env := cliEnv(t, nil)
	port := freePort(t)
	listener(t, port)
	r := portCLI([]string{"allocate", "chat-fast", "--fixed", strconv.Itoa(port)}, env)
	if r.code != 1 || !strings.Contains(r.err, strconv.Itoa(port)) || !strings.Contains(r.err, "LLMCTL_PORT_CHAT_FAST") {
		t.Fatalf("%+v", r)
	}
	if r.out != "" {
		t.Fatalf("nothing on stdout on failure, got %q", r.out)
	}
}

func TestPortCLIDynamicViaEnvAndFlag(t *testing.T) {
	lo, hi := freePortBlock(t, 5)
	env := cliEnv(t, map[string]string{"LLMCTL_PORT_STRATEGY": "dynamic", "LLMCTL_PORT_RANGE": fmt.Sprintf("%d-%d", lo, hi)})
	r := portCLI([]string{"allocate", "a"}, env)
	p, err := strconv.Atoi(strings.TrimSpace(r.out))
	if r.code != 0 || err != nil || p < lo || p > hi {
		t.Fatalf("%+v", r)
	}
	// --strategy overrides the environment
	env2 := cliEnv(t, map[string]string{"LLMCTL_PORT_STRATEGY": "dynamic"})
	fixed := freePort(t)
	r = portCLI([]string{"allocate", "a", "--strategy", "fixed", "--fixed", strconv.Itoa(fixed)}, env2)
	if r.code != 0 || strings.TrimSpace(r.out) != strconv.Itoa(fixed) {
		t.Fatalf("%+v", r)
	}
	// list shows holds
	r = portCLI([]string{"list", "--json"}, env2)
	if r.code != 0 || !strings.Contains(r.out, strconv.Itoa(fixed)) {
		t.Fatalf("%+v", r)
	}
}

func TestRegistryCLIFullCycle(t *testing.T) {
	env := cliEnv(t, nil)
	p, e := startSvc(t, "decide-nli", false)
	reg := []string{"register", e.Name, "--port", strconv.Itoa(e.Port), "--pid", strconv.Itoa(p.pid()), "--token", e.CmdToken,
		"--protocol", "http", "--health-path", "/health", "--kind", "decision", "--profile", "decide-nli", "--instance", "1", "--loopback-only"}
	if r := regCLI(reg, env); r.code != 0 {
		t.Fatalf("%+v", r)
	}
	r := regCLI([]string{"list", "--json"}, env)
	var doc struct{ Services []Entry }
	if err := json.Unmarshal([]byte(r.out), &doc); err != nil || len(doc.Services) != 1 {
		t.Fatalf("%v %+v", err, r)
	}
	got := doc.Services[0]
	if got.Name != "decide-nli" || got.Labels["kind"] != "decision" || got.Labels["profile"] != "decide-nli" || got.Labels["instance"] != "1" || got.Labels["protocol"] != "http" || !got.LoopbackOnly {
		t.Fatalf("%+v", got)
	}
	// plain list: one row per service
	r = regCLI([]string{"list"}, env)
	if !strings.Contains(r.out, "decide-nli") || !strings.Contains(r.out, strconv.Itoa(e.Port)) {
		t.Fatalf("%q", r.out)
	}
	// diff equal -> 0 ; mismatch -> 1
	live := fmt.Sprintf("decide-nli=%d", p.pid())
	if r = regCLI([]string{"diff", "--live", live}, env); r.code != 0 {
		t.Fatalf("%+v", r)
	}
	if r = regCLI([]string{"diff", "--live", live + ",ghost=4242"}, env); r.code != 1 || !strings.Contains(r.out+r.err, "ghost") {
		t.Fatalf("%+v", r)
	}
	// reconcile keeps the live service, removes it after kill
	if r = regCLI([]string{"reconcile", "--grace", "1m"}, env); r.code != 0 {
		t.Fatalf("%+v", r)
	}
	p.kill()
	r = regCLI([]string{"reconcile", "--json"}, env)
	if r.code != 0 || !strings.Contains(r.out, "decide-nli") {
		t.Fatalf("%+v", r)
	}
	r = regCLI([]string{"list", "--json"}, env)
	_ = json.Unmarshal([]byte(r.out), &doc)
	if len(doc.Services) != 0 {
		t.Fatalf("%+v", r)
	}
	// unregister of a missing name is not an error
	if r = regCLI([]string{"unregister", "decide-nli"}, env); r.code != 0 {
		t.Fatalf("%+v", r)
	}
}

func TestRegistryCLIUsageErrors(t *testing.T) {
	env := cliEnv(t, nil)
	for _, args := range [][]string{
		{}, {"bogus"}, {"register"}, {"register", "x"}, {"register", "x", "--port", "8000"},
		{"register", "x", "--port", "abc", "--pid", "5", "--token", "t"},
		{"register", "x", "--port", "8000", "--pid", "1", "--token", "t"},
		{"unregister"}, {"diff"}, {"diff", "--live", "nopid"}, {"reconcile", "--grace", "soon"},
	} {
		if r := regCLI(args, env); r.code != 2 {
			t.Errorf("%v: exit %d (%q)", args, r.code, r.err)
		}
	}
}

func TestDiscoverCLI(t *testing.T) {
	env := cliEnv(t, nil)
	_, a := startSvc(t, "a", false)
	pb, b := startSvc(t, "b", false)
	b.Labels["kind"] = "encoder"
	b.Protocol = "https"
	for _, e := range []Entry{a, b} {
		if r := regCLI([]string{"register", e.Name, "--port", strconv.Itoa(e.Port), "--pid", strconv.Itoa(e.PID), "--token", e.CmdToken, "--protocol", e.Protocol, "--kind", e.Labels["kind"]}, env); r.code != 0 {
			t.Fatalf("%+v", r)
		}
	}
	_ = pb
	r := discCLI([]string{"--json"}, env)
	var doc struct {
		Services []struct {
			Name    string            `json:"name"`
			URL     string            `json:"url"`
			Healthy bool              `json:"healthy"`
			Labels  map[string]string `json:"labels"`
		} `json:"services"`
	}
	if err := json.Unmarshal([]byte(r.out), &doc); err != nil || len(doc.Services) != 2 {
		t.Fatalf("%v %q", err, r.out)
	}
	if doc.Services[0].URL != fmt.Sprintf("http://127.0.0.1:%d", a.Port) || doc.Services[1].URL != fmt.Sprintf("https://127.0.0.1:%d", b.Port) {
		t.Fatalf("urls %+v", doc.Services)
	}
	r = discCLI([]string{"--kind", "encoder", "--json"}, env)
	_ = json.Unmarshal([]byte(r.out), &doc)
	if len(doc.Services) != 1 || doc.Services[0].Name != "b" {
		t.Fatalf("%+v", doc)
	}
	r = discCLI([]string{"--label", "kind=nothing"}, env)
	if r.code != 0 || strings.Contains(r.out, "http") {
		t.Fatalf("%+v", r)
	}
	r = discCLI(nil, env)
	for _, must := range []string{"NAME", "URL", "HEALTH", "a", "b", "kind=decision"} {
		if !strings.Contains(r.out, must) {
			t.Errorf("table lacks %q:\n%s", must, r.out)
		}
	}
	// never prints key material
	env["LLMCTL_DECIDE_API_KEY"] = "sk-SECRET-VALUE"
	r = discCLI([]string{"--json"}, env)
	if strings.Contains(r.out+r.err, "SECRET") {
		t.Fatal("discover leaked a key")
	}
	if r = discCLI([]string{"--label", "novalue"}, env); r.code != 2 {
		t.Fatalf("bad --label must be a usage error: %+v", r)
	}
}

func TestDiscoverShowsLoopbackAndKeyFileFlags(t *testing.T) {
	env := cliEnv(t, nil)
	hold := spawn(t, "hold", "tok-disc")
	good := t.TempDir() + "/k"
	if err := os.WriteFile(good, []byte("SECRET-VALUE\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	reg := func(name, keyFile string, loop bool) {
		args := []string{"register", name, "--port", strconv.Itoa(freePort(t)), "--pid", strconv.Itoa(hold.pid()), "--token", "tok-disc", "--kind", "decide", "--profile", "decide-tiny"}
		if keyFile != "" {
			args = append(args, "--label", LabelKeyFile+"="+keyFile)
		}
		if loop {
			args = append(args, "--loopback-only")
		}
		if r := regCLI(args, env); r.code != 0 {
			t.Fatalf("%v: %+v", args, r)
		}
	}
	reg("with-key", good, true)
	reg("lost-key", "/nonexistent/key", true)
	reg("no-key", "", false)

	table := discCLI(nil, env)
	if table.code != 0 || !strings.Contains(table.out, "LOOPBACK") || !strings.Contains(table.out, "KEY") {
		t.Fatalf("table lacks the columns: %+v", table)
	}
	row := func(name string) string {
		for _, l := range strings.Split(table.out, "\n") {
			if strings.HasPrefix(l, name+" ") {
				return l
			}
		}
		t.Fatalf("no row for %s in %q", name, table.out)
		return ""
	}
	if f := strings.Fields(row("with-key")); f[4] != "yes" || f[5] != "ok" {
		t.Fatalf("with-key row: %v", f)
	}
	if f := strings.Fields(row("lost-key")); f[4] != "yes" || f[5] != "MISSING" {
		t.Fatalf("lost-key row: %v", f)
	}
	if f := strings.Fields(row("no-key")); f[4] != "no" || f[5] != "-" {
		t.Fatalf("no-key row: %v", f)
	}
	js := discCLI([]string{"--json"}, env)
	var doc struct {
		Services []struct {
			Name           string `json:"name"`
			LoopbackOnly   bool   `json:"loopback_only"`
			KeyFileNamed   bool   `json:"key_file_named"`
			KeyFilePresent bool   `json:"key_file_present"`
		} `json:"services"`
	}
	if err := json.Unmarshal([]byte(js.out), &doc); err != nil {
		t.Fatal(err)
	}
	want := map[string][3]bool{"with-key": {true, true, true}, "lost-key": {true, true, false}, "no-key": {false, false, false}}
	for _, s := range doc.Services {
		w := want[s.Name]
		if s.LoopbackOnly != w[0] || s.KeyFileNamed != w[1] || s.KeyFilePresent != w[2] {
			t.Errorf("%s: %+v want %v", s.Name, s, w)
		}
	}
	if strings.Contains(table.out+js.out, "SECRET-VALUE") {
		t.Fatal("discover printed key material")
	}
}
