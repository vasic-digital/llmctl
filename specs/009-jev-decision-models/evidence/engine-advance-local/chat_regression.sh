#!/usr/bin/env bash
# chat regression of the advance candidate vs the pinned engine on THIS host's GPU (OD-1 gate).
# usage: chat_regression.sh <label> <llama-server binary> <model.gguf> <outdir>
set -euo pipefail
label="$1"; bin="$2"; model="$3"; out="$4"; port=18981
kf="$(mktemp)"; chmod 600 "$kf"; head -c 24 /dev/urandom | base64 | tr -d '/+=\n' > "$kf"
log="$out/server-$label.log"
"$bin" --model "$model" --host 127.0.0.1 --port "$port" --api-key-file "$kf" -ngl 99 --ctx-size 4096 -np 1 --no-warmup >"$log" 2>&1 &
pid=$!
cleanup() { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; rm -f "$kf"; }
trap cleanup EXIT
ready=no
for i in $(seq 1 180); do
  kill -0 "$pid" 2>/dev/null || { echo "server exited early" >&2; tail -5 "$log" >&2; exit 1; }
  # -f: a 503 while the model loads is NOT ready
  if curl -sf -o /dev/null -H "Authorization: Bearer $(cat "$kf")" "http://127.0.0.1:$port/health"; then ready=yes; break; fi
  sleep 1
done
[[ "$ready" == yes ]] || { echo "server never became ready" >&2; exit 1; }
req='{"messages":[{"role":"user","content":"List the first five prime numbers, comma separated, nothing else."}],"temperature":0,"seed":42,"max_tokens":48,"cache_prompt":false}'
for n in 1 2 3; do
  curl -s -H "Authorization: Bearer $(cat "$kf")" -H 'Content-Type: application/json' -d "$req" "http://127.0.0.1:$port/v1/chat/completions" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(json.dumps(d["choices"][0]["message"]["content"]))' > "$out/chat-$label-$n.txt"
done
curl -s -H "Authorization: Bearer $(cat "$kf")" -H 'Content-Type: application/json' -d '{"prompt":"The capital of France is","temperature":0,"seed":42,"n_predict":12,"cache_prompt":false}' "http://127.0.0.1:$port/completion" | python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin)["content"]))' > "$out/raw-$label.txt"
nvidia-smi --query-gpu=memory.used --format=csv,noheader > "$out/vram-$label.txt"
# GPU proof from the GPU itself: our server pid must hold real VRAM (the logs print no backend lines at default verbosity)
nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits | awk -F', *' -v p="$pid" '$1==p {print $2}' > "$out/vram-pid-$label.txt"
mib="$(head -1 "$out/vram-pid-$label.txt")"
[[ "${mib:-0}" -ge 1000 ]] || { echo "server pid $pid holds ${mib:-0} MiB VRAM in $label run - this run would not cover CUDA" >&2; exit 1; }
echo "$label done"
