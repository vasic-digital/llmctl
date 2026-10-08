#!/usr/bin/env python3
"""Drives templates/agents/router.py against the real test gateway (environment from tests/test_agent_kit.sh)."""
import importlib.util, json, os, sys, tempfile

spec = importlib.util.spec_from_file_location("router", os.environ["ROUTER"])
router = importlib.util.module_from_spec(spec)
spec.loader.exec_module(router)

fails = 0
def expect(name, cond, detail=""):
    global fails
    if cond:
        print("router ok: " + name)
    else:
        fails += 1
        print("ROUTER-FAIL " + name + " " + str(detail))

routes = json.load(open(os.environ["ROUTES"]))["routes"]
ep, ca, key = os.environ["LLMCTL_ENDPOINT"], os.environ["LLMCTL_CACERT"], router.Secret(os.environ["LLMCTL_API_KEY"])
mk = lambda **kw: router.Router(routes, kw.pop("endpoint", ep), cafile=kw.pop("cafile", ca), key=kw.pop("key", key), **kw)
Q = {"q": {"type": "choice", "instructions": "Which tool?", "criteria": {"grep": "search", "ls": "list"}}}
NQ = {"q": {"type": "noul", "instructions": "Is it safe?"}}

r = mk()
res = r.decide("tool_selection_small", "find the file", Q, label_count=3)
expect("success on a real gateway", res["ok"] and res["source"] == "decide-tiny" and res["trail"] == ["tool_selection_small:ok"], res)
expect("the success result carries the real answer", res["result"]["answers"]["q"]["choice"] in ("grep", "ls") and 0 <= res["confidence"] <= 1, res)
res = r.decide("tool_selection", "x", Q, label_count=3)
expect("selector picks the small route for few labels", res["trail"][:1] == ["tool_selection->tool_selection_small"], res)
res = r.decide("tool_selection", "x", Q, label_count=10)
expect("a selector with label_count_over routes to the large one", res["ok"] and res["trail"][0] == "tool_selection->tool_selection_large" and res["route"] == "tool_selection_large", res)
res = r.decide("tool_selection_small", "x", Q, label_count=6)
expect("max_labels is enforced (falls back)", res["ok"] and res["trail"][0] == "tool_selection_small:max_labels" and res["route"] == "tool_selection_large", res)
res = r.decide("strict", "x", Q)
expect("below min_confidence follows the fallback to deny", (not res["ok"]) and res["source"] == "deny" and "below" in res["reason"], res)
res = r.decide("strict", "x", NQ)
expect("a noul question is scaled abs(p-0.5)*2 (0.5/0.5 uniform -> 0) and fails the gate", (not res["ok"]) and res["source"] == "deny", res)
res = r.decide("strict_chain", "x", Q)
expect("a fallback cycle ends in escalate, no recursion error", (not res["ok"]) and res["source"] == "escalate" and "cycle" in res["reason"], res)
res = r.decide("dangling", "x", Q)
expect("a fallback that is no route escalates (J3-038 KeyError class)", (not res["ok"]) and res["source"] == "escalate" and "unknown route" in res["reason"], res)
res = r.decide("tool_selecti", "x", Q)
expect("an unknown route name escalates instead of raising", (not res["ok"]) and res["source"] == "escalate", res)
res = r.decide("no_model", "x", Q)
expect("a route without a model escalates", (not res["ok"]) and "needs a model" in res["reason"], res)
res = r.decide("escalate", "x", Q)
expect("the reserved route name escalate is terminal", (not res["ok"]) and res["source"] == "escalate", res)

for label, kw in (("gateway down", {"endpoint": os.environ["DEAD_URL"]}), ("529 overloaded", {"endpoint": os.environ["S529_URL"]}),
                  ("wrong key (401)", {"key": router.Secret("llmctl_wrong_key_for_the_test_0000000000000000")})):
    res = mk(**kw).decide("tool_selection_small", "x", Q)
    expect(label + " never yields an allow: escalate", (not res["ok"]) and res["source"] == "escalate" and "failed" in res["reason"], res)
expect("529 is reported as retryable in the reason", "retryable" in mk(endpoint=os.environ["S529_URL"]).decide("tool_selection_small", "x", Q)["reason"])

