cd ~/llmctl-3.1.0-factory
for p in "$@"; do for t in noul choice score; do
 case $t in choice) c=(--criteria "{\"billing\":\"charges and invoices\",\"tech\":\"technical failure\"}");; score) c=(--criteria "[\"not urgent\",\"low\",\"medium\",\"high\",\"critical\"]");; *) c=();; esac
 s=$(date +%s%N); out=$(./bin/llmctl decide ask --type $t --state "Customer says: I was charged twice for my invoice this month." --instructions "Triage the support message." "${c[@]}" --profile $p --json --timeout 120 2>&1 | head -c 700); e=$(date +%s%N)
 echo "$p $t wall_ms=$(( (e-s)/1000000 )) :: $(echo $out | tr "\n" " " | head -c 330)"
done; done
