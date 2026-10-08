package main

import (
	"flag"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"

	"github.com/vasic-digital/llmctl/llmctld/internal/mtls"
)

// G-106 (OD-21 / T131): TLS material for the llmctl shell CLI.
//
// lib/cluster.sh reaches this daemon with curl over HTTP/3 and full
// verification. That needs three things the daemon previously did not give
// it: a server certificate that carries SANs (mtls.IssueNodeCert, sans.go),
// a client certificate/key issued by the same CA (this file), and a trust
// anchor to hand to curl --cacert (ca.crt, also written here). The daemon
// writes all three into a dedicated 0700 directory on bootstrap/join, so the
// CA PRIVATE key never leaves the -ca-key path and is never copied next to
// the material a CLI user reads.

const cliCertName = "llmctl-cli"

// splitList splits a comma-separated flag value.
func splitList(v string) []string {
	var out []string
	for _, p := range strings.Split(v, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// configureCertSANs registers the operator-visible names every certificate
// issued by this process must carry, on top of the always-present loopback
// and hostname names: the host part of apiBind (unless it is a wildcard)
// and every advertised name/IP.
func configureCertSANs(apiBind string, advertise []string) error {
	names := append([]string(nil), advertise...)
	if apiBind != "" {
		host, _, err := net.SplitHostPort(apiBind)
		if err != nil {
			return fmt.Errorf("invalid -api-bind %q: %w", apiBind, err)
		}
		names = append(names, host)
	}
	mtls.SetExtraSANs(names...)
	return nil
}

// resolveCLICertDir returns the explicit directory or, by default, a "cli"
// directory next to the CA certificate.
func resolveCLICertDir(explicit, caCertPath string) string {
	if explicit != "" {
		return explicit
	}
	return filepath.Join(filepath.Dir(caCertPath), "cli")
}

// writeCLIMaterial writes ca.crt, client.crt and client.key into dir
// (created 0700; an existing directory is tightened to 0700). Every file is
// 0600 and replaced atomically (temp file + rename), so a reader never sees
// a half-written key. Only the CA CERTIFICATE is written - never ca's key.
func writeCLIMaterial(dir string, ca *mtls.CA) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create %s: %w", dir, err)
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return fmt.Errorf("chmod %s: %w", dir, err)
	}
	cc, err := ca.IssueClientCert(cliCertName)
	if err != nil {
		return err
	}
	for _, f := range []struct {
		name string
		data []byte
	}{{"ca.crt", ca.CertPEM}, {"client.crt", cc.CertPEM}, {"client.key", cc.KeyPEM}} {
		if err := writeFile0600(filepath.Join(dir, f.name), f.data); err != nil {
			return err
		}
	}
	return nil
}

func writeFile0600(path string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tmp-*")
	if err != nil {
		return fmt.Errorf("create temp for %s: %w", path, err)
	}
	tmpName := tmp.Name()
	cleanup := func() { _ = os.Remove(tmpName) }
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		cleanup()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		cleanup()
		return err
	}
	if err := tmp.Close(); err != nil {
		cleanup()
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		cleanup()
		return err
	}
	return nil
}

// runClusterIssueCLICert re-issues the CLI client certificate for an
// existing CA (e.g. after a CA rotation, or when client.crt expired):
//
//	llmctld cluster issue-cli-cert -ca-cert ca.crt -ca-key ca.key [-out-dir DIR]
func runClusterIssueCLICert(args []string) int {
	fs := flag.NewFlagSet("cluster issue-cli-cert", flag.ContinueOnError)
	var caCert, caKey, outDir string
	fs.StringVar(&caCert, "ca-cert", "", "path to the cluster CA certificate PEM (required)")
	fs.StringVar(&caKey, "ca-key", "", "path to the cluster CA private key PEM (required)")
	fs.StringVar(&outDir, "out-dir", "", "directory to write ca.crt/client.crt/client.key into (default: a \"cli\" directory next to -ca-cert)")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if caCert == "" || caKey == "" {
		fmt.Fprintln(os.Stderr, "llmctld: -ca-cert and -ca-key are required")
		return 2
	}
	certPEM, err := os.ReadFile(caCert)
	if err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster issue-cli-cert: read CA cert:", err)
		return 1
	}
	keyPEM, err := os.ReadFile(caKey)
	if err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster issue-cli-cert: read CA key:", err)
		return 1
	}
	ca, err := mtls.LoadCA(certPEM, keyPEM)
	if err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster issue-cli-cert: load CA:", err)
		return 1
	}
	dir := resolveCLICertDir(outDir, caCert)
	if err := writeCLIMaterial(dir, ca); err != nil {
		fmt.Fprintln(os.Stderr, "llmctld: cluster issue-cli-cert:", err)
		return 1
	}
	fmt.Printf("CLI_CERT_DIR=%s\n", dir)
	return 0
}
