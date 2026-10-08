"""decider-4b GGUF on llama.cpp: typed decisions with calibrated probabilities, no torch forward pass.

Needs `pip install decider-ai==1.5.0 llama-cpp-python` (llama-cpp-python 0.3.35 or newer; build it with
CMAKE_ARGS="-DGGML_CUDA=on" or "-DGGML_METAL=on" for a GPU).  The prompt is built by decider.prompt with the HF tokenizer
shipped in this repository, llama.cpp runs the rows, and the answer is the softmax over the option-letter logits at each
answer slot, divided by the temperatures in decider_config.json.  One prompt per llama_decode (see the model card for why).

    from decide_gguf import GGUFDecider
    d = GGUFDecider("decider-4b-v2.1-Q4_K_M.gguf")          # tokenizer and decider_config.json from the same folder
    d.decide("My card was charged twice for the same purchase.",
             [{"question": "Which department should handle this?", "options": ["billing", "technical", "sales"]}])
"""
import ctypes, json, os

import numpy as np
import llama_cpp as L
from transformers import AutoTokenizer
from decider.infer import Example, Q, _NoShuffle
from decider.prompt import MAX_OPTIONS, build, letter_ids
from decider import temperature as TT

_QUIET = L.llama_log_callback(lambda level, text, data: None)


class GGUFDecider:
    def __init__(self, gguf_path, folder=None, n_ctx=32768, n_gpu_layers=-1, n_threads=None, verbose=False):
        folder = folder or os.path.dirname(os.path.abspath(gguf_path))
        cfg = json.load(open(os.path.join(folder, "decider_config.json")))
        (self.T, self.T_by_type), _ = TT.from_config(cfg)
        self.name = "decider-" + str(cfg.get("version", "dev"))
        self.tok = AutoTokenizer.from_pretrained(folder)
        self.letters = np.asarray(letter_ids(self.tok))
        if not verbose:
            L.llama_log_set(_QUIET, ctypes.c_void_p(0))
        L.llama_backend_init()
        mp = L.llama_model_default_params(); mp.n_gpu_layers = n_gpu_layers
        self.model = L.llama_model_load_from_file(os.fsencode(gguf_path), mp)
        if not self.model:
            raise RuntimeError(f"llama.cpp could not load {gguf_path}")
        cp = L.llama_context_default_params()
        cp.n_ctx = n_ctx; cp.n_batch = n_ctx; cp.n_ubatch = min(2048, n_ctx); cp.n_seq_max = 1
        if n_threads:
            cp.n_threads = cp.n_threads_batch = n_threads
        self.ctx = L.llama_init_from_model(self.model, cp)
        self.n_ctx = n_ctx
        self.n_vocab = L.llama_vocab_n_tokens(L.llama_model_get_vocab(self.model))
        self.batch = L.llama_batch_init(n_ctx, 0, 1)

    def _slot_logits(self, ids, slots):
        if len(ids) > self.n_ctx:
            raise ValueError(f"prompt of {len(ids)} tokens exceeds n_ctx {self.n_ctx}")
        L.llama_memory_clear(L.llama_get_memory(self.ctx), True)
        b, want = self.batch, set(slots)
        for i, t in enumerate(ids):
            b.token[i] = t; b.pos[i] = i; b.n_seq_id[i] = 1; b.seq_id[i][0] = 0; b.logits[i] = i in want
        b.n_tokens = len(ids)
        if L.llama_decode(self.ctx, b) != 0:
            raise RuntimeError("llama_decode failed")
        rows = []
        for s in slots:
            p = ctypes.cast(L.llama_get_logits_ith(self.ctx, s), ctypes.POINTER(ctypes.c_float))
            rows.append(np.ctypeslib.as_array(p, shape=(self.n_vocab,))[self.letters].astype(np.float64))
        return rows

    def decide(self, context, questions, max_ctx_tokens=1536):
        """questions: [{"question": str, "options": [str, ...]}, ...] (2..255 options).
        -> [{"choice", "confidence", "probs"}, ...], one per question, as decider.infer.Decider.decide returns them."""
        for q in questions:
            assert 2 <= len(q["options"]) <= MAX_OPTIONS, f"2..{MAX_OPTIONS} options required"
        item = build(Example(context, [Q(q["question"], list(q["options"]), 0) for q in questions]), self.tok, _NoShuffle(),
                     max_options=MAX_OPTIONS, max_ctx_tokens=max_ctx_tokens)
        T = TT.for_types(self.T, self.T_by_type, ["choice"] * len(questions))
        out = []
        for q, lg, n, t in zip(questions, self._slot_logits(item["ids"], item["slots"]), item["nopts"], T):
            z = lg[:n] / t; p = np.exp(z - z.max()); p /= p.sum()
            j = int(p.argmax())
            out.append(dict(choice=q["options"][j], confidence=float(p[j]), probs=dict(zip(q["options"], p.tolist()))))
        return out
