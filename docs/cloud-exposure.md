# Exposing the decision gateway beyond your LAN

**Revision:** 1 - 2026-10-08. Applies to `llmctl decide serve` (the HTTPS decision gateway, default port 8095). It does **not** apply
to the chat engines (llama-server, colibri): those have no authentication of their own and must never be exposed beyond a trusted LAN
(see "Safety guarantees" in the [README](../README.md)).

Serving only machines on your own LAN (the common case) is [lan-exposure](lan-exposure.md); persistent start at boot is [persistent-services](persistent-services.md); certificate and key procedures are in [runbooks](runbooks.md).

## What you are exposing

The gateway is the only llmctl component designed to face a network. Out of the box it already:

* serves **HTTPS only**, TLS 1.2 minimum, certificates from a local CA under `$LLMCTL_HOME/cert` (`llmctl decide cert show`);
* requires an **access key** on every `/v1/*` request (`Authorization: Bearer ...`); `/healthz` and `/readyz` are open and tell a caller
  nothing but "alive" / "ready"; `/metrics` needs the key;
* binds `0.0.0.0` unless `LLMCTL_DECIDE_BIND` (or the global `LLMCTL_BIND_HOST`) says otherwise;
* limits connections (global, per source, unauthenticated vs authenticated), slows repeated failed authentications, bounds request size
  and time (`docs/decide-gateway.md`, `docs/tls-and-keys.md`).

What it does **not** do: protect against a volumetric flood from many addresses, hide the fact that something listens on the port, rate
limit **authenticated** callers per user, separate users (there is one key, one trust level), or give you a public certificate. Everything
below follows from that.

## Decide first whether you need it

| You want | Prefer |
|---|---|
| use it from your own laptop/phone at home or in the office | stay on the LAN; no exposure needed |
| use it from your own machines in other places | a **VPN / overlay** (WireGuard, Tailscale, ZeroTier): the gateway stays unreachable from the public Internet |
| use it from one specific machine you control | an **SSH tunnel** (`ssh -L 8095:127.0.0.1:8095 host`) and `LLMCTL_DECIDE_BIND=127.0.0.1` |
| let third parties call it | think again; see "Publicly reachable" at the end and the limits above |

## Option 1: VPN or overlay network (recommended)

Join the gateway host and the clients to one private network and reach the gateway by its private address. Nothing is opened on the
router. Add the private address (or MagicDNS/host name) to the certificate so clients can verify it:

```bash
export LLMCTL_TLS_SAN="dns:gw.tailnet.example,ip:100.64.0.7"     # your overlay name / address
llmctl decide cert renew --san "$LLMCTL_TLS_SAN"                    # re-issue the leaf with the new SANs
llmctl decide serve --stop && llmctl decide serve                   # or send SIGHUP (first field of gateway.pid) to reload the pair
```

Then export the CA **public** certificate once and install it on each client (the key travels separately, over a channel you trust):

```bash
llmctl decide cert export ./llmctl-ca.crt      # public CA only, mode 0644
```

`llmctl` never discovers a public IP for you and never adds a name to the certificate on its own: SANs come from the host's own names
and addresses plus what you list in `LLMCTL_TLS_SAN`. The default CA carries **name constraints** (host names, `localhost`, `*.local`,
loopback, RFC 1918, ULA, CGNAT/overlay ranges plus your `LLMCTL_TLS_SAN` extras), so a leaf for an arbitrary public name is not
issued unless you list it. `LLMCTL_CA_NAME_CONSTRAINTS=off` is a deliberate, logged opt-out.

## Option 2: SSH tunnel

```bash
# on the gateway host
export LLMCTL_DECIDE_BIND=127.0.0.1 && llmctl decide serve
# on the client
ssh -N -L 8095:127.0.0.1:8095 user@gateway-host
export LLMCTL_ENDPOINT=https://127.0.0.1:8095
```

The certificate already covers `127.0.0.1`, so verification works unchanged. This is the smallest possible exposure (an SSH login), and
it is per-session, not a service.

## Option 3: LAN firewall / router port-forward

Forwarding `TCP 8095` from the router to the host makes the gateway reachable from the Internet. If you do this:

