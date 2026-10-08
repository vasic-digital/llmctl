package registry

import (
	"crypto/x509"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// LabelCAFile is the registry label under which a TLS service records the path of the CA that
// certifies it, so a reconciler running without the service's environment (a cron job, a shell
// with another LLMCTL_HOME) still verifies against the right CA (G-068).
const LabelCAFile = "ca_file"

// ResolveCA is the ONE place the llmctl CA certificate path is resolved for every consumer (the
// registry reconciler, the gateway's published label, the ask client): LLMCTL_CACERT, else
// $LLMCTL_HOME/cert/ca/ca.crt with LLMCTL_HOME defaulting to $HOME/llmctl. It returns "" when
// neither LLMCTL_CACERT, LLMCTL_HOME nor HOME is known. get is os.Getenv or a map lookup.
func ResolveCA(get func(string) string) string {
	switch {
	case get("LLMCTL_CACERT") != "":
		return get("LLMCTL_CACERT")
	case get("LLMCTL_HOME") != "":
		return filepath.Join(get("LLMCTL_HOME"), "cert", "ca", "ca.crt")
	case get("HOME") != "":
		return filepath.Join(get("HOME"), "llmctl", "cert", "ca", "ca.crt")
	}
	return ""
}

// caNotFound marks "no usable CA certificate": the https entry cannot be certified, which is not
// the same as the service being unhealthy.
type caNotFound struct{ msg string }

func (e *caNotFound) Error() string { return e.msg }

// trustedCAFile reports whether a CA path read from a registry label may be trusted: a regular
// file owned by the current user that is not world-writable. A label is attacker-controllable
// data (any local process can register), so it never names a file the user does not own.
func trustedCAFile(path string) error {
	st, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("%s: %v", path, err)
	}
	if !st.Mode().IsRegular() {
		return fmt.Errorf("%s is not a regular file", path)
	}
	if sys, ok := st.Sys().(*syscall.Stat_t); ok && int(sys.Uid) != currentUID() {
		return fmt.Errorf("%s is not owned by the current user", path)
	}
	if st.Mode().Perm()&0o002 != 0 {
		return fmt.Errorf("%s is world-writable", path)
	}
	return nil
}

// pickCA returns the CA pool an https entry is verified against: its ca_file label when that file
// is trusted and loads, else the configured CA. Neither usable is a *caNotFound.
func (r *Registry) pickCA(e Entry) (*x509.CertPool, error) {
	var why []string
	if lp := e.Labels[LabelCAFile]; lp != "" {
		if err := trustedCAFile(lp); err != nil {
			why = append(why, "ignoring the ca_file label: "+err.Error())
		} else if pool, err := loadCAPool(lp); err == nil {
			return pool, nil
		} else {
			why = append(why, "ignoring the ca_file label: "+err.Error())
		}
	}
	pool, err := loadCAPool(r.cfg.CACert)
	if err != nil {
		why = append(why, err.Error())
		return nil, &caNotFound{"CA not found: set LLMCTL_CACERT (" + strings.Join(why, "; ") + ")"}
	}
	return pool, nil
}
