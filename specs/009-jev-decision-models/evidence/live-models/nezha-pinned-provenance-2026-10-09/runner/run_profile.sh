#!/usr/bin/env bash
# run_profile.sh <profile> <out-dir> <gateway-timeout-seconds|default> : live letter-logit matrix on nezha (CPU), scratch LLMCTL_HOME.
set -uo pipefail
P=$1; OUT=$2; TO=$3; GW_PORT=8195; ENG_PORT=8197
RUNNER=$HOME/llmctl-work-0910/runner; REPO=$HOME/llmctl-work-0910/repo; W=$HOME/llmctl-work-0910/w
cd "$REPO" || exit 1
export LLMCTL_DATA_DIR=$W/data LLMCTL_STATE_DIR=$W/state LLMCTL_HOME=$W/home LLMCTL_ENV_FILE=$W/home/env
export LLMCTL_DECIDE_BIN=$REPO/build/llmctl-decide LLMCTL_DECIDE_NATIVE=1
[[ "$TO" != default ]] && export LLMCTL_DECIDE_TIMEOUT=$TO
UP=$(echo "$P" | tr 'a-z-' 'A-Z_')
export "LLMCTL_DECIDE_ENDPOINT_${UP}=http://127.0.0.1:${ENG_PORT}" LLMCTL_DECIDE_PORT=$GW_PORT
GGUF=$(ls $W/data/models/$P/*.gguf | head -1)
mkdir -p "$OUT" "$W/state/keys" "$W/work"
KF=$W/state/keys/llama-$P.key; ( umask 077; python3 -c 'import secrets;print(secrets.token_hex(32))' > "$KF" ); chmod 600 "$KF"
CA=$W/home/cert/ca/ca.crt; GW=https://127.0.0.1:$GW_PORT
cleanup(){ bin/llmctl decide serve --stop >/dev/null 2>&1; [[ -n "${EP:-}" ]] && kill "$EP" 2>/dev/null; sed -i -E 's#(Bearer )[A-Za-z0-9._~+/=-]+#\1<redacted>#g' "$OUT"/*.log 2>/dev/null; }
trap cleanup EXIT
LSD=$HOME/llmctl-work-live/llama.cpp/build/bin
CMD=("$LSD/llama-server" --model "$GGUF" --host 127.0.0.1 --port $ENG_PORT --ctx-size 8192 --n-gpu-layers 0 --flash-attn auto --parallel 1 --jinja --api-key-file "$KF" --no-webui --cache-type-k q8_0 --cache-type-v q8_0)
echo "${CMD[*]}" | sed "s#$KF#<keyfile>#" > "$OUT/engine-cmdline.txt"
echo "LLMCTL_DECIDE_TIMEOUT=${LLMCTL_DECIDE_TIMEOUT:-<unset: gateway default 8s>}" >> "$OUT/engine-cmdline.txt"
env LD_LIBRARY_PATH=$LSD CUDA_VISIBLE_DEVICES= "${CMD[@]}" > "$OUT/engine.log" 2>&1 & EP=$!
for _ in $(seq 1 300); do curl -fsS -m 2 http://127.0.0.1:$ENG_PORT/health >/dev/null 2>&1 && break; kill -0 $EP 2>/dev/null || { echo ENGINE-EXITED > "$OUT/RESULT.txt"; exit 3; }; sleep 1; done
{ cat $HOME/llmctl-work-0910/PROVENANCE.txt; sha256sum build/llmctl-decide; free -m|sed -n 1,3p; grep -E "VmRSS" /proc/$EP/status; "$LSD/llama-server" --version 2>&1 | head -2; date -u; } > "$OUT/context.txt" 2>&1
bin/llmctl decide serve --port $GW_PORT > "$OUT/gateway-start.log" 2>&1
for _ in $(seq 1 30); do bin/llmctl decide models 2>/dev/null | awk -v p="$P" '$1==p && $2=="ready"{f=1} END{exit !f}' && break; sleep 1; done
bin/llmctl decide models > "$OUT/gateway-models.txt" 2>&1
if ! awk -v p="$P" '$1==p && $2=="ready"{f=1} END{exit !f}' "$OUT/gateway-models.txt"; then echo "FAILED-PREFLIGHT: gateway does not report $P ready" > "$OUT/RESULT.txt"; exit 5; fi
( umask 077; bin/llmctl decide key show --yes-print > "$W/work/access.key" 2>/dev/null ); chmod 600 "$W/work/access.key"
[[ -s $W/work/access.key ]] || { echo "NO-ACCESS-KEY" > "$OUT/RESULT.txt"; exit 4; }
CTO=330; [[ "$TO" == default ]] && CTO=120
G() { REPO=$REPO HDRLOG="$OUT/hdr-$1.jsonl" python3 "$RUNNER/golden_hdr.py" --base-url $GW --cacert $CA --key-file $W/work/access.key --profile $P --timeout $CTO "${@:2}"; }
# smoke: 3 choice questions
G smoke --types choice --limit 3 --run-id $P-smoke --out-dir "$OUT/smoke" > "$OUT/smoke.log" 2>&1
echo "--- smoke:"; tail -6 "$OUT/smoke.log"
if ! grep -q "well_formed=[1-9]" "$OUT/smoke.log"; then echo "SMOKE-FAILED: no well-formed answer, full matrix skipped" > "$OUT/RESULT.txt"; exit 6; fi
[[ "${SMOKE_ONLY:-0}" == 1 ]] && { echo smoke-only > "$OUT/RESULT.txt"; exit 0; }
nice -n 10 bash -c "$(declare -f G); G(){ REPO=$REPO HDRLOG=\"$OUT/hdr-\$1.jsonl\" python3 $RUNNER/golden_hdr.py --base-url $GW --cacert $CA --key-file $W/work/access.key --profile $P --timeout $CTO \"\${@:2}\"; }; G golden --permute-groups --run-id $P-golden --out-dir $OUT/golden > $OUT/golden.log 2>&1; echo rc=\$? >> $OUT/golden.log; G probes --set probes --run-id $P-probes --out-dir $OUT/probes > $OUT/probes.log 2>&1; echo rc=\$? >> $OUT/probes.log"
[[ -f $OUT/golden/results.json ]] && python3 scripts/golden/stats.py $OUT/golden/results.json > $OUT/golden-stats.txt 2>&1
[[ -f $OUT/probes/results.json ]] && python3 scripts/golden/stats.py $OUT/probes/results.json > $OUT/probes-stats.txt 2>&1
grep -E "VmRSS|VmHWM" /proc/$EP/status >> "$OUT/context.txt"
echo done > "$OUT/RESULT.txt"
