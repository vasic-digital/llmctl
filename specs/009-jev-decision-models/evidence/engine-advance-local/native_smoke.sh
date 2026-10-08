#!/usr/bin/env bash
# native /v1/systemone smoke of the advance candidate on THIS host's GPU. usage: native_smoke.sh <run> <outdir>
set -euo pipefail
run="$1"; out="$2"; S="$HOME/llmctl-engine-scratch"; bin="$S/llama.cpp-b11379/build/bin/llama-server"
kf="$(mktemp)"; chmod 600 "$kf"; head -c 24 /dev/urandom | base64 | tr -d '/+=\n' > "$kf"
port=18982; log="$out/server-julia-r$run.log"
env -u LD_LIBRARY_PATH "$bin" -m "$S/models/Julia-1-Q8_0.gguf" --host 127.0.0.1 --port "$port" --api-key-file "$kf" -ngl 99 -c 4096 -np 1 -b 4096 -ub 4096 >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; rm -f "$kf"' EXIT
ready=no
for i in $(seq 1 120); do
  kill -0 "$pid" 2>/dev/null || { echo "server exited early" >&2; tail -5 "$log" >&2; exit 1; }
  if curl -sf -o /dev/null "http://127.0.0.1:$port/health"; then ready=yes; break; fi
  sleep 1
done
[[ $ready == yes ]] || { echo "never ready" >&2; exit 1; }
nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits | awk -F', *' -v p="$pid" '$1==p {print $2}' > "$out/vram-pid-julia-r$run.txt"
echo "vram MiB: $(cat "$out/vram-pid-julia-r$run.txt")"
python3 "$out/sys1.py" "$port" "$(cat "$kf")" "$out" "julia-r$run" | tee "$out/native-r$run.txt" | cut -c1-600
curl -s -H "Authorization: Bearer $(cat "$kf")" "http://127.0.0.1:$port/v1/models" | head -c 300; echo
