#!/bin/bash
# Runs ON the remote (via remote-run.sh): summarize the usage CSV per day — average
# and peak of CPU, memory, swap and Claude sessions — over the last N days (default 7).
DAYS="${USAGE_DAYS:-7}"
CSV="$HOME/Library/Logs/agent-mac-ops-usage.csv"
[ -s "$CSV" ] || { echo "no usage data yet ($CSV) — run install-usage-sampler.sh"; exit 0; }
since=$(date -v-"${DAYS}"d '+%F')

echo "per day (avg / peak) since $since — $(sed 1d "$CSV" | wc -l | tr -d ' ') samples total"
printf '%-10s %6s %13s %15s %13s %13s %11s\n' day samples "cpu_busy%" "mem_used_gb" "swap_gb" "claude_sess" "fsevents_gb"
awk -F, -v since="$since" 'NR>1 { d=substr($1,1,10); if (d<since) next
  n[d]++; c[d]+=$4; m[d]+=$6; s[d]+=$8; k[d]+=$11
  if ($4>cx[d]) cx[d]=$4; if ($6>mx[d]) mx[d]=$6; if ($8>sx[d]) sx[d]=$8; if ($11>kx[d]) kx[d]=$11; if ($15>fx[d]) fx[d]=$15; tot=$5 }
  END { for (d in n) printf "%-10s %6d %6.0f /%5.0f %7.1f /%6.1f %6.1f /%5.1f %6.1f /%5d %11.1f\n", d, n[d], c[d]/n[d], cx[d], m[d]/n[d], mx[d], s[d]/n[d], sx[d], k[d]/n[d], kx[d], fx[d] }' "$CSV" | sort
echo "(memory total: $(tail -1 "$CSV" | cut -d, -f5) GB; latest row: $(tail -1 "$CSV" | cut -d, -f1))"
exit 0
