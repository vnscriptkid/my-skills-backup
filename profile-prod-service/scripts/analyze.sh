#!/usr/bin/env bash
# Print the standard views for one pod dir written by capture.sh.
# Usage: bash analyze.sh <pod-dir> [code-regex, default carousell/]
set -u
D=${1:?pod dir}
RE=${2:-carousell/}
P="go tool pprof"
section() { printf '\n##### %s #####\n' "$1"; }

# callers of the top flat non-runtime frames (library leaves like reflect.* or pq.textDecode show no caller in -top)
peek_top() { # file sample_index
  $P -top -nodecount=15 ${2:+-sample_index=$2} "$1" 2>/dev/null |
    awk 'f {$1=$2=$3=$4=$5=""; sub(/^ +/, ""); print} /flat%/ {f=1}' |
    grep -vE '^(runtime\.|internal/runtime|syscall\.|aeshash|memeqbody|indexbyte)' | head -5 |
    while IFS= read -r fn; do
      esc=$(printf '%s' "$fn" | sed 's/[][\.*^$()+?{}|]/\\&/g')
      echo "--- callers of $fn"
      $P -peek "^${esc}\$" ${2:+-sample_index=$2} "$1" 2>/dev/null |
        awk '/flat%/ {f=1; next} f && /\| +[^ ]/ {print} f && /^-+\+/ {n++} n==2 {exit}' | head -8
    done
}

if [ -f "$D/cpu.pb.gz" ]; then
  section "CPU: header + flat top 25"
  $P -top -nodecount=25 "$D/cpu.pb.gz" 2>/dev/null | sed -n '1,35p'
  section "CPU: GC share (gcBgMarkWorker + mallocgc cum %)"
  $P -top -cum -nodecount=2000 "$D/cpu.pb.gz" 2>/dev/null | grep -E 'runtime\.(gcBgMarkWorker|mallocgc)$'
  section "CPU: background metrics cost (hystrix stream, prometheus scrape)"
  $P -top -cum -nodecount=2000 "$D/cpu.pb.gz" 2>/dev/null | grep -E 'StreamHandler\)\.loop$|rolling\.\(\*Timing\)\.Percentile$|promhttp\.HandlerForTransactional\.func1$'
  section "CPU: cumulative, code paths matching $RE"
  $P -top -cum -nodecount=2000 "$D/cpu.pb.gz" 2>/dev/null | grep -E "$RE" | head -45
  section "CPU: callers of top flat frames"
  peek_top "$D/cpu.pb.gz"
fi

section "HEAP in-use: total + flat top 20"
$P -top -nodecount=20 -sample_index=inuse_space "$D/heap.pb.gz" 2>/dev/null | sed -n '4,30p'
section "HEAP in-use: cumulative, code paths"
$P -top -cum -nodecount=2000 -sample_index=inuse_space "$D/heap.pb.gz" 2>/dev/null | grep -E "$RE" | head -30

section "ALLOCS since process start: total + flat top 20"
$P -top -nodecount=20 -sample_index=alloc_space "$D/allocs.pb.gz" 2>/dev/null | sed -n '4,30p'
section "ALLOCS: cumulative, code paths"
$P -top -cum -nodecount=2000 -sample_index=alloc_space "$D/allocs.pb.gz" 2>/dev/null | grep -E "$RE" | head -45
section "ALLOCS: background metrics + periodic reloads"
$P -top -cum -nodecount=3000 -sample_index=alloc_space "$D/allocs.pb.gz" 2>/dev/null | grep -E 'StreamHandler\)\.loop$|promhttp\.HandlerForTransactional\.func1$|category\.loadData$'
section "ALLOCS: callers of top flat frames"
peek_top "$D/allocs.pb.gz" alloc_space

if [ -f "$D/metrics.txt.gz" ]; then
  section "METRICS: payload bytes, total series, top families"
  gzip -dc "$D/metrics.txt.gz" | wc -c
  gzip -dc "$D/metrics.txt.gz" | grep -vc '^#'
  gzip -dc "$D/metrics.txt.gz" | grep -v '^#' | sed -E 's/[{ ].*//; s/_(bucket|sum|count)$//' | sort | uniq -c | sort -rn | head -12
  TOP=$(gzip -dc "$D/metrics.txt.gz" | grep -v '^#' | sed -E 's/[{ ].*//; s/_(bucket|sum|count)$//' | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')
  section "METRICS: distinct values per label in $TOP"
  gzip -dc "$D/metrics.txt.gz" | grep -E "^${TOP}(_bucket|_sum|_count)?\{" | grep -oE '[a-zA-Z_]+="[^"]*"' | sort -u |
    awk -F= '{n[$1]++} END {for (l in n) print n[l]"\t"l}' | sort -rn
fi

section "GOROUTINES: total + who created them"
head -1 "$D/goroutine.txt"
if [ -f "$D/goroutine-full.txt" ]; then
  grep -E '^created by ' "$D/goroutine-full.txt" | sed -E 's/^created by //; s/ in goroutine [0-9]+$//' | sort | uniq -c | sort -rn | head -12
else
  awk '/^[0-9]+ @/{n=$1; next} n && /^#/{print n"\t"$3; n=0}' "$D/goroutine.txt" |
    awk -F'\t' '{a[$2]+=$1} END {for (k in a) print a[k]"\t"k}' | sort -rn | head -12
fi

section "POD"
cat "$D/pod.txt" 2>/dev/null