try:
    mk(cafile="/nonexistent/ca.pem"); expect("a missing CA is a configuration error", False)
except router.ConfigError:
    expect("a missing CA is a configuration error", True)
with tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False) as f:
    f.write("not a pem"); bad = f.name
try:
    mk(cafile=bad); expect("a garbage CA file is a configuration error", False)
except router.ConfigError:
    expect("a garbage CA file is a configuration error", True)
finally:
    os.unlink(bad)
try:
    router.Router(routes, "http://127.0.0.1:1", cafile=ca, key=key); expect("plain http is refused", False)
except router.ConfigError:
    expect("plain http is refused", True)
for bad_route in ("min_agreement", "cost_budget", "min_probability"):
    try:
        router.Router({"r": {"model": "m", "min_confidence": 0.1, bad_route: 1}}, ep, cafile=ca, key=key); expect(bad_route + " is rejected, not ignored", False)
    except router.ConfigError:
        expect(bad_route + " is rejected, not ignored", True)

ex = json.load(open(os.path.join(os.path.dirname(os.environ["ROUTER"]), "routes.example.json")))["routes"]
try:
    rr = router.Router(ex, ep, cafile=ca, key=key)
    expect("routes.example.json loads", True)
    res = rr.decide("risk_gate", "x", Q)
    expect("the example risk_gate fails closed to deny on a low-confidence answer", (not res["ok"]) and res["source"] == "deny", res)
    res = rr.decide("tool_selection", "x", Q, label_count=3)
    expect("the example tool_selection routes small -> large -> escalate or succeeds, never raises", "source" in res, res)
except router.ConfigError as e:
    expect("routes.example.json loads", False, e)

# key sources
env = dict(os.environ); env.pop("LLMCTL_API_KEY", None)
with tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as f:
    f.write("OTHER=1\nLLMCTL_API_KEY=%s\n" % os.environ["LLMCTL_API_KEY"]); kf = f.name
env["LLMCTL_API_KEY_FILE"] = kf
try:
    r2 = router.Router(routes, ep, cafile=ca, key=router.load_key(env))
    expect("the key can come from a key file", r2.decide("tool_selection_small", "x", Q)["ok"])
finally:
    os.unlink(kf)
env.pop("LLMCTL_API_KEY_FILE")
try:
    router.load_key(env); expect("no key at all is a configuration error", False)
except router.ConfigError:
    expect("no key at all is a configuration error", True)
expect("a Secret never prints its value", os.environ["LLMCTL_API_KEY"] not in (repr(key) + str(key)))
expect("the router object does not leak the key through its repr", os.environ["LLMCTL_API_KEY"] not in repr(vars(mk()).get("key")))

# the CLI form
import subprocess
p = subprocess.run([sys.executable, os.environ["ROUTER"], os.environ["ROUTES"], "tool_selection_small", "find it", json.dumps(Q)],
                   capture_output=True, text=True, env={**os.environ, "LLMCTL_ENDPOINT": ep, "LLMCTL_CACERT": ca})
expect("CLI: success exit 0 with one JSON line", p.returncode == 0 and json.loads(p.stdout)["ok"], (p.returncode, p.stdout, p.stderr))
p = subprocess.run([sys.executable, os.environ["ROUTER"], os.environ["ROUTES"], "strict", "find it", json.dumps(Q)],
                   capture_output=True, text=True, env={**os.environ, "LLMCTL_ENDPOINT": ep, "LLMCTL_CACERT": ca})
expect("CLI: a deny outcome exits 1", p.returncode == 1 and json.loads(p.stdout)["source"] == "deny", (p.returncode, p.stdout))
p = subprocess.run([sys.executable, os.environ["ROUTER"], os.environ["ROUTES"], "strict", "x", "{bad"], capture_output=True, text=True,
                   env={**os.environ, "LLMCTL_ENDPOINT": ep, "LLMCTL_CACERT": ca})
expect("CLI: bad question JSON is a configuration failure that escalates", p.returncode == 1 and json.loads(p.stdout)["source"] == "escalate", (p.returncode, p.stdout))
p = subprocess.run([sys.executable, os.environ["ROUTER"]], capture_output=True, text=True)
expect("CLI: usage exits 2", p.returncode == 2)
print("ROUTER-DONE fails=%d" % fails)
sys.exit(1 if fails else 0)
