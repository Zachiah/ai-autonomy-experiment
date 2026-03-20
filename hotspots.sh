#!/usr/bin/env bash
# hotspots.sh — find which files absorb the most rework in a git repo
#
# Complements churn.sh: while churn.sh gives a whole-repo summary,
# this tool identifies *which specific files* are being rewritten most.
# Helps distinguish productive deep work from circular editing.
#
# Usage: ./hotspots.sh [number_of_commits] [top_n_files]

set -euo pipefail

N=${1:-50}
TOP=${2:-10}

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "Error: not a git repository" >&2
  exit 1
fi

echo "=== Hotspot Report (last $N commits, top $TOP files) ==="
echo ""

# Temporary file for accumulating per-file stats
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

# Gather per-file add/delete stats across commits
while IFS= read -r hash; do
  while IFS=$'\t' read -r added deleted file; do
    [ -z "$file" ] && continue
    [ "$added" = "-" ] && added=0
    [ "$deleted" = "-" ] && deleted=0
    echo "$file $added $deleted"
  done < <(git diff --numstat "${hash}^" "$hash" 2>/dev/null || true)
done < <(git log --format="%H" -n "$N" 2>/dev/null) > "$tmpfile"

# Aggregate: for each file, sum adds, deletes, and count touches
echo "File                                      Adds   Dels  Rewrt%  Touches"
echo "------------------------------------------------------------------------"

awk '
{
  file = $1
  adds[file] += $2
  dels[file] += $3
  touches[file] += 1
}
END {
  for (f in adds) {
    a = adds[f]
    d = dels[f]
    t = touches[f]
    rr = (a > 0) ? int(d * 100 / a) : 0
    # Sort key: total churn volume (adds + deletes)
    volume = a + d
    printf "%s\t%d\t%d\t%d\t%d\t%d\n", f, a, d, rr, t, volume
  }
}
' "$tmpfile" | sort -t$'\t' -k6 -nr | head -n "$TOP" | while IFS=$'\t' read -r file adds dels rr touches volume; do
  # Check if file still exists
  if [ -f "$file" ]; then
    status="  "
  else
    status="D "
  fi
  printf "%s%-40s %5d  %5d   %3d%%   %5d\n" "$status" "$file" "$adds" "$dels" "$rr" "$touches"
done

echo ""
echo "Legend: D = file deleted from working tree"
echo "        Rewrt% = deletion/addition ratio (>80% = high churn)"
echo ""

# Identify files with high churn AND many touches (the real hotspots)
echo "--- Files likely churning (Rewrt% > 80 AND touched 3+ times) ---"
hotspot_count=0
awk '
{
  file = $1; adds[file] += $2; dels[file] += $3; touches[file] += 1
}
END {
  for (f in adds) {
    a = adds[f]; d = dels[f]; t = touches[f]
    rr = (a > 0) ? int(d * 100 / a) : 0
    if (rr > 80 && t >= 3) {
      printf "  %s — %d touches, %d%% rewrite\n", f, t, rr
    }
  }
}
' "$tmpfile" | sort | while read -r line; do
  echo "$line"
  hotspot_count=$((hotspot_count + 1))
done

# Check if anything was printed
hotspot_found=$(awk '
{
  file = $1; adds[file] += $2; dels[file] += $3; touches[file] += 1
}
END {
  for (f in adds) {
    a = adds[f]; d = dels[f]; t = touches[f]
    rr = (a > 0) ? int(d * 100 / a) : 0
    if (rr > 80 && t >= 3) { found = 1 }
  }
  print (found ? "yes" : "no")
}
' "$tmpfile")

if [ "$hotspot_found" = "no" ]; then
  echo "  (none — no files meet both thresholds)"
fi

echo ""
echo "=== End of report ==="
