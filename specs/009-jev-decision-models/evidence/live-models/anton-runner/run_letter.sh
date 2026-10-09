#!/usr/bin/env bash
# run_letter.sh <profile> <gguf-path> <out-dir> : live letter-logit matrix on anton (CPU engine, scratch LLMCTL_HOME).
set -uo pipefail
P=$1; GGUF=$2; OUT=$3; GW_PORT=8195; ENG_PORT=8197
REPO=/home/milosvasic/Projects/llmctl; W=$HOME/llmctl-live-w-20261008
cd "$REPO" || exit 1
export LLMCTL_DATA_DIR=$W/data LLMCTL_STATE_DIR=$W/state LLMCTL_HOME=$W/home LLMCTL_ENV_FILE=$W/home/env
export LLMCTL_DECIDE_BIN=$REPO/build/llmctl-decide LLMCTL_DECIDE_NATIVE=1
UP=$(echo "$P" | tr 'a-z-' 'A-Z_')
export "LLMCTL_DECIDE_ENDPOINT_${UP}=http://127.0.0.1:${ENG_PORT}" LLMCTL_DECIDE_PORT=$GW_PORT
mkdir -p "$OUT" "$W/state/keys" "$W/work"
KF=$W/state/keys/llama-$P.key
( umask 077; python3 -c 'import secrets;print(secrets.token_hex(32))' > "$KF" ); chmod 600 "$KF"
CA=$W/home/cert/ca/ca.crt; GW=https://127.0.0.1:$GW_PORT
cleanup(){ bin/llmctl decide serve --stop >/dev/null 2>&1; [[ -n "${EP:-}" ]] && kill "$EP" 2>/dev/null; sed -i -E 's#(Bearer )[A-Za-z0-9._~+/=-]+#\1<redacted>#g' "$OUT"/*.log 2>/dev/null; }
trap cleanup EXIT
LS=$REPO/submodules/llama.cpp/build/bin/llama-server
CMD=("$LS" --model "$GGUF" --host 127.0.0.1 --port $ENG_PORT --ctx-size 8192 --n-gpu-layers 0 --flash-attn auto --parallel 1 --jinja --api-key-file "$KF" --no-webui --cache-type-k q8_0 --cache-type-v q8_0)
echo "${CMD[*]}" | sed "s#$KF#<keyfile>#" > "$OUT/engine-cmdline.txt"
env LD_LIBRARY_PATH=$REPO/submodules/llama.cpp/build/bin CUDA_VISIBLE_DEVICES= "${CMD[@]}" > "$OUT/engine.log" 2>&1 & EP=$!
for _ in $(seq 1 240); do curl -fsS -m 2 http://127.0.0.1:$ENG_PORT/health >/dev/null 2>&1 && break; kill -0 $EP 2>/dev/null || { echo ENGINE-EXITED > "$OUT/RESULT.txt"; exit 3; }; sleep 1; done
{ git rev-parse HEAD; git status --short internal/gateway/letter.go; sha256sum build/llmctl-decide; free -m|sed -n 1,2p; nvidia-smi --query-gpu=memory.used --format=csv; } > "$OUT/context.txt" 2>&1
grep -E "VmRSS" /proc/$EP/status >> "$OUT/context.txt"
bin/llmctl decide serve --port $GW_PORT > "$OUT/gateway-start.log" 2>&1
for _ in $(seq 1 30); do bin/llmctl decide models 2>/dev/null | awk -v p="$P" '$1==p && $2=="ready"{f=1} END{exit !f}' && break; sleep 1; done
bin/llmctl decide models > "$OUT/gateway-models.txt" 2>&1
( umask 077; bin/llmctl decide key show --yes-print > "$W/work/access.key" 2>/dev/null ); chmod 600 "$W/work/access.key"
# smoke: 3 choice questions through the gateway
python3 scripts/golden/run_golden.py --base-url $GW --cacert $CA --key-file $W/work/access.key --profile $P --types choice --limit 3 --run-id $P-smoke --out-dir "$OUT/smoke" > "$OUT/smoke.log" 2>&1
echo "--- smoke:"; cat "$OUT/smoke.log" | tail -8
if [[ "${SMOKE_ONLY:-0}" == 1 ]]; then exit 0; fi
if ! grep -q "well_formed=[1-9]" "$OUT/smoke.log"; then echo "SMOKE-FAILED: no well-formed answer, full matrix skipped" > "$OUT/RESULT.txt"; exit 6; fi
nice -n 10 python3 scripts/golden/run_golden.py --base-url $GW --cacert $CA --key-file $W/work/access.key --profile $P --permute-groups --run-id $P-golden --out-dir "$OUT/golden" > "$OUT/golden.log" 2>&1; echo "rc=$?" >> "$OUT/golden.log"
nice -n 10 python3 scripts/golden/run_golden.py --base-url $GW --cacert $CA --key-file $W/work/access.key --profile $P --set probes --run-id $P-probes --out-dir "$OUT/probes" > "$OUT/probes.log" 2>&1; echo "rc=$?" >> "$OUT/probes.log"
[[ -f $OUT/golden/results.json ]] && python3 scripts/golden/stats.py $OUT/golden/results.json > $OUT/golden-stats.txt 2>&1
[[ -f $OUT/probes/results.json ]] && python3 scripts/golden/stats.py $OUT/probes/results.json > $OUT/probes-stats.txt 2>&1
grep -E "VmRSS|VmHWM" /proc/$EP/status >> "$OUT/context.txt"; nvidia-smi --query-gpu=memory.used --format=csv >> "$OUT/context.txt"
echo done > "$OUT/RESULT.txt"
