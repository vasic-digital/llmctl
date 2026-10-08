package certs

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// run drives the real CLI entry in-process with hermetic names/addresses.
func run(t *testing.T, home string, args ...string) (int, string, string) {
	t.Helper()
	t.Setenv("LLMCTL_TLS_SAN", "")
	t.Setenv("LLMCTL_TLS_MODE", "")
	t.Setenv("LLMCTL_CA_NAME_CONSTRAINTS", "")
	full := append([]string{"--home", home, "--hostname", "testhost", "--address", "192.168.1.115"}, args...)
	var o, e bytes.Buffer
	rc := Run(full, &o, &e)
	return rc, o.String(), e.String()
}

func TestCLIUsageErrorsExit2(t *testing.T) {
	home := newHome(t)
	for _, args := range [][]string{
		nil,
		{"bogus"},
		{"--nope", "ensure"},
		{"ensure", "--nope"},
		{"export"},
		{"export", "a", "b"},
		{"ensure", "--mode", "weird"},
		{"--now", "abc", "ensure"},
		{"show", "extra"},
	} {
		var o, e bytes.Buffer
		if rc := Run(append([]string{"--home", home}, args...), &o, &e); rc != 2 {
			t.Errorf("args %v: rc=%d want 2 (stderr %q)", args, rc, e.String())
		}
	}
	var o, e bytes.Buffer
	if rc := Run(nil, &o, &e); rc != 2 {
		t.Errorf("no args rc=%d", rc)
	}
}

func TestCLIEnsureIdempotentAndQuiet(t *testing.T) {
	home := newHome(t)
	rc, out, errOut := run(t, home, "ensure")
	if rc != 0 || !strings.Contains(out, "issued mode=ca-leaf version=1 created=true") {
		t.Fatalf("rc=%d out=%q err=%q", rc, out, errOut)
	}
	if !strings.Contains(out, "leaf_sha256 ") {
		t.Errorf("no fingerprint line: %q", out)
	}
	if strings.Contains(out+errOut, "PRIVATE") {
		t.Error("ensure printed key material")
	}
	before := listNames(t, filepath.Join(home, "cert"))
	rc, out, _ = run(t, home, "ensure")
	if rc != 0 || !strings.Contains(out, "ok mode=ca-leaf version=1 created=false") {
		t.Errorf("second ensure: rc=%d out=%q", rc, out)
	}
	if strings.Join(before, ",") != strings.Join(listNames(t, filepath.Join(home, "cert")), ",") {
		t.Error("second ensure changed the directory")
	}
}

func TestCLIFlagsBeforeAndAfterSubcommand(t *testing.T) {
	home := newHome(t)
	var o, e bytes.Buffer
	rc := Run([]string{"ensure", "--home", home, "--hostname", "testhost", "--address", "192.168.1.115"}, &o, &e)
	if rc != 0 {
		t.Fatalf("rc=%d %s", rc, e.String())
	}
	if _, err := os.Stat(filepath.Join(home, "cert", "current")); err != nil {
		t.Error(err)
	}
}

func TestCLIDefaultHomeFromEnv(t *testing.T) {
	home := newHome(t)
	t.Setenv("LLMCTL_HOME", home)
	var o, e bytes.Buffer
	if rc := Run([]string{"--hostname", "testhost", "--address", "192.168.1.115", "ensure"}, &o, &e); rc != 0 {
		t.Fatalf("rc=%d %s", rc, e.String())
	}
	if _, err := os.Stat(filepath.Join(home, "cert", "ca", "ca.crt")); err != nil {
		t.Error("LLMCTL_HOME ignored")
	}
}

