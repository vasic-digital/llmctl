"""Extra: shipped spm pair-encoding vs the HF fast tokenizer.json (same pinned revision) on short pairs.
usage: python -I d01_tokenizer_equivalence.py <onnx_server.py> <spm.model> <tokenizer.json>"""
import importlib.util, sys
import sentencepiece as spm
from tokenizers import Tokenizer
spec = importlib.util.spec_from_file_location("onnx_server", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sp = spm.SentencePieceProcessor(); sp.Load(sys.argv[2]); tk = Tokenizer.from_file(sys.argv[3]); tk.no_padding()
sc = object.__new__(m.Scorer); sc.max_tokens = 512; sc.tok_kind = "spm"; sc.tok = sp
sc.cls_id, sc.sep_id, sc.pad_id = sp.bos_id(), sp.eos_id(), sp.pad_id()
pairs = [("The server restarted twice overnight.", "Restart the service."),
         ("Disk usage is at 91% on /var.", "Rotate the logs."),
         ("Der Dienst ist ausgefallen.", "Escalate to the on-call engineer."),
         ("Prices rose 3.5% (year over year), costs: $1,200.", "Costs increased."),
         ("  multiple   spaces\tand\nnewlines ", "hypothesis with  spaces")]
bad = 0
for p, h in pairs:
    a = sc.encode(p, h)[0]; b = tk.encode(p, h).ids
    ok = a == b; bad += (not ok)
    print("MATCH" if ok else "DIFF ", repr(p)[:40], len(a), len(b))
    if not ok: print("  spm:", a[:30], "\n  hf :", b[:30])
print("pairs:", len(pairs), "mismatches:", bad)
