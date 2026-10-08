"""RED: run the CANDIDATE's encode_pair (extracted verbatim from its source via ast, not retyped)
with the real DeBERTa spm.model and a ~600-token state; show the hypothesis tokens are cut away.
usage: python -I d01_red_candidate.py <candidate onnx_server.py> <spm.model>"""
import ast, sys, textwrap, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, sentencepiece as spm
from d01_common import HYP, long_state
src = open(sys.argv[1]).read()
tree = ast.parse(src)
fn = next(n for c in ast.walk(tree) if isinstance(c, ast.ClassDef) for n in c.body
          if isinstance(n, ast.FunctionDef) and n.name == "encode_pair")
code = textwrap.dedent(ast.get_source_segment(src, fn))
ns = {}
exec(code, ns)  # defines encode_pair(self, premise, hypothesis)
sp = spm.SentencePieceProcessor(); assert sp.Load(sys.argv[2])
class Self: pass
s = Self(); s.np = np; s.tokenizer = ("spm", sp)
state = long_state()
p_ids, h_ids = sp.EncodeAsIds(state), sp.EncodeAsIds(HYP)
ids, mask = ns["encode_pair"](s, state, HYP)
ids = ids[0].tolist()
sep = sp.eos_id()
print("premise tokens:", len(p_ids), " hypothesis tokens:", len(h_ids))
print("candidate encode_pair output length:", len(ids))
print("last id is [SEP]:", ids[-1] == sep)
tail = ids[-len(h_ids):]
print("hypothesis token ids present at the tail intact:", tail == h_ids)
present = sum(1 for t in h_ids if t in set(ids[len(ids)-5:]))
print("number of [SEP] ids in output:", ids.count(sep), "(a well-formed pair has 2)")
print("hypothesis fully absent from the output:", all(ids[i:i+len(h_ids)] != h_ids for i in range(len(ids)-len(h_ids)+1)))
print("DEFECT D-01 REPRODUCED" if (len(ids) == 512 and ids.count(sep) < 2) else "NOT REPRODUCED")
