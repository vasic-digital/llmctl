import json, subprocess, sys, os
W = "/home/milosvasic/Projects/llmctl/.claude/worktrees/agent-aad90dc8154ff63a7"
D = W + "/specs/009-jev-decision-models/evidence/protocol-verification"
os.makedirs(D + "/trees", exist_ok=True)
c = json.load(open(W + "/models/catalog.json"))
SKIP = ('.gguf', '.onnx', '.safetensors', '.bin', '.png', '.jpg', '.pt', '.msgpack', '.h5', '.model')
def curl(url, out):
    r = subprocess.run(["curl", "-sL", "--max-time", "30", "-o", out, "-w", "%{http_code}", url], capture_output=True, text=True)
    return r.stdout
for k, v in c["profiles"].items():
    if "decide" not in k:
        continue
    repo, rev = v["hf_repo"], v["hf_revision"]
    tp = f"{D}/trees/{k}.json"
    code = curl(f"https://huggingface.co/api/models/{repo}/tree/{rev}?recursive=true", tp)
    tree = json.load(open(tp))
    small = [x["path"] for x in tree if x.get("type") == "file" and not x["path"].endswith(SKIP) and x.get("size", 0) < 2_000_000]
    os.makedirs(f"{D}/{k}", exist_ok=True)
    got = []
    for p in small:
        out = f"{D}/{k}/" + p.replace("/", "__")
        hc = curl(f"https://huggingface.co/{repo}/raw/{rev}/{p}", out)
        got.append((p, hc, os.path.getsize(out)))
    print(k, code, got)
