#!/bin/bash
# Append one resource-usage row to a CSV. Runs ON the remote every 5 minutes (a
# LaunchAgent installed by install-usage-sampler.sh), so the history keeps growing
# while the laptop sleeps. Answers "how many more devs can this box carry?" with
# real numbers instead of a guess. Plain macOS tools only, nothing to install.
set -uo pipefail
OUT="${USAGE_CSV:-$HOME/Library/Logs/agent-mac-ops-usage.csv}"
GB=1073741824

[ -s "$OUT" ] || echo "ts,load1,ncpu,cpu_busy_pct,mem_total_gb,mem_used_gb,compressed_gb,swap_used_gb,pressure_level,disk_free_gb,claude_sessions,claude_by_user,claude_rss_gb,node_rss_gb,fseventsd_rss_gb" > "$OUT"

ncpu=$(sysctl -n hw.ncpu)
mem_total=$(sysctl -n hw.memsize)
load1=$(sysctl -n vm.loadavg | awk '{print $2}')
pressure=$(sysctl -n kern.memorystatus_vm_pressure_level)

# Second sample of `top` is the real one; the first covers time since boot.
idle=$(top -l 2 -n 0 -s 1 | awk '/CPU usage/{v=$7} END{sub("%","",v); print v}')
cpu_busy=$(awk -v i="${idle:-0}" 'BEGIN{printf "%.1f", 100-i}')

read -r used compressed < <(vm_stat | awk -v gb=$GB '
  /page size of/          {ps=$8}
  /Pages active/          {a=$3}
  /Pages wired down/      {w=$4}
  /occupied by compressor/{c=$5}
  END{printf "%.1f %.1f\n", (a+w+c)*ps/gb, c*ps/gb}')
swap=$(sysctl -n vm.swapusage | awk '{for(i=1;i<=NF;i++) if($i=="used") {v=$(i+2); sub("M","",v); printf "%.1f", v/1024}}')
disk_free=$(df -k /System/Volumes/Data | awk 'NR==2{printf "%.0f", $4/1048576}')

# Claude CLI processes, per user, so a second dev shows up as their own column value.
procs=$(ps -Ao user=,rss=,comm=)
read -r sessions claude_rss < <(awk -v gb=$GB '$3 ~ /\/claude$/ {n++; r+=$2} END{printf "%d %.2f\n", n, r*1024/gb}' <<<"$procs")
by_user=$(awk '$3 ~ /\/claude$/ {n[$1]++} END{for(u in n) printf "%s%s:%d", (s++?";":""), u, n[u]}' <<<"$procs")
node_rss=$(awk -v gb=$GB '$3 ~ /(^|\/)node$/ {r+=$2} END{printf "%.2f", r*1024/gb}' <<<"$procs")
fse_rss=$(awk -v gb=$GB '$3 ~ /fseventsd$/ {r+=$2} END{printf "%.2f", r*1024/gb}' <<<"$procs")

printf '%s,%s,%s,%s,%.0f,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
  "$(date '+%F %T')" "$load1" "$ncpu" "$cpu_busy" "$(awk -v m="$mem_total" -v gb=$GB 'BEGIN{print m/gb}')" \
  "$used" "$compressed" "${swap:-0}" "$pressure" "$disk_free" \
  "$sessions" "${by_user:-none}" "$claude_rss" "$node_rss" "$fse_rss" >> "$OUT"
