package gateway

import (
	"net"
	"os"
	"strconv"

	"github.com/vasic-digital/llmctl/internal/registry"
)

// KindGateway is the registry kind under which the gateway publishes itself.
const KindGateway = "gateway"

// GatewayEntryName is the registry name of the gateway.
const GatewayEntryName = "decide-gateway"

// GatewayEntry builds the registry entry of a gateway process listening on bind:port over https.
// A wildcard (or empty) bind is published as 127.0.0.1 - the address a local client and the
// health probe can reach - and is not loopback-only; a loopback bind is.
func GatewayEntry(bind string, port, pid int, token string) registry.Entry {
	host := bind
	ip := net.ParseIP(bind)
	wildcard := bind == "" || (ip != nil && ip.IsUnspecified())
	if wildcard {
		host = "127.0.0.1"
	}
	return registry.Entry{
		Name: GatewayEntryName, Host: host, Port: port, Protocol: "https", HealthPath: "/healthz",
		Labels: map[string]string{
			registry.LabelKind: KindGateway, registry.LabelProfile: "decide", "protocol": "https", "port": strconv.Itoa(port),
		},
		PID: pid, CmdToken: token, LoopbackOnly: !wildcard && ip != nil && ip.IsLoopback(),
	}
}

// PublishGateway registers the gateway in reg (call once it is listening) and returns the function
// that unregisters it (call on drain). The unregister removes the entry only while it is still this
// process's own, so a successor that took the name over is never evicted by a late drain.
func PublishGateway(reg *registry.Registry, bind string, port int, token string) (unpublish func(), err error) {
	return PublishGatewayCA(reg, bind, port, token, "")
}

// PublishGatewayCA is PublishGateway that also records the CA file that certifies the gateway in
// the entry's ca_file label (registry.LabelCAFile), so a reconciler that does not share the
// gateway's environment verifies against the right CA (G-068). An empty caFile adds no label.
func PublishGatewayCA(reg *registry.Registry, bind string, port int, token, caFile string) (unpublish func(), err error) {
	e := GatewayEntry(bind, port, os.Getpid(), token)
	if caFile != "" {
		e.Labels[registry.LabelCAFile] = caFile
	}
	if err := reg.Register(e); err != nil {
		return func() {}, err
	}
	return func() {
		if cur, ok, err := reg.Get(e.Name); err == nil && ok && cur.PID == e.PID {
			_, _ = reg.Unregister(e.Name)
		}
	}, nil
}