1. **Add the public name or address to the certificate** (`LLMCTL_TLS_SAN=dns:gw.example.org` or `ip:203.0.113.7`, then
   `llmctl decide cert renew --san ...`, then signal the gateway: `kill -HUP "$(awk '{print $1}' "$LLMCTL_STATE_DIR/decide/gateway.pid")"`). Without it a verifying client correctly refuses the connection. The default CA only allows LAN-class names; a public DNS name needs a CA created with it listed ([runbooks](runbooks.md#renew--reload-the-certificate)).
2. Keep the key at its generated strength (256 bits); the entropy floor refuses weak operator-supplied keys, but a **throttle does not
   make guessing impossible** (`docs/tls-and-keys.md`).
3. Allow only the source addresses you need (`ufw`, `nftables`, router ACL). A firewall in front is the stated answer to a
   volumetric attacker (`docs/decide-gateway.md`, "Connection admission").
4. Expect port scanners within minutes. The request log (`decide-requests.jsonl`, field `auth`) records failed authentications; `/metrics` exposes
   `llmctl_decide_requests_total` (by status class, so a 4xx burst is visible) and `llmctl_decide_request_duration_seconds`.
5. Residual risk you accept: a flaw in the Go TLS/HTTP stack or in llmctl is reachable by anyone who can reach the port. Keep Go and
   llmctl current.
6. A forwarded port on a **multi-user** host also inherits the loopback port-squatting caveat for engines (`docs/tls-and-keys.md`).

## Option 4: Reverse proxy in front

A proxy (nginx, Caddy, HAProxy, a cloud load balancer) adds rate limiting, IP allow-lists, a public certificate and logging.
Honest consequences:

* **Two TLS hops.** Either the proxy terminates TLS with a public certificate and **re-encrypts to the gateway** (the proxy must trust
  the llmctl CA: give it `ca.crt` as the upstream CA bundle and let it verify), or it passes TCP/TLS through (`stream`/SNI passthrough)
  and clients still verify the llmctl certificate. Do **not** configure the proxy to skip upstream verification: that removes the only
  authentication of the gateway to the proxy and is exactly the shortcut llmctl refuses to offer in its own client.
* **The source address changes.** Behind a proxy every request comes from the proxy's address, so the gateway's per-source limits
  see one source. Raise the budgets (`LLMCTL_DECIDE_MAX_CONNS_PER_SOURCE`, `...UNAUTH_PER_SOURCE`) deliberately and rate limit at the proxy.
  The gateway does not read `X-Forwarded-For`.
* The proxy sees plaintext request bodies (the decision **state**) when it terminates TLS. Treat it as part of the trust boundary.
* Hosted SDK clients with default retry policy retry every 5xx; set `RetryPolicy(http_statuses={408, 429, 502, 503, 529})`
  (`docs/decide-gateway.md`) and do not let the proxy add retries of its own for a request that already reached the gateway.

## Option 5: Tunnel service (cloudflared, ngrok, Tailscale Funnel)

Convenient, because no inbound port is opened. The honest consequences: the provider terminates or relays your traffic, the decision
state and the access key pass through a third party, and the public name is on a provider-owned domain that your CA will not cover
unless you list it. Use it only when that is acceptable for the data you send; otherwise prefer Option 1.

## Never

* Never expose a chat engine port (8080-8091, 8098 ...) or the `onnx` runtime directly. They are unauthenticated or protected by an
  internal key meant for loopback.
* Never disable certificate verification in a client to "make it work". llmctl's own client has no such switch by design; if a third
  party client has one, fix the trust (`SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS`, or the proxy's CA bundle) instead.
* Never put the key in a URL, a shell history line, or a document. Use `$LLMCTL_API_KEY` references (`llmctl decide key export`).

## Publicly reachable: checklist

* [ ] SAN list contains exactly the names/addresses clients use; CA exported to each client over a trusted channel
* [ ] key rotated since any chat/log paste; `llmctl decide key doctor` clean
* [ ] firewall allow-list or reverse proxy rate limit in place
* [ ] `LLMCTL_DECIDE_MAX_*` limits reviewed for the front end (NAT/proxy = one source)
* [ ] `curl --cacert ca.crt https://host:8095/readyz` works from outside, and **fails** when `--cacert` is a wrong CA
* [ ] `llmctl decide cert doctor` shows more than 30 days left (renewal in [runbooks](runbooks.md))

Limits of this advice: it was reasoned from the code and the research notes (`specs/009-jev-decision-models/research/web-security-tls-exposure.md`);
no internet-facing deployment was exercised during the 3.1.0 work (see [limitations](limitations.md)).
