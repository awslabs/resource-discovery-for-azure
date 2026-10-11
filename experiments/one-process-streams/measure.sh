#!/bin/bash
# Run one Step3 design under /usr/bin/time -l (wall, user+sys CPU of the process AND its reaped
# children) with the tree sampler alongside. macOS (ps -M, time -l).
# Usage: measure.sh <processes|runspaces|sequential> <label>; RDA_EXTRA_ENV="DOTNET_gcServer=1" for Server GC.
set -u
DESIGN=$1; LABEL=$2
HERE=$(cd "$(dirname "$0")" && pwd)
TREE=$(cd "$HERE/../.." && pwd)
OUT=${RDA_PROTO_OUT:-${TMPDIR:-/tmp}/rda-one-process-results}
mkdir -p "$OUT"
/usr/bin/time -l env -u DOTNET_ROOT ${RDA_EXTRA_ENV:-} "$(command -v pwsh)" -NoProfile -File "$HERE/Step3-Streams.ps1" -Tree "$TREE" -Design "$DESIGN" -Streams 3 -ConcurrencyLimit 6 -ResultFile "$OUT/$LABEL.json" 2> "$OUT/$LABEL.time" &
TPID=$!
sleep 1
PW=$(pgrep -P "$TPID" | head -1); [ -z "$PW" ] && PW=$TPID
bash "$HERE/sample-tree.sh" "$PW" "$OUT/$LABEL.sample" &
wait "$TPID"
sleep 2
echo "== $LABEL"; cat "$OUT/$LABEL.sample" 2>/dev/null; grep -E "real|user|sys" "$OUT/$LABEL.time" | head -1
