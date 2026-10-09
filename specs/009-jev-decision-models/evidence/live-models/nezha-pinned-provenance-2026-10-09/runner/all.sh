#!/usr/bin/env bash
B=$HOME/llmctl-work-0910; cd $B
run(){ # profile label timeout wall [nli]
  for _ in $(seq 1 60); do pgrep -f "llama-server.*llmctl-work-0910|onnx_server.py.*llmctl-work-0910" >/dev/null || break; sleep 2; done
  sleep 20
  echo "[$(date -u +%T)] START $2" >> $B/all.log
  bash runner/launch.sh $1 $2 $3 $4 ${5:-gguf} >> $B/all.log 2>&1
  echo "[$(date -u +%T)] END $2 result=$(cat out/$2/RESULT.txt 2>/dev/null)" >> $B/all.log
  if grep -q ABORT out/$2/psi-samples.txt 2>/dev/null; then echo "WATCHDOG ABORT in $2; stopping driver" >> $B/all.log; exit 9; fi
}
run decide-2b  pinned-decide-2b-to300  300 3600
run decide-pro pinned-decide-pro-to300 300 10800
run decide     pinned-decide-to300     300 7200
run decide-max pinned-decide-max-to300 300 21600
run decide-nli pinned-decide-nli       default 3600 nli
echo ALL_DONE >> $B/all.log
