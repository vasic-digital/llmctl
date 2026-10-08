"""Stand-in for the onnxruntime MODEL BACKEND only (never the code under test).

The "model" file (model.onnx) is a small JSON spec so each test shapes the
backend without any environment seam in production code:
  {"inputs": ["input_ids","attention_mask"],   # declared graph inputs
   "order": ["entailment","neutral","contradiction"],  # logit layout
   "mode": "nli"|"nan"|"two"|"raise"|"inf"|"nan_after_first"|"raise_after_first"|"two_after_first",
   "record": "/path/feeds.jsonl"}              # append each run's feeds
"nli" logits: contradiction high iff the HYPOTHESIS segment (after the first
SEP id) holds the 'not' token id, else entailment high; neutral is 0.
"""
import json

import numpy as np

from _words import NOT, SEP


class SessionOptions:
    pass


class _In:
    def __init__(self, name):
        self.name = name


class InferenceSession:
    def __init__(self, path, sess_options=None, providers=None):
        with open(path, "r", encoding="utf-8") as fh:
            self.spec = json.load(fh)
        self.providers = providers
        self.calls = 0

    def get_inputs(self):
        return [_In(n) for n in self.spec.get("inputs", ["input_ids", "attention_mask"])]

    def run(self, names, feeds):
        declared = [i.name for i in self.get_inputs()]
        missing = [n for n in declared if n not in feeds]
        extra = [n for n in feeds if n not in declared]
        if missing or extra:
            raise ValueError("Required inputs (%s) are missing / unexpected (%s)" % (missing, extra))
        rec = self.spec.get("record")
        if rec:
            with open(rec, "a", encoding="utf-8") as fh:
                fh.write(json.dumps({k: v.tolist() for k, v in feeds.items()}) + "\n")
        self.calls += 1
        mode = self.spec.get("mode", "nli")
        late = self.calls > 1  # first run = the load-time smoke
        ids, mask = feeds["input_ids"], feeds["attention_mask"]
        if mode == "raise" or (mode == "raise_after_first" and late):
            raise RuntimeError("stub backend failure")
        n = ids.shape[0]
        if mode == "two" or (mode == "two_after_first" and late):
            return [np.zeros((n, 2), dtype=np.float32)]
        order = self.spec.get("order", ["entailment", "neutral", "contradiction"])
        out = np.zeros((n, len(order)), dtype=np.float32)
        for r in range(n):
            row = [int(x) for x, m in zip(ids[r], mask[r]) if m]
            hyp = row[row.index(SEP) + 1:] if SEP in row else row
            contra = NOT in hyp
            val = {"entailment": -1.0 if contra else 2.0, "neutral": 0.0,
                   "contradiction": 3.0 if contra else -1.0}
            for c, lbl in enumerate(order):
                out[r, c] = val.get(lbl, 0.0)
        if mode == "nan" or (mode == "nan_after_first" and late):
            out[0, 0] = float("nan")
        if mode == "inf":
            out[0, 0] = float("inf")
        return [out]