func TestCLIShowDoctorExport(t *testing.T) {
	home := newHome(t)
	run(t, home, "ensure")
	rc, out, _ := run(t, home, "show")
	if rc != 0 || !strings.Contains(out, "leaf_sha256") || !strings.Contains(out, "ca-leaf") {
		t.Errorf("show: rc=%d %q", rc, out)
	}
	rc, out, _ = run(t, home, "show", "--json")
	var m map[string]any
	if rc != 0 || json.Unmarshal([]byte(out), &m) != nil || m["mode"] != "ca-leaf" || m["leaf_sha256"] == "" {
		t.Errorf("show --json: rc=%d %q", rc, out)
	}
	if strings.Contains(out, "PRIVATE") {
		t.Error("key material in show")
	}
	rc, out, _ = run(t, home, "doctor")
	if rc != 0 || !strings.Contains(out, "OK") {
		t.Errorf("doctor: rc=%d %q", rc, out)
	}
	rc, out, _ = run(t, home, "doctor", "--json")
	var rep Report
	if rc != 0 || json.Unmarshal([]byte(out), &rep) != nil || !rep.OK {
		t.Errorf("doctor --json: rc=%d %q", rc, out)
	}
	dest := filepath.Join(t.TempDir(), "pub", "ca.crt")
	rc, out, _ = run(t, home, "export", dest)
	if rc != 0 || strings.TrimSpace(out) != dest || modeOf(t, dest) != 0o644 {
		t.Errorf("export: rc=%d %q", rc, out)
	}
	_ = os.Chmod(filepath.Join(home, "cert", "ca", "ca.key"), 0o644)
	if rc, _, _ = run(t, home, "doctor"); rc != 5 {
		t.Errorf("doctor with loose CA key: rc=%d want 5", rc)
	}
}

func TestCLIRenewAndOfflineKey(t *testing.T) {
	home := newHome(t)
	dest := filepath.Join(t.TempDir(), "usb", "ca.key")
	if rc, _, e := run(t, home, "ensure", "--offline-ca-key", dest); rc != 0 {
		t.Fatalf("ensure offline: %s", e)
	}
	rc, _, e := run(t, home, "renew")
	if rc != 5 || !strings.Contains(e, "offline") {
		t.Errorf("renew w/o key: rc=%d %q", rc, e)
	}
	rc, out, e := run(t, home, "renew", "--ca-key", dest, "--reuse-key")
	if rc != 0 || !strings.Contains(out, "issued mode=ca-leaf version=2 created=true") {
		t.Errorf("renew: rc=%d %q %q", rc, out, e)
	}
	if tgt, _ := os.Readlink(filepath.Join(home, "cert", "current")); tgt != "v-2" {
		t.Errorf("current -> %s", tgt)
	}
}

func TestCLIExpiredExit5(t *testing.T) {
	home := newHome(t)
	run(t, home, "ensure")
	future := fmt.Sprint(time.Now().Add(400 * 24 * time.Hour).Unix())
	rc, _, e := run(t, home, "--now", future, "ensure")
	if rc != 5 || !strings.Contains(e, "expired") {
		t.Errorf("rc=%d %q", rc, e)
	}
}

func TestCLIWarningsOnStderr(t *testing.T) {
	home := newHome(t)
	var o, e bytes.Buffer
	rc := Run([]string{"--home", home, "--hostname", "testhost", "--address", "8.8.8.8", "ensure"}, &o, &e)
	if rc != 0 || !strings.Contains(e.String(), "WARNING:") || strings.Contains(o.String(), "WARNING") {
		t.Errorf("rc=%d out=%q err=%q", rc, o.String(), e.String())
	}
}

func TestCLIPlacementRefusalExit5(t *testing.T) {
	repo := gitInit(t)
	rc, _, e := run(t, filepath.Join(repo, "llmctl"), "ensure")
	if rc != 5 || !strings.Contains(e, "git work tree") {
		t.Errorf("rc=%d %q", rc, e)
	}
}

func TestCLINoCertsShowExit5(t *testing.T) {
	if rc, _, _ := run(t, newHome(t), "show"); rc != 5 {
		t.Errorf("rc=%d", rc)
	}
}
