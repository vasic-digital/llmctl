#!/usr/bin/env python3
"""Real-tokenizer property check for lib/onnx_server.py (D-01 / G-017).

usage: onnx_real_tokenizer_check.py <onnx_server.py> <spm.model>
Loads the given runtime module, builds a Scorer WITHOUT onnxruntime (encode() needs only
the tokenizer), feeds the real DeBERTa-v3 SentencePiece model a ~600-token premise and
asserts the hypothesis + both [SEP] tokens survive, only the premise is cut, and the
truncated flag is set. Exit 0 = property holds, 1 = violated. Prints one line per check.
"""
import importlib.util
import sys

import sentencepiece as spm


def main():
    mod_path, spm_path = sys.argv[1], sys.argv[2]
    spec = importlib.util.spec_from_file_location("onnx_server_under_test", mod_path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    sp = spm.SentencePieceProcessor()
    if not sp.Load(spm_path):
        print("FAIL cannot load spm model")
        return 2
    sc = object.__new__(mod.Scorer)
    sc.max_tokens, sc.tok_kind, sc.tok = 512, "spm", sp
    sc.cls_id, sc.sep_id, sc.pad_id = sp.bos_id(), sp.eos_id(), sp.pad_id()
    hyp = "Option A is the correct action for this decision: restart the failed service now."
    sent = ("Observation %d: the monitoring agent recorded a transient latency spike on node %d "
            "while the queue depth stayed within its configured limits and no operator action was pending.")
    state = " ".join(sent % (i, i % 7) for i in range(20))
    p_ids, h_ids = sp.EncodeAsIds(state), sp.EncodeAsIds(hyp)
    bad = 0

    def check(name, cond):
        nonlocal bad
        print(("ok   " if cond else "FAIL ") + name)
        bad += 0 if cond else 1

    check("premise is long enough to need truncation (>512 tokens)", len(p_ids) > 512)
    try:
        ids, types, trunc = sc.encode(state, hyp)
    except Exception as exc:  # a mutant that breaks encode must FAIL, not crash silently
        print("FAIL encode raised %s" % type(exc).__name__)
        return 1
    check("length is exactly 512", len(ids) == 512)
    check("truncated flag is True", trunc is True)
    check("starts with [CLS]", ids[0] == sp.bos_id())
    check("exactly two [SEP]", ids.count(sp.eos_id()) == 2)
    check("hypothesis tokens intact before the final [SEP]", ids[-1 - len(h_ids):-1] == h_ids)
    check("ends with [SEP]", ids[-1] == sp.eos_id())
    check("premise is the part that was cut (kept prefix matches)", ids[1:1 + 10] == p_ids[:10])
    check("token_type 1 covers hypothesis + final [SEP]", types.count(1) == len(h_ids) + 1)
    ids2, _t2, trunc2 = sc.encode("The server restarted.", "Restart the service.")
    check("short pair is not truncated", trunc2 is False and len(ids2) < 512)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
