#!/usr/bin/env python3
"""Probe decide-tiny on 127.0.0.1:8092 with the vendor's macjev-render-v1 verdict layout
(segments tokenised separately via /tokenize, special tokens NOT parsed) vs the gateway's
letter-logit prompt. Prints per-option logprob(' yes') - logprob(' no') at each ' ->' slot."""
import json, math, urllib.request

U = "http://127.0.0.1:8092"
YES, NO, ARROW = 9542, 874, 1411


def post(path, body):
    r = urllib.request.Request(U + path, json.dumps(body).encode(), {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(r, timeout=120))


def enc(t):
    return post("/tokenize", {"content": t, "add_special": False, "parse_special": False})["tokens"]


def verdict(state, qtype, ins, opts):
    pre = enc("State:\n") + enc(state) + enc("\n\n")
    suf = enc(f"Question [{qtype}]: {ins}\nOptions:\n")
    eo = [enc(o) for o in opts]
    for o in eo:
        suf += enc("- ") + o + enc("\n")
    suf += enc("Judge each option:\n")
    slots = []
    for o in eo:
        suf += o + [ARROW]
        slots.append(len(pre) + len(suf))
        suf += enc("\n")
    ids = pre + suf
    out = []
    for s in slots:
        r = post("/completion", {"prompt": ids[:s], "n_predict": 1, "n_probs": 32, "temperature": 0,
                                 "cache_prompt": False, "seed": 1, "post_sampling_probs": False})
        top = {t["id"]: t["logprob"] for t in r["completion_probabilities"][0]["top_logprobs"]}
        out.append((top.get(YES), top.get(NO)))
    return out


def show(name, opts, res):
    sc = [(y - n) if y is not None and n is not None else None for y, n in res]
    print(name, [(o, None if s is None else round(s, 3)) for o, s in zip(opts, sc)])
    if None not in sc:
        T = 0.8800546821789332
        m = max(x / T for x in sc)
        e = [math.exp(x / T - m) for x in sc]
        print("   probs(T=global)", [round(x / sum(e), 3) for x in e])


st = "Routing."
o = ["billing: handles invoices", "legal: contracts"]
show("choice-2 (invoice)", o, verdict(st, "choice", "Which team handles invoices?", o))
o4 = ["billing: handles invoices", "legal: contracts", "shipping: deliveries", "support: login help"]
show("choice-4 (invoice)", o4, verdict(st, "choice", "Which team handles invoices?", o4))
on = ["false: no, the statement does not hold", "true: yes, the statement holds"]
show("noul (disk 97%)", on, verdict("Disk usage is 97% and rising", "noul", "Is immediate action needed?", on))
show("noul (disk 12%)", on, verdict("Disk usage is 12% and stable", "noul", "Is immediate action needed?", on))
