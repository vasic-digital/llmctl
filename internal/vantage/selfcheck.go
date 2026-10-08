package vantage

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"strings"
	"time"
)

// Check is one named assertion of the self-check.
type Check struct {
	Name   string `json:"name"`
	OK     bool   `json:"ok"`
	Detail string `json:"detail"`
}

// SelfCheckResult is the data of `vantage --selfcheck`.
type SelfCheckResult struct {
	OK                 bool    `json:"ok"`
	HostIP             string  `json:"host_ip"`
	ContainerIP        string  `json:"container_ip"`
	ServerObservedPeer string  `json:"server_observed_peer"`
	ContainerLocalAddr string  `json:"container_local_addr"`
	Checks             []Check `json:"checks"`
}

func hostOf(addr string) string {
	h, _, err := net.SplitHostPort(addr)
	if err != nil {
		return addr
	}
	return h
}

func isLoopback(h string) bool {
	ip := net.ParseIP(h)
	return ip != nil && ip.IsLoopback()
}

// EvaluateSelfCheck turns the observations into assertions (pure, unit-tested).
// observedPeer is the remote address the host-side echo server saw;
// containerLocal is the local address the container used for that connection;
// containerIP is the address the container reports for itself.
func EvaluateSelfCheck(hostIP, containerIP, observedPeer, containerLocal, echoedPeer string) []Check {
	obs, loc := hostOf(observedPeer), hostOf(containerLocal)
	return []Check{
		{"server saw a connection", obs != "", fmt.Sprintf("peer=%q", observedPeer)},
		{"observed peer is not loopback", obs != "" && !isLoopback(obs), fmt.Sprintf("server-observed peer host %q", obs)},
		{"container source address is not loopback", loc != "" && !isLoopback(loc), fmt.Sprintf("container local address %q", loc)},
		{"container source address differs from the host address", loc != "" && loc != hostIP, fmt.Sprintf("container %q vs host %q", loc, hostIP)},
		{"container source address is the container's own IP", loc != "" && loc == containerIP, fmt.Sprintf("local %q vs reported ip %q", loc, containerIP)},
		{"container and server agree on the peer", echoedPeer == observedPeer, fmt.Sprintf("echoed %q vs observed %q", echoedPeer, observedPeer)},
	}
}

// SelfCheck proves the container's source address differs from the host
// loopback: the container calls an echo server bound on the host's NON-loopback
// address and the observed peer is compared (FR-064).
func (m *Manager) SelfCheck(ctx context.Context) (SelfCheckResult, error) {
	st, err := m.mustState(ctx)
	if err != nil {
		return SelfCheckResult{}, err
	}
	ln, err := net.Listen("tcp", net.JoinHostPort(st.HostIP, "0"))
	if err != nil {
		return SelfCheckResult{}, fmt.Errorf("selfcheck: cannot bind echo server on host address %s: %w", st.HostIP, err)
	}
	observed := make(chan string, 4)
	srv := &http.Server{ReadHeaderTimeout: 5 * time.Second, Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case observed <- r.RemoteAddr:
		default:
		}
		_, _ = w.Write([]byte(r.RemoteAddr))
	})}
	go func() { _ = srv.Serve(ln) }()
	defer func() {
		sctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = srv.Shutdown(sctx)
	}()

	url := "http://" + ln.Addr().String() + "/echo"
	res, err := m.Probe(ctx, ProbeRequest{URL: url, Timeout: 5 * time.Second})
	if err != nil {
		return SelfCheckResult{}, err
	}
	if res.Error != "" {
		return SelfCheckResult{HostIP: st.HostIP, ContainerIP: st.IP, Checks: []Check{{"container reached the echo server", false, res.Error}}},
			fmt.Errorf("selfcheck: container could not reach the host echo server %s: %s", url, res.Error)
	}
	var peer string
	select {
	case peer = <-observed:
	case <-time.After(2 * time.Second):
	}
	out := SelfCheckResult{HostIP: st.HostIP, ContainerIP: st.IP, ServerObservedPeer: peer, ContainerLocalAddr: res.LocalAddr}
	out.Checks = EvaluateSelfCheck(st.HostIP, st.IP, peer, res.LocalAddr, strings.TrimSpace(res.Body))
	out.OK = true
	for _, c := range out.Checks {
		out.OK = out.OK && c.OK
	}
	return out, nil
}
