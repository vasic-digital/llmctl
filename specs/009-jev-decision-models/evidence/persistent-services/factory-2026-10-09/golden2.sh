cd ~/llmctl-3.1.0-factory
declare -A MO=([decide-max]=16 [decide-kev-9b]=255 [decide-pro]=20 [decide-2b]=16)
rm -f ~/llmctl-factory-logs/golden2-progress.log
for p in decide-max decide-kev-9b decide-pro decide-2b; do
  o=$HOME/golden-out/factory-$p-2026-10-09/questions
  python3 scripts/golden/run_golden.py --base-url https://127.0.0.1:8095 --cacert ~/llmctl/cert/ca/ca.crt --key-file $HOME/.cache/gk/k --profile $p --permute-groups --max-options ${MO[$p]} --timeout 120 --run-id questions-1 --out-dir $o > $o/run-questions.log 2>&1
  echo "done $p rc=$?" >> ~/llmctl-factory-logs/golden2-progress.log
done
echo ALLDONE >> ~/llmctl-factory-logs/golden2-progress.log; rm -f $HOME/.cache/gk/k
