"""GREEN: the SHIPPED lib/onnx_server.py Scorer.encode with the real spm.model and the same state.
Imports the shipped module; builds a Scorer without ONNX (object.__new__) since encode() needs only tok/ids.
usage: python -I d01_green_shipped.py <repo>/lib/onnx_server.py <spm.model>"""
import importlib.util, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, sentencepiece as spm
from d01_common import HYP, long_state
spec = importlib.util.spec_from_file_location("onnx_server", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sp = spm.SentencePieceProcessor(); assert sp.Load(sys.argv[2])
sc = object.__new__(m.Scorer); sc.max_tokens = 512; sc.tok_kind = "spm"; sc.tok = sp
sc.cls_id, sc.sep_id, sc.pad_id = sp.bos_id(), sp.eos_id(), sp.pad_id()
state = long_state(); h_ids = sp.EncodeAsIds(HYP); p_ids = sp.EncodeAsIds(state)
ids, types, trunc = sc.encode(state, HYP)
print("premise tokens:", len(p_ids), " hypothesis tokens:", len(h_ids))
print("shipped encode length:", len(ids), " truncated flag:", trunc)
print("hypothesis intact before final [SEP]:", ids[-1-len(h_ids):-1] == h_ids)
print("[SEP] count:", ids.count(sc.sep_id), " starts with [CLS]:", ids[0] == sc.cls_id)
print("premise kept tokens:", len(ids) - 3 - len(h_ids), "of", len(p_ids))
print("token_type 1 count == len(hyp)+1:", types.count(1) == len(h_ids) + 1)
ok = len(ids) == 512 and trunc and ids[-1-len(h_ids):-1] == h_ids and ids.count(sc.sep_id) == 2
print("GREEN HOLDS" if ok else "GREEN FAILS")
sys.exit(0 if ok else 1)
