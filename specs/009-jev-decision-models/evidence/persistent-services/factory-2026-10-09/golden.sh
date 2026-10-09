cd ~/llmctl-3.1.0-factory
declare -A MO=([decide-max]=16 [decide-kev-9b]=255 [decide-pro]=20 [decide-2b]=16)
for p in decide-max decide-kev-9b decide-pro decide-2b; do
  o=$HOME/golden-out/factory-$p-2026-10-09; mkdir -p $o
  python3 scripts/golden/run_golden.py --base-url https://127.0.0.1:8095 --cacert ~/llmctl/cert/ca/ca.crt --key-file /home/milos/.cache/gk/k --profile $p --permute-groups --max-options ${MO[$p]} --timeout 120 --run-id questions-1 --out-dir $o > $o/run-questions.log 2>&1
  python3 scripts/golden/run_golden.py --base-url https://127.0.0.1:8095 --cacert ~/llmctl/cert/ca/ca.crt --key-file /home/milos/.cache/gk/k --profile $p --set probes --max-options ${MO[$p]} --timeout 120 --run-id probes-1 --out-dir $o > $o/run-probes.log 2>&1
  echo "done $p rc=$?" >> ~/llmctl-factory-logs/golden-progress.log
done
echo ALLDONE >> ~/llmctl-factory-logs/golden-progress.log
echo rm >/dev/null; rm -f /home/milos/.cache/gk/k
