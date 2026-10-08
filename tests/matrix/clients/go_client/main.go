//go:build ignore

// go-nethttp matrix adapter (stdlib net/http + crypto/tls only). See ../README.md.
package main

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
)

func main() {
	if len(os.Args) != 7 {
		fmt.Println("ERROR usage")
		os.Exit(2)
	}
	method, url, cacert, tmo, bodyf, hdrf := os.Args[1], os.Args[2], os.Args[3], os.Args[4], os.Args[5], os.Args[6]
	var body io.Reader
	if bodyf != "-" {
		b, err := os.ReadFile(bodyf)
		if err != nil {
			fmt.Println("ERROR read body:", err)
			return
		}
		body = bytes.NewReader(b)
	}
	tcfg := &tls.Config{}
	if cacert != "-" {
		pem, err := os.ReadFile(cacert)
		pool := x509.NewCertPool()
		if err != nil || !pool.AppendCertsFromPEM(pem) {
			fmt.Println("ERROR cannot load CA file")
			return
		}
		tcfg.RootCAs = pool
	}
	t, _ := strconv.ParseFloat(tmo, 64)
	cl := &http.Client{
		Timeout:       time.Duration(t * float64(time.Second)),
		Transport:     &http.Transport{TLSClientConfig: tcfg, DisableKeepAlives: true},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	req, err := http.NewRequest(method, url, body)
	if err != nil {
		fmt.Println("ERROR", err)
		return
	}
	if hdrf != "-" {
		b, _ := os.ReadFile(hdrf)
		for _, l := range strings.Split(string(b), "\n") {
			if i := strings.Index(l, ":"); i > 0 {
				req.Header.Set(strings.TrimSpace(l[:i]), strings.TrimSpace(l[i+1:]))
			}
		}
	}
	resp, err := cl.Do(req)
	if err != nil {
		fmt.Println("ERROR", strings.ReplaceAll(err.Error(), "\n", " "))
		return
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	fmt.Println("STATUS", resp.StatusCode)
	keys := make([]string, 0, len(resp.Header))
	for k := range resp.Header {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		for _, v := range resp.Header[k] {
			fmt.Printf("HEADER %s: %s\n", strings.ToLower(k), v)
		}
	}
	fmt.Println("BODY_B64", base64.StdEncoding.EncodeToString(data))
}
