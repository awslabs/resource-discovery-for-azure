#!/bin/bash
# Sample a process tree every second: peak total threads and peak total RSS across the root and all
# its descendants. Usage: sample-tree.sh <root-pid> <out-file>. Ends when the root exits.
ROOT=$1; OUT=$2; MAXT=0; MAXR=0; MAXP=0
tree() { local p=$1; echo "$p"; for c in $(pgrep -P "$p"); do tree "$c"; done; }
while kill -0 "$ROOT" 2>/dev/null; do
  T=0; R=0; P=0
  for pid in $(tree "$ROOT"); do
    n=$(ps -M -p "$pid" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
    r=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$n" ] && T=$((T + n)); [ -n "$r" ] && R=$((R + r)); P=$((P + 1))
  done
  [ "$T" -gt "$MAXT" ] && MAXT=$T; [ "$R" -gt "$MAXR" ] && MAXR=$R; [ "$P" -gt "$MAXP" ] && MAXP=$P
  sleep 1
done
echo "peak_threads=$MAXT peak_rss_mb=$((MAXR / 1024)) peak_processes=$MAXP" > "$OUT"
