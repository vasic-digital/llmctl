"""Supplementary driver (T058n, anton -> nezha). Reuses the matrix adapters + validators UNCHANGED
(imports tests.matrix.run.Env / cases.validate_systemone) to send noul/choice/score calls to each
SERVED profile by explicit model id, because run.py sends no `model` and the gateway has no default.
Key is read from the environment variable LLMCTL_API_KEY only; never printed."""
import json, os, sys, tempfile, argparse, time
sys.path.insert(0, os.getcwd())
from tests.matrix import run as R, cases as C
ap = argparse.ArgumentParser()
ap.add_argument("--base"); ap.add_argument("--cacert"); ap.add_argument("--spki-cert"); ap.add_argument("--out")
a = ap.parse_args()
ns = argparse.Namespace(base_url=a.base, cacert=a.cacert, engine_port=None, host_ip=None, scenario_hook=None)
work = tempfile.mkdtemp(prefix="pp-")
env = R.Env(ns, work); env.key = os.environ["LLMCTL_API_KEY"]; env.base = a.base; env.cacert = a.cacert
env.spki = R.spki_from_cert(a.spki_cert)
clients = ["curl", "python-urllib", "python-requests", "node-fetch", "go-nethttp"]
env.prepare(clients)
profiles = ["decide-nli", "decide-2b", "decide-pro", "decide-max"]
qs = {"noul": {"q": C._q_noul()}, "choice": {"q": C._q_choice(3)}, "score": {"q": C._q_score(5)}}
rows = []
for p in profiles:
    for cl in clients:
        ok, why = env.avail[cl]
        for kind, q in qs.items():
            body = C.req(questions=q, model=p)
            rec = {"profile": p, "client": cl, "qtype": kind}
            if not ok:
                rec.update(result="not-exercised", reason=why); rows.append(rec); continue
            r = env.invoke(cl, "POST", a.base + "/v1/systemone", "key", {"Content-Type": "application/json"}, json.dumps(body).encode(), 60)
            rec["ms"] = r.ms; rec["status"] = r.status
            probs = []
            if r.status != 200:
                probs.append("status %s error=%s body=%s" % (r.status, r.error, r.body[:200]))
            else:
                try:
                    d = json.loads(r.body)
                    strict = C.validate_systemone(d, body)
                    # tolerant pass: drop the additive `maturity` label the 3.1.0 gateway adds (absent from tests/matrix + contracts)
                    import copy
                    d2 = copy.deepcopy(d)
                    for an in d2.get("answers", {}).values():
                        if isinstance(an, dict): an.pop("maturity", None)
                    probs += C.validate_systemone(d2, body)
                    rec["maturity"] = [an.get("maturity") for an in d.get("answers", {}).values()]
                    rec["strict_problems"] = strict
                    if d.get("model") != p: probs.append("model echo %r != %r" % (d.get("model"), p))
                    ans = d["answers"]["q"]; rec["answer_type"] = ans.get("type")
                except Exception as e:
                    probs.append("parse: %s" % e)
            rec["result"] = "pass" if not probs else "fail"
            if probs: rec["problems"] = probs
            rows.append(rec)
            print(p, cl, kind, rec["result"], rec["ms"], flush=True)
json.dump(rows, open(a.out, "w"), indent=1)
