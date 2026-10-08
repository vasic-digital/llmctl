package server

import (
	"bufio"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"
)

// G-037: an early rejection (413/401/404/400/503) of a request whose body is still being uploaded
// must still reach the client. Closing a socket that holds unread request bytes makes the kernel
// send an RST that can destroy the response (and fails the client's write with EPIPE). The server
// therefore flushes the response first and drains a bounded amount of the body (lingering close).
func rejectingWire(method, path, hdr string, body string) string {
	return fmt.Sprintf("%s %s HTTP/1.1\r\nHost: localhost\r\n%sContent-Length: %d\r\nConnection: close\r\n\r\n%s",
		method, path, hdr, len(body), body)
}

// uploadThenRead is the hardest client: it writes the WHOLE request before reading anything.
func uploadThenRead(h *harness, wire string) (*http.Response, error) {
	raw, err := net.DialTimeout("tcp", h.addr, 3*time.Second)
	if err != nil {
		return nil, fmt.Errorf("dial: %w", err)
	}
	defer raw.Close()
	tc := tls.Client(raw, h.clientTLS())
	_ = tc.SetDeadline(time.Now().Add(8 * time.Second))
	if err := tc.Handshake(); err != nil {
		return nil, fmt.Errorf("handshake: %w", err)
	}
	if _, err := io.WriteString(tc, wire); err != nil {
		return nil, fmt.Errorf("write: %w", err)
	}
	resp, err := http.ReadResponse(bufio.NewReader(tc), nil)
	if err != nil {
		return nil, fmt.Errorf("read: %w", err)
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	return resp, nil
}

func TestEarlyRejectWithUnreadBodyStillDeliversTheResponse(t *testing.T) {
	h := startServer(t, withLimits(func(l *Limits) {
		l.MaxBody = 4096
		noShedding(l)             // this test is about early rejection, not connection shedding
		l.AuthFailLimit = 1 << 20 // ... nor about the failed-auth throttle
	}))
	auth := "Authorization: Bearer " + testKey + "\r\nContent-Type: application/json\r\n"
	cases := []struct {
		name, wire string
		status     int
	}{
		{"413-small", rejectingWire("POST", "/v1/systemone", auth, strings.Repeat("x", 5000)), 413},
		{"413-large", rejectingWire("POST", "/v1/systemone", auth, strings.Repeat("x", 200_000)), 413},
		{"401-body", rejectingWire("POST", "/v1/systemone", "Content-Type: application/json\r\n", strings.Repeat("x", 3000)), 401},
		{"404-body", rejectingWire("POST", "/nope", auth, strings.Repeat("x", 3000)), 404},
		{"400-ctype", rejectingWire("POST", "/v1/systemone", "Authorization: Bearer "+testKey+"\r\nContent-Type: text/plain\r\n", strings.Repeat("x", 3000)), 400},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var wg sync.WaitGroup
			errs := make(chan error, 160)
			for w := 0; w < 8; w++ {
				wg.Add(1)
				go func() {
					defer wg.Done()
					for i := 0; i < 20; i++ {
						resp, err := uploadThenRead(h, tc.wire)
						if err != nil {
							errs <- err
							continue
						}
						if resp.StatusCode != tc.status {
							errs <- fmt.Errorf("status %d want %d", resp.StatusCode, tc.status)
						}
					}
				}()
			}
			wg.Wait()
			close(errs)
			n := 0
			for e := range errs {
				if n++; n <= 3 {
					t.Error(e)
				}
			}
			if n > 0 {
				t.Fatalf("%d/160 clients lost the %d response", n, tc.status)
			}
		})
	}
}

// The drain is bounded: a body far beyond the cap is not read to the end (no unbounded work for a
// hostile uploader) and the connection is closed within the linger deadline.
func TestEarlyRejectDrainIsBounded(t *testing.T) {
	h := startServer(t, withLimits(func(l *Limits) { l.MaxBody = 4096 }))
	raw, err := net.DialTimeout("tcp", h.addr, 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	tc := tls.Client(raw, h.clientTLS())
	_ = tc.SetDeadline(time.Now().Add(10 * time.Second))
	if err := tc.Handshake(); err != nil {
		t.Fatal(err)
	}
	head := "POST /v1/systemone HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer " + testKey +
		"\r\nContent-Type: application/json\r\nContent-Length: 1000000000\r\n\r\n"
	if _, err := io.WriteString(tc, head); err != nil {
		t.Fatal(err)
	}
	br := bufio.NewReader(tc)
	resp, err := http.ReadResponse(br, nil)
	if err != nil || resp.StatusCode != 413 {
		t.Fatalf("%v %v", resp, err)
	}
	// keep uploading far more than the drain cap; the server must hang up (EPIPE/RST/EOF) in time
	start := time.Now()
	chunk := make([]byte, 64*1024)
	var werr error
	for sent := 0; sent < 64<<20 && werr == nil; sent += len(chunk) {
		_ = tc.SetWriteDeadline(time.Now().Add(5 * time.Second))
		_, werr = tc.Write(chunk)
	}
	if werr == nil {
		t.Fatal("server kept accepting an unbounded upload after rejecting the request")
	}
	if d := time.Since(start); d > 5*time.Second {
		t.Fatalf("hang-up took %v", d)
	}
}
