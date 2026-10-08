package registry

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestConfigFromEnv(t *testing.T) {
	old := currentUID
	currentUID = func() int { return 1000 }
	defer func() { currentUID = old }()
	cases := []struct {
		name    string
		env     map[string]string
		want    Config
		wantErr string
	}{
		{"defaults from HOME", map[string]string{"HOME": "/h"}, Config{StateDir: "/h/.local/state/llmctl", Strategy: Fixed, RangeLo: 20000, RangeHi: 20999}, ""},
		{"XDG_STATE_HOME", map[string]string{"HOME": "/h", "XDG_STATE_HOME": "/x"}, Config{StateDir: "/x/llmctl", Strategy: Fixed, RangeLo: 20000, RangeHi: 20999}, ""},
		{"explicit state dir wins", map[string]string{"HOME": "/h", "XDG_STATE_HOME": "/x", "LLMCTL_STATE_DIR": "/s"}, Config{StateDir: "/s", Strategy: Fixed, RangeLo: 20000, RangeHi: 20999}, ""},
		{"dynamic + range", map[string]string{"LLMCTL_STATE_DIR": "/s", "LLMCTL_PORT_STRATEGY": "dynamic", "LLMCTL_PORT_RANGE": "21000-21099"}, Config{StateDir: "/s", Strategy: Dynamic, RangeLo: 21000, RangeHi: 21099}, ""},
		{"fixed spelled out", map[string]string{"LLMCTL_STATE_DIR": "/s", "LLMCTL_PORT_STRATEGY": "fixed"}, Config{StateDir: "/s", Strategy: Fixed, RangeLo: 20000, RangeHi: 20999}, ""},
		{"bad strategy", map[string]string{"LLMCTL_STATE_DIR": "/s", "LLMCTL_PORT_STRATEGY": "random"}, Config{}, "LLMCTL_PORT_STRATEGY"},
		{"bad range text", map[string]string{"LLMCTL_STATE_DIR": "/s", "LLMCTL_PORT_RANGE": "abc"}, Config{}, "LLMCTL_PORT_RANGE"},
		{"inverted range", map[string]string{"LLMCTL_STATE_DIR": "/s", "LLMCTL_PORT_RANGE": "21099-21000"}, Config{}, "LLMCTL_PORT_RANGE"},
		{"privileged range", map[string]string{"LLMCTL_STATE_DIR": "/s", "LLMCTL_PORT_RANGE": "80-90"}, Config{}, "LLMCTL_PORT_RANGE"},
		{"range above 65535", map[string]string{"LLMCTL_STATE_DIR": "/s", "LLMCTL_PORT_RANGE": "65000-70000"}, Config{}, "LLMCTL_PORT_RANGE"},
		{"no home no state", map[string]string{}, Config{}, "LLMCTL_STATE_DIR"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := ConfigFromEnv(envOf(c.env))
			if c.wantErr != "" {
				if err == nil || !contains(err.Error(), c.wantErr) {
					t.Fatalf("want error mentioning %q, got %v", c.wantErr, err)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			got.CACert = "" // covered by TestConfigCACert
			if got != c.want {
				t.Fatalf("got %+v want %+v", got, c.want)
			}
		})
	}
}

func TestProfileVar(t *testing.T) {
	for in, want := range map[string]string{
		"chat-fast":   "LLMCTL_PORT_CHAT_FAST",
		"decide.nli":  "LLMCTL_PORT_DECIDE_NLI",
		"Vision":      "LLMCTL_PORT_VISION",
		"gateway":     "LLMCTL_PORT_GATEWAY",
		"a b/c":       "LLMCTL_PORT_A_B_C",
		"chat-fast.2": "LLMCTL_PORT_CHAT_FAST_2",
	} {
		if got := ProfileVar(in); got != want {
			t.Errorf("ProfileVar(%q)=%q want %q", in, got, want)
		}
	}
}

func TestConfigDirs(t *testing.T) {
	c := Config{StateDir: "/s"}
	if got, want := c.Dir(), filepath.Join("/s", "registry"); got != want {
		t.Fatalf("Dir=%q want %q", got, want)
	}
}

func contains(s, sub string) bool { return strings.Contains(s, sub) }

func TestConfigCACert(t *testing.T) {
	for name, tc := range map[string]struct {
		env  map[string]string
		want string
	}{
		"explicit wins":  {map[string]string{"HOME": "/h", "LLMCTL_HOME": "/lh", "LLMCTL_CACERT": "/c/ca.crt"}, "/c/ca.crt"},
		"llmctl home":    {map[string]string{"HOME": "/h", "LLMCTL_HOME": "/lh"}, "/lh/cert/ca/ca.crt"},
		"home default":   {map[string]string{"HOME": "/h"}, "/h/llmctl/cert/ca/ca.crt"},
		"nothing to use": {map[string]string{"LLMCTL_STATE_DIR": "/s"}, ""},
	} {
		env := map[string]string{"LLMCTL_STATE_DIR": "/s"}
		for k, v := range tc.env {
			env[k] = v
		}
		got, err := ConfigFromEnv(envOf(env))
		if err != nil || got.CACert != tc.want {
			t.Errorf("%s: CACert=%q want %q (%v)", name, got.CACert, tc.want, err)
		}
	}
}
