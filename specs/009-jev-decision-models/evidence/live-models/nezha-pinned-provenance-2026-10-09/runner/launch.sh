#!/usr/bin/env bash
# launch.sh <profile> <label> <gw-timeout|default> <wall-timeout-seconds> [nli]   (SMOKE_ONLY=1 supported)
P=$1; L=$2; TO=$3; T=$4; KIND=${5:-gguf}
B=$HOME/llmctl-work-0910; OUT=$B/out/$L; mkdir -p $OUT; U=live-$L
echo "== pre-start $(date -u +%T)"; free -g | sed -n 1,3p; cat /proc/pressure/memory
full=$(awk '/^full/{sub("avg10=","",$2);print $2}' /proc/pressure/memory)
st=$(awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{printf "%.1f", f*100/t}' /proc/meminfo)
if awk -v a="$full" -v s="$st" 'BEGIN{exit !(a>=5 || s<50)}'; then echo "PRESTART-REFUSED psi_full=$full swap_free=$st"; exit 7; fi
pgrep -af "llama-server|onnx_server|llmctl-decide" | grep -v pgrep && { echo "PRESTART-REFUSED: ours/other engine running"; exit 8; }
cp /dev/null $OUT/psi-samples.txt
systemd-run --user --quiet --unit=wd-$U bash $B/runner/watchdog.sh $U $OUT/psi-samples.txt
sleep 1
if [[ $KIND == nli ]]; then
  CMDLINE=(env REPO=$B/repo W=$B/w OUT=$OUT GW_PORT=8195 ENG_PORT=8197 bash $B/runner/realcheck/run_live_nli.sh)
else
  CMDLINE=(bash $B/runner/run_profile.sh $P $OUT $TO)
fi
systemd-run --user --scope --unit=$U -p MemoryMax=44G -p MemorySwapMax=2G -p TasksMax=2000 timeout $T "${CMDLINE[@]}" > $OUT/full-run.log 2>&1
echo "scope rc=$?" >> $OUT/full-run.log
EOF_MARK=1
