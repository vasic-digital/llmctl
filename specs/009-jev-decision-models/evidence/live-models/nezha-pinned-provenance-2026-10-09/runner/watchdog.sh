#!/usr/bin/env bash
# watchdog.sh <scope-unit> <samples-file> : every 10s sample PSI memory + swap free; stop the scope if full avg10>=10 or swap free<30%.
U=$1; S=$2; : > "$S"
while systemctl --user is-active --quiet "$U.scope" 2>/dev/null || [[ -z "${STARTED:-}" ]]; do
  STARTED=1
  full=$(awk '/^full/{for(i=1;i<=NF;i++) if($i ~ /^avg10=/){sub("avg10=","",$i); print $i}}' /proc/pressure/memory)
  some=$(awk '/^some/{for(i=1;i<=NF;i++) if($i ~ /^avg10=/){sub("avg10=","",$i); print $i}}' /proc/pressure/memory)
  st=$(awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{if(t>0) printf "%.1f", f*100/t; else print 100}' /proc/meminfo)
  av=$(awk '/MemAvailable/{printf "%d",$2/1024}' /proc/meminfo)
  echo "$(date -u +%T) psi_full10=$full psi_some10=$some swap_free_pct=$st mem_avail_mib=$av" >> "$S"
  if awk -v a="$full" -v s="$st" 'BEGIN{exit !(a>=10 || s<30)}'; then
    echo "$(date -u +%T) ABORT threshold hit -> stopping $U.scope" >> "$S"; systemctl --user stop "$U.scope"; exit 9; fi
  sleep 10
done
