package certs

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDamagedStateIsReportedNotRepaired(t *testing.T) {
	home := newHome(t)
	info := mustEnsure(t, opts(home))
	cases := []struct {
		name   string
		damage func()
		want   string
	}{
		{"garbage leaf cert", func() { _ = os.WriteFile(info.LeafCert, []byte("junk"), 0o644) }, "PEM"},
		{"garbage leaf key", func() { _ = os.WriteFile(info.LeafKey, []byte("junk"), 0o600) }, "private key"},
		{"missing CA cert", func() { _ = os.Remove(info.CACert) }, "damaged"},
	}
	for _, c := range cases {
		h := newHome(t)
		i := mustEnsure(t, opts(h))
		switch c.name {
		case "garbage leaf cert":
			_ = os.WriteFile(i.LeafCert, []byte("junk"), 0o644)
		case "garbage leaf key":
			_ = os.WriteFile(i.LeafKey, []byte("junk"), 0o600)
		case "missing CA cert":
			_ = os.Remove(i.CACert)
		}
		if _, err := Ensure(opts(h)); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: %v", c.name, err)
		}
		if _, err := Show(opts(h)); err == nil {
			t.Errorf("%s: show accepted damage", c.name)
		}
	}
	_ = info
}

func TestParseHelpersRejectNonsense(t *testing.T) {
	d := t.TempDir()
	// a file with only non-key PEM blocks
	p := filepath.Join(d, "x.pem")
	_ = os.WriteFile(p, []byte("-----BEGIN EC PARAMETERS-----\nBggqhkjOPQMBBw==\n-----END EC PARAMETERS-----\n"), 0o600)
	if _, err := parseKeyFile(p, false); err == nil {
		t.Error("EC PARAMETERS only is not a key")
	}
	if _, err := parseKeyFile(filepath.Join(d, "absent"), false); err == nil {
		t.Error("absent key")
	}
	_ = os.WriteFile(p, []byte("-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n"), 0o600)
	if _, err := parseKeyFile(p, false); err == nil {
		t.Error("corrupt PKCS8")
	}
	_ = os.WriteFile(p, []byte("-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n"), 0o600)
	if _, err := parseCertFile(p); err == nil {
		t.Error("corrupt certificate")
	}
	if _, err := parseCertFile(filepath.Join(d, "absent")); err == nil {
		t.Error("absent certificate")
	}
	// first non-certificate block is skipped, the certificate after it is used
	home := newHome(t)
	info := mustEnsure(t, opts(home))
	b, _ := os.ReadFile(info.LeafCert)
	_ = os.WriteFile(p, append([]byte("-----BEGIN EC PARAMETERS-----\nBggqhkjOPQMBBw==\n-----END EC PARAMETERS-----\n"), b...), 0o644)
	if _, err := parseCertFile(p); err != nil {
		t.Errorf("leading non-cert block: %v", err)
	}
}

func TestUnusableHomeIsAnErrorNotAPanic(t *testing.T) {
	d := t.TempDir()
	file := filepath.Join(d, "afile")
	_ = os.WriteFile(file, []byte("x"), 0o644)
	// home is a regular file: cert dir cannot be created
	if _, err := Ensure(opts(file)); err == nil {
		t.Error("home that is a file accepted")
	}
	if _, err := Ensure(Options{}); err == nil {
		t.Error("empty home accepted")
	}
	// cert dir exists but `ca` is a file
	home := newHome(t)
	_ = os.MkdirAll(filepath.Join(home, "cert"), 0o700)
	_ = os.WriteFile(filepath.Join(home, "cert", "ca"), []byte("x"), 0o644)
	if _, err := Ensure(opts(home)); err == nil {
		t.Error("blocked ca dir accepted")
	}
	if _, err := ExportCA(home, filepath.Join(file, "sub", "ca.crt")); err == nil {
		t.Error("export under a file accepted")
	}
}

func TestLooseCertDirIsTightenedByMutatingCommands(t *testing.T) {
	home := newHome(t)
	mustEnsure(t, opts(home))
	cert := filepath.Join(home, "cert")
	_ = os.Chmod(cert, 0o755)
	mustEnsure(t, opts(home))
	if m := modeOf(t, cert); m != 0o700 {
		t.Errorf("ensure left the directory at %o", m)
	}
}

func TestRenewWithoutAnythingAndUnknownMode(t *testing.T) {
	home := newHome(t)
	if _, err := Renew(opts(home)); err == nil || !strings.Contains(err.Error(), "ensure") {
		t.Errorf("renew with nothing: %v", err)
	}
	o := opts(home)
	o.Mode = "weird"
	if _, err := Renew(o); err == nil {
		t.Error("unknown mode accepted")
	}
	mustEnsure(t, opts(home))
	bad := opts(home)
	bad.SANs = "ip:zzz"
	if _, err := Renew(bad); err == nil {
		t.Error("bad SAN accepted by renew")
	}
}

func TestOfflineExportRefusesUnwritableDest(t *testing.T) {
	d := t.TempDir()
	file := filepath.Join(d, "afile")
	_ = os.WriteFile(file, []byte("x"), 0o644)
	home := newHome(t)
	o := opts(home)
	o.OfflineCAKeyTo = filepath.Join(file, "ca.key")
	if _, err := Ensure(o); err == nil {
		t.Fatal("unwritable offline destination accepted")
	}
	if _, err := os.Stat(filepath.Join(home, "cert", "ca", "ca.key")); err != nil {
		t.Error("CA key must stay on the host when the export failed")
	}
}

func TestCLIHelpAndOddPaths(t *testing.T) {
	var o, e bytes.Buffer
	if rc := Run([]string{"-h"}, &o, &e); rc != 0 || !strings.Contains(o.String(), "usage: llmctl cert") {
		t.Errorf("-h rc=%d %q %q", rc, o.String(), e.String())
	}
	o.Reset()
	e.Reset()
	if rc := Run([]string{"ensure", "-h"}, &o, &e); rc != 0 {
		t.Errorf("ensure -h rc=%d", rc)
	}
	// export with an unreadable CA (selfsigned has none) is a cert problem, exit 5
	home := newHome(t)
	rc, _, _ := run(t, home, "ensure", "--mode", "selfsigned")
	if rc != 0 {
		t.Fatal("ensure selfsigned")
	}
	if rc, _, e := run(t, home, "export", filepath.Join(t.TempDir(), "x")); rc != 5 || !strings.Contains(e, "no CA certificate") {
		t.Errorf("export rc=%d %q", rc, e)
	}
	rc, out, _ := run(t, home, "show")
	if rc != 0 || !strings.Contains(out, "selfsigned") {
		t.Errorf("show selfsigned rc=%d %q", rc, out)
	}
}

func TestCLIByoShowAndDoctor(t *testing.T) {
	home := newHome(t)
	writeBYO(t, home, false, false, false)
	rc, out, _ := run(t, home, "show")
	if rc != 0 || !strings.Contains(out, "byo") || !strings.Contains(out, "none") {
		t.Errorf("show byo rc=%d %q", rc, out)
	}
	rc, out, _ = run(t, home, "ensure")
	if rc != 0 || !strings.Contains(out, "mode=byo version=none") {
		t.Errorf("ensure byo rc=%d %q", rc, out)
	}
	if rc, _, _ = run(t, home, "doctor"); rc != 0 {
		t.Errorf("doctor byo rc=%d", rc)
	}
}
