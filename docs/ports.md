# Ports

**Revision:** 1 - 2026-10-08 (llmctl 3.1.0). Which TCP ports llmctl uses, how to move one, and which ports other tools commonly want. The table of profile ports is
generated from `models/catalog.json` (the `ports` object); the regeneration command is at the end of the page. If the table and the catalog ever disagree, the catalog wins.

## Profile ports (fixed strategy defaults)

| Port | Profile | Engine | Capability |
|---|---|---|---|
| 8080 | `fast` | llama | chat |
| 8081 | `coder` | llama | coder, chat |
| 8082 | `vision` | llama | vision, chat |
| 8083 | `vision-pro` | llama | vision, chat |
| 8084 | `moe-fast` | llama | chat |
| 8085 | `small` | llama | chat |
| 8086 | `ws-dense-32b` | llama | chat, coder |
| 8087 | `ws-moe-30b` | llama | chat, coder |
| 8090 | `colibri-glm` | colibri | chat, coder |
| 8091 | `colibri-qwen36` | colibri | chat, coder |
| 8092 | `decide-tiny` | llama | decide |
| 8093 | `decide` | llama | decide |
| 8094 | `decide-pro` | llama | decide |
| 8096 | `decide-nli` | onnx | decide |
| 8097 | `decide-max` | llama | decide |
| 8098 | `decide-2b` | llama | decide |
| 8103 | `decide-julia` | llama (native) | decide |
| 8104 | `decide-kev-08b` | llama (native) | decide |
| 8105 | `decide-kev-4b` | llama (native) | decide |
| 8106 | `decide-kev-9b` | llama (native) | decide |
| 8107 | `decide-laya` | llama (native) | decide |
| 8108 | `decide-lev` | llama (native) | decide |

Other llmctl ports, not in the catalog:

| Port | What | Where it is set |
|---|---|---|
| 8095 | the decision gateway (`llmctl decide serve`, HTTPS) | `LLMCTL_DECIDE_PORT` (default 8095); `LLMCTL_PORT_GATEWAY` under the registry, see below |
| 9443 | the address the **cluster CLI** expects `llmctld` on | `LLMCTL_CLUSTER_ENDPOINT` (default `https://127.0.0.1:9443`). This is only the CLI's default: `llmctld` itself listens on whatever `-api-bind` you give it (its own default is `127.0.0.1:0`, an ephemeral port), so start the daemon with `-api-bind 127.0.0.1:9443` or point the variable at the real address |

Ports the catalog leaves free: 8088-8089, 8095 (gateway), 8099-8102 and 8109 upward. 8099 is where the first candidate of `decide-max` lived and 8097 is where it is now, so do not assume an
older note's number.

## Which interface a port binds to

Chat engines bind `LLMCTL_BIND_HOST` (default `0.0.0.0`), the decision engines and the `onnx` runtime bind loopback only, and the gateway binds `LLMCTL_DECIDE_BIND` over HTTPS with a mandatory key
(see [architecture](architecture.md) "Port map" and [cloud-exposure](cloud-exposure.md)). A per-profile bind host is `LLMCTL_BIND_HOST_<PROFILE>`.

## Moving one port: `LLMCTL_PORT_<PROFILE>`

The variable name is the profile name upper-cased with `-` and `.` replaced by `_`: `LLMCTL_PORT_FAST=18080`, `LLMCTL_PORT_DECIDE_KEV_08B=18104`. An explicit number always wins over the catalog and over the
dynamic strategy. The value `auto` asks the registry allocator for a free port for that one profile. A value that is not a number is refused with `... is not a valid port number`.

This is exactly what the conflict message tells you. When a profile's port is already taken by another program, the start fails and llmctl reads the engine log and prints (the process name is added when `ss` can see it):

```
port 8080 is already in use by another process (llama-server), not an llmctl profile - stop it, or set LLMCTL_PORT_FAST to a free port
```

(`_sched_diagnose_bind_failure` in `lib/scheduler.sh`; the variable named in the message is built by the same rule as the one the planner reads.) The override is host-local on purpose: it is an environment variable, so the shared
`models/catalog.json` stays portable.

## Fixed versus dynamic

* **Fixed (default).** Each profile uses the port above. If something else holds it, the start fails loudly (see the message above); nothing is moved silently.
* **Dynamic (`LLMCTL_PORT_STRATEGY=dynamic`, or `LLMCTL_PORT_<PROFILE>=auto` for one profile).** The port is assigned at start time by the allocator in `llmctl-decide` (bind-tested on loopback, the wildcard addresses and every local interface), taken
  from a per-user range (`LLMCTL_PORT_RANGE`, default a 1000-port block derived from your uid inside 20000-31999), recorded in the service registry, and read back by `llmctl plan` and `llmctl decide registry`. The decision gateway finds its engines through that registry,
  so a moved engine needs no configuration change. Every service (chat engines, decision engines, the `onnx` runtime, the gateway) can run under it. It needs the `llmctl-decide` binary (`llmctl build decide`); without it, asking for dynamic ports is
  refused with an error rather than ignored, and a dry run never allocates anything. All details, variables and failure modes: [registry-discovery](registry-discovery.md).
* A fixed port a client has hard-coded (an agent configuration, an `OPENAI_BASE_URL`) does not follow a dynamic move; use `llmctl decide discover` or the registry to look the current one up.

## Collisions seen on a real host

On the development host on 2026-10-08 a listing of listening sockets showed 8080, 8082, 8087, 8099, 8100, 8102, 8110 and 8111 in use. The native-profile live report records 8099, 8100, 8102, 8110 and 8111 as held by other programs; the
research notes list 8080, 8082 and 8087 as collisions too (on a host that runs llmctl itself, some of these can of course be llmctl's own running profiles - check the process before you blame another tool). That is why the free range 8103-8108 was chosen for the six native decision
profiles, and why `fast`, `vision` and `ws-moe-30b` can need an override on such a host. This is one machine's measurement, not a claim about yours. Expect similar collisions on a workstation that runs other local servers;
run `ss -ltn` (or `lsof -iTCP -sTCP:LISTEN`) before the first start, and set `LLMCTL_PORT_<PROFILE>` or switch to the dynamic strategy for the ones that clash.

## Defaults of other tools (not verified by llmctl)

These come from the documentation of those projects as commonly published, were **not** re-checked for this release and can differ by version or packaging; verify with `ss -ltnp` on your machine.

| Port | Tool (default) |
|---|---|
| 8080 | `llama-server` started by hand without `--port` (this is also the catalog port of `fast`) |
| 11434 | Ollama |
| 8000 | vLLM's OpenAI-compatible server |
| 1234 | LM Studio local server |
| 7860 | Gradio-based web UIs such as text-generation-webui |

## Regenerating the profile table

```bash
python3 - <<'PY'
import json
c = json.load(open("models/catalog.json"))
for n, p in sorted(c["profiles"].items(), key=lambda kv: c["ports"][kv[0]]):
    cap = p["capability"]
    print("| %d | `%s` | %s | %s |" % (c["ports"][n], n, p["engine"], ", ".join(cap) if isinstance(cap, list) else cap))
PY
```

Related: [hardware-tiers](hardware-tiers.md) (decision profile sizes and tiers), [decision-models](decision-models.md), [runbooks](runbooks.md) ("Port conflicts").
