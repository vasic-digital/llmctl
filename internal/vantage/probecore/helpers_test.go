package probecore

import (
	"encoding/base64"
	"encoding/hex"
	"strconv"
	"strings"
)

func base64Wrap(der []byte) string {
	s := base64.StdEncoding.EncodeToString(der)
	var b strings.Builder
	for len(s) > 64 {
		b.WriteString(s[:64] + "\n")
		s = s[64:]
	}
	b.WriteString(s + "\n")
	return b.String()
}

func hexOf(b []byte) string { return hex.EncodeToString(b) }
func itoa(n int) string     { return strconv.Itoa(n) }
