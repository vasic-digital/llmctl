package registry

import (
	"strconv"
	"strings"
	"testing"
)

func TestStateDirFlagOverridesEnvironment(t *testing.T) {
	other := t.TempDir()
	env := cliEnv(t, nil)
	port := freePort(t)
	if r := portCLI([]string{"allocate", "a", "--fixed", strconv.Itoa(port), "--state-dir", other}, env); r.code != 0 {
		t.Fatalf("%+v", r)
	}
	r := portCLI([]string{"list", "--state-dir", other}, env)
	if !strings.Contains(r.out, "a\t"+strconv.Itoa(port)) {
		t.Fatalf("%+v", r)
	}
	if r := portCLI([]string{"list"}, env); strings.Contains(r.out, "a\t") {
		t.Fatalf("hold leaked into the default state dir: %+v", r)
	}
}

func TestBadEnvironmentIsUsageError(t *testing.T) {
	env := cliEnv(t, map[string]string{"LLMCTL_PORT_STRATEGY": "chaos"})
	for _, r := range []cliRun{portCLI([]string{"list"}, env), regCLI([]string{"list"}, env), discCLI(nil, env)} {
		if r.code != 2 || !strings.Contains(r.err, "LLMCTL_PORT_STRATEGY") {
			t.Errorf("%+v", r)
		}
	}
	env = cliEnv(t, map[string]string{"LLMCTL_PORT_CHAT": "banana"})
	if r := portCLI([]string{"allocate", "chat", "--fixed", "8000"}, env); r.code != 2 || !strings.Contains(r.err, "LLMCTL_PORT_CHAT") {
		t.Errorf("%+v", r)
	}
}

func TestRegistryDiffEmptyLiveSetAndJSON(t *testing.T) {
	env := cliEnv(t, nil)
	if r := regCLI([]string{"diff", "--live", ""}, env); r.code != 0 || !strings.Contains(r.out, "registry == live set") {
		t.Fatalf("%+v", r)
	}
	if r := regCLI([]string{"diff", "--live", "", "--json"}, env); r.code != 0 || !strings.Contains(r.out, `"registry_only": []`) {
		t.Fatalf("%+v", r)
	}
}

func TestMatchToken(t *testing.T) {
	for _, c := range []struct {
		name string
		args []string
		i    int
		tok  string
		want bool
	}{
		{"argv0 equals token", []string{"llama-server"}, 0, "llama-server", true},
		{"argv0 path basename", []string{"/opt/x/bin/llama-server"}, 0, "llama-server", true},
		{"--name flag form", []string{"x", "--name=decide-nli"}, 1, "decide-nli", true},
		{"--model path flag form", []string{"x", "--model=/m/decide-nli"}, 1, "decide-nli", true},
		{"exact marker anywhere", []string{"x", "__helper", "tok"}, 2, "tok", true},
		{"interpreter + script", []string{"/usr/bin/python3", "/opt/lib/onnx_server.py"}, 1, "onnx_server.py", true},
		{"carrier sentence", []string{"sleep 300; : tok"}, 0, "tok", false},
		{"longer name", []string{"llama-server-extra"}, 0, "llama-server", false},
		{"prefixed name", []string{"prefix-llama-server"}, 0, "llama-server", false},
		{"not a flag", []string{"x", "name=decide-nli"}, 1, "decide-nli", false},
		// C-01: a path ARGUMENT whose basename is the token is a carrier (tail -f, vim, cat ...)
		{"tail -f path argument", []string{"tail", "-f", "/var/log/llama-server"}, 2, "llama-server", false},
		{"editor path argument", []string{"vim", "/home/u/llama-server"}, 1, "llama-server", false},
		{"non-interpreter argv1", []string{"/usr/bin/less", "/opt/lib/onnx_server.py"}, 1, "onnx_server.py", false},
	} {
		if got := matchToken(c.args[c.i], c.tok, c.i, c.args); got != c.want {
			t.Errorf("%s: matchToken(%q, %q, %d)=%v want %v", c.name, c.args, c.tok, c.i, got, c.want)
		}
	}
}

func TestPortTakenErrorNamesHolder(t *testing.T) {
	e := &PortTakenError{Name: "b", Port: 8000, Var: "LLMCTL_PORT_B", Holder: "a"}
	if !strings.Contains(e.Error(), `"a"`) || !strings.Contains(e.Error(), "8000") {
		t.Fatal(e.Error())
	}
}
