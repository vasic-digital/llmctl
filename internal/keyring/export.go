package keyring

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// Managed block markers in a shell startup file.
const (
	BlockBegin = "# >>> llmctl key (managed) >>>"
	BlockEnd   = "# <<< llmctl key (managed) <<<"
)

// ExportResult describes InstallExportBlock's outcome.
type ExportResult struct {
	Changed  bool
	Backup   string
	Written  string
	Warnings []string
	Path     string
}

// ExportLine returns the startup-file text. The default (key == nil) is the
// reference form, which reads the value from the env file at shell start and so
// never contains the key; pass a key for the inline form.
func ExportLine(shell, envFile string, key *Secret) (string, error) {
	switch shell {
	case "bash", "zsh", "sh", "fish":
	default:
		return "", newErr(kindGeneric, "unsupported shell %q; use bash, zsh, sh or fish", shell)
	}
	if key != nil {
		if _, err := ValidateKey(key.Reveal(), "argument"); err != nil {
			return "", err
		}
		if shell == "fish" {
			return fmt.Sprintf(`set -gx %s "%s"`, KeyVar, key.Reveal()), nil
		}
		return fmt.Sprintf(`export %s="%s"`, KeyVar, key.Reveal()), nil
	}
	q := shellQuote(envFile)
	sed := fmt.Sprintf("sed -n 's/^%s=//p' %s | head -n 1", KeyVar, q)
	if shell == "fish" {
		return fmt.Sprintf("test -r %s; and set -gx %s (%s)", q, KeyVar, sed), nil
	}
	return fmt.Sprintf(`[ -r %s ] && export %s="$(%s)"`, q, KeyVar, sed), nil
}

func realpath(p string) string {
	abs, err := filepath.Abs(p)
	if err != nil {
		return p
	}
	if r, err := filepath.EvalSymlinks(abs); err == nil {
		return r
	}
	if r, err := filepath.EvalSymlinks(filepath.Dir(abs)); err == nil {
		return filepath.Join(r, filepath.Base(abs))
	}
	return abs
}

// InstallExportBlock adds/refreshes the managed block in startupFile (an
// explicit path only). Idempotent: identical content -> no write, no backup.
// A backup copy of the pre-change file is made.
func InstallExportBlock(startupFile, line string, backup bool) (ExportResult, error) {
	startupFile = realpath(startupFile)
	block := BlockBegin + "\n" + line + "\n" + BlockEnd + "\n"
	existed := false
	text := ""
	mode := os.FileMode(0o600)
	if st, err := os.Stat(startupFile); err == nil {
		existed = true
		mode = st.Mode().Perm()
		b, err := os.ReadFile(startupFile)
		if err != nil {
			return ExportResult{}, newErr(kindGeneric, "cannot read %s: %s", startupFile, reason(err))
		}
		text = string(b)
	} else if !errors.Is(err, os.ErrNotExist) {
		return ExportResult{}, newErr(kindGeneric, "cannot stat %s: %s", startupFile, reason(err))
	}
	var warnings []string
	if mode&0o044 != 0 {
		warnings = append(warnings, startupFile+" is readable by other users; shell startup files often are - prefer the reference form so no key value is stored there")
	}
	pat := regexp.MustCompile(`(?s)` + regexp.QuoteMeta(BlockBegin) + `\n.*?` + regexp.QuoteMeta(BlockEnd) + `\n?`)
	var newText string
	if loc := pat.FindStringIndex(text); loc != nil {
		newText = text[:loc[0]] + block + text[loc[1]:]
	} else {
		sep := ""
		if text != "" && !strings.HasSuffix(text, "\n") {
			sep = "\n"
		}
		newText = text + sep + block
	}
	if newText == text && existed {
		return ExportResult{Written: block, Warnings: warnings, Path: startupFile}, nil
	}
	backupPath := ""
	if existed && backup {
		backupPath = startupFile + ".llmctl-bak"
		for i := 1; ; i++ {
			if _, err := os.Lstat(backupPath); errors.Is(err, os.ErrNotExist) {
				break
			}
			backupPath = fmt.Sprintf("%s.llmctl-bak.%d", startupFile, i+1)
		}
		bf, err := os.OpenFile(backupPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
		if err != nil {
			return ExportResult{}, newErr(kindGeneric, "cannot create backup %s: %s", backupPath, reason(err))
		}
		_, werr := bf.WriteString(text)
		cerr := bf.Close()
		if werr != nil || cerr != nil {
			return ExportResult{}, newErr(kindGeneric, "cannot write backup %s", backupPath)
		}
	}
	dir := filepath.Dir(startupFile)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return ExportResult{}, newErr(kindGeneric, "cannot create %s: %s", dir, reason(err))
	}
	tf, err := os.CreateTemp(dir, ".llmctl-")
	if err != nil {
		return ExportResult{}, newErr(kindGeneric, "cannot create a temporary file in %s: %s", dir, reason(err))
	}
	fail := func(err error) (ExportResult, error) {
		tf.Close()
		_ = os.Remove(tf.Name())
		return ExportResult{}, newErr(kindGeneric, "cannot write %s: %s", startupFile, reason(err))
	}
	if err := tf.Chmod(mode); err != nil {
		return fail(err)
	}
	if _, err := tf.WriteString(newText); err != nil {
		return fail(err)
	}
	if err := tf.Sync(); err != nil {
		return fail(err)
	}
	if err := tf.Close(); err != nil {
		return fail(err)
	}
	if err := os.Rename(tf.Name(), startupFile); err != nil {
		_ = os.Remove(tf.Name())
		return ExportResult{}, newErr(kindGeneric, "cannot write %s: %s", startupFile, reason(err))
	}
	return ExportResult{Changed: true, Backup: backupPath, Written: block, Warnings: warnings, Path: startupFile}, nil
}
