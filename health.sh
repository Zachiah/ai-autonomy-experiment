#!/usr/bin/env bash
# health.sh — unified codebase health check
#
# Runs the full diagnostic suite (churn, hotspots, coupling, trend)
# against a git repo and produces a single composite report with
# an overall health grade.
#
# The individual tools answer separate questions:
#   churn.sh    — how much rework is happening?
#   hotspots.sh — where is it concentrated?
#   coupling.sh — what hidden dependencies exist?
#   trend.sh    — is it getting better or worse?
#
# This tool integrates them into a diagnosis. Individual tool output
# is suppressed; only the synthesized findings are shown.
#
# Usage: ./health.sh [number_of_commits]

set -euo pipefail

N=${1:-50}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "Error: not a git repository" >&2
  exit 1
fi

available=$(git log --format="%H" | wc -l | tr -d ' ')
if [ "$available" -lt 4 ]; then
  echo "Error: need at least 4 commits for meaningful analysis (found $available)" >&2
  exit 1
fi

# Clamp N to available commits
if [ "$N" -gt "$available" ]; then
  N=$available
fi

echo "=== Codebase Health Report ==="
echo "Repository: $(basename "$(git rev-parse --show-toplevel)")"
echo "Commits analyzed: $N (of $available total)"
echo "Period: $(git log --format='%as' -1 --skip=$((N-1)))..$(git log --format='%as' -1)"
echo ""

# Detect root commit (has no parent, breaks git diff hash^ hash)
ROOT_HASH=$(git rev-list --max-parents=0 HEAD 2>/dev/null | head -1)

# ── 1. Churn metrics (inline, not shelling out) ──

total_added=0
total_deleted=0
total_file_edits=0
new_files=0
touched_files=""

while IFS= read -r hash; do
  [ "$hash" = "$ROOT_HASH" ] && continue
  while IFS=$'\t' read -r added deleted file; do
    [ -z "$file" ] && continue
    [ "$added" = "-" ] && added=0
    [ "$deleted" = "-" ] && deleted=0
    total_added=$((total_added + added))
    total_deleted=$((total_deleted + deleted))
    total_file_edits=$((total_file_edits + 1))
    touched_files="$touched_files"$'\n'"$file"
  done < <(git diff --numstat "${hash}^" "$hash" 2>/dev/null || true)

  new_count=$(git diff --diff-filter=A --name-only "${hash}^" "$hash" 2>/dev/null | wc -l | tr -d ' ')
  new_files=$((new_files + new_count))
done < <(git log --format="%H" -n "$N" 2>/dev/null)

unique_files=$(echo "$touched_files" | sort -u | grep -c '.' 2>/dev/null || echo 0)
net_change=$((total_added - total_deleted))

if [ "$total_added" -gt 0 ]; then
  rewrite_pct=$((total_deleted * 100 / total_added))
else
  rewrite_pct=0
fi

# ── 2. Hotspot analysis (find worst offenders) ──

tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

while IFS= read -r hash; do
  [ "$hash" = "$ROOT_HASH" ] && continue
  while IFS=$'\t' read -r added deleted file; do
    [ -z "$file" ] && continue
    [ "$added" = "-" ] && added=0
    [ "$deleted" = "-" ] && deleted=0
    echo "$file $added $deleted"
  done < <(git diff --numstat "${hash}^" "$hash" 2>/dev/null || true)
done < <(git log --format="%H" -n "$N" 2>/dev/null) > "$tmpfile"

hotspot_count=$(awk '
{
  file = $1; adds[file] += $2; dels[file] += $3; touches[file] += 1
}
END {
  count = 0
  for (f in adds) {
    a = adds[f]; d = dels[f]; t = touches[f]
    rr = (a > 0) ? int(d * 100 / a) : 0
    if (rr > 80 && t >= 3) count++
  }
  print count
}
' "$tmpfile")

top_hotspot=$(awk '
{
  file = $1; adds[file] += $2; dels[file] += $3; touches[file] += 1
}
END {
  max_vol = 0; max_file = ""
  for (f in adds) {
    vol = adds[f] + dels[f]
    if (vol > max_vol) { max_vol = vol; max_file = f; max_rr = (adds[f] > 0) ? int(dels[f] * 100 / adds[f]) : 0; max_t = touches[f] }
  }
  if (max_file != "") printf "%s (%d%% rewrite, %d touches)", max_file, max_rr, max_t
}
' "$tmpfile")

# ── 3. Coupling check ──

pair_tmpdir=$(mktemp -d)
trap 'rm -f "$tmpfile"; rm -rf "$pair_tmpdir"' EXIT

while IFS= read -r hash; do
  [ "$hash" = "$ROOT_HASH" ] && continue
  if git rev-parse "${hash}^" &>/dev/null; then
    git diff --name-only "${hash}^" "$hash" 2>/dev/null | sort > "$pair_tmpdir/files_$hash"
  else
    git diff-tree --no-commit-id --name-only -r "$hash" 2>/dev/null | sort > "$pair_tmpdir/files_$hash"
  fi
done < <(git log --format="%H" -n "$N" 2>/dev/null)

pair_file="$pair_tmpdir/pairs"
> "$pair_file"

for f in "$pair_tmpdir"/files_*; do
  file_count=$(wc -l < "$f" | tr -d ' ')
  [ "$file_count" -le 1 ] && continue
  [ "$file_count" -gt 20 ] && continue
  awk '{ files[NR] = $0 } END { for (i = 1; i < NR; i++) for (j = i + 1; j <= NR; j++) print files[i] "|" files[j] }' "$f"
done > "$pair_file"

coupled_pairs=$(sort "$pair_file" | uniq -c | sort -rn | awk '$1 >= 3 { count++ } END { print count+0 }')
top_couple=$(sort "$pair_file" | uniq -c | sort -rn | head -1 | awk '{ split($2, a, "|"); printf "%s <-> %s (%d co-changes)", a[1], a[2], $1 }')

# ── 4. Trend (compare halves) ──

half=$((N / 2))
trend_label="UNKNOWN"

if [ "$half" -ge 2 ]; then
  # Newer half: first $half commits in log (most recent)
  new_added=0; new_deleted=0
  count=0
  while IFS= read -r hash; do
    [ "$hash" = "$ROOT_HASH" ] && continue
    count=$((count + 1))
    [ "$count" -gt "$half" ] && break
    while IFS=$'\t' read -r added deleted file; do
      [ -z "$file" ] && continue
      [ "$added" = "-" ] && added=0
      [ "$deleted" = "-" ] && deleted=0
      new_added=$((new_added + added))
      new_deleted=$((new_deleted + deleted))
    done < <(git diff --numstat "${hash}^" "$hash" 2>/dev/null || true)
  done < <(git log --format="%H" -n "$N" 2>/dev/null)

  # Older half: remaining commits
  old_added=0; old_deleted=0
  count=0
  while IFS= read -r hash; do
    [ "$hash" = "$ROOT_HASH" ] && continue
    count=$((count + 1))
    [ "$count" -le "$half" ] && continue
    while IFS=$'\t' read -r added deleted file; do
      [ -z "$file" ] && continue
      [ "$added" = "-" ] && added=0
      [ "$deleted" = "-" ] && deleted=0
      old_added=$((old_added + added))
      old_deleted=$((old_deleted + deleted))
    done < <(git diff --numstat "${hash}^" "$hash" 2>/dev/null || true)
  done < <(git log --format="%H" -n "$N" 2>/dev/null)

  if [ "$old_added" -gt 0 ]; then old_rr=$((old_deleted * 100 / old_added)); else old_rr=0; fi
  if [ "$new_added" -gt 0 ]; then new_rr=$((new_deleted * 100 / new_added)); else new_rr=0; fi

  rr_delta=$((new_rr - old_rr))
  if [ "$rr_delta" -gt 15 ]; then
    trend_label="WORSENING"
  elif [ "$rr_delta" -lt -15 ]; then
    trend_label="IMPROVING"
  else
    trend_label="STABLE"
  fi
  trend_detail="${old_rr}% -> ${new_rr}% rewrite ratio"
fi

# ── Scoring ──

score=100

# Rewrite ratio penalty (0-30 points)
if [ "$rewrite_pct" -gt 90 ]; then
  score=$((score - 30))
elif [ "$rewrite_pct" -gt 70 ]; then
  score=$((score - 20))
elif [ "$rewrite_pct" -gt 50 ]; then
  score=$((score - 10))
fi

# Hotspot penalty (0-20 points)
if [ "$hotspot_count" -gt 5 ]; then
  score=$((score - 20))
elif [ "$hotspot_count" -gt 2 ]; then
  score=$((score - 10))
elif [ "$hotspot_count" -gt 0 ]; then
  score=$((score - 5))
fi

# Coupling penalty (0-15 points)
if [ "$coupled_pairs" -gt 10 ]; then
  score=$((score - 15))
elif [ "$coupled_pairs" -gt 5 ]; then
  score=$((score - 10))
elif [ "$coupled_pairs" -gt 0 ]; then
  score=$((score - 5))
fi

# Trend penalty (0-20 points)
if [ "$trend_label" = "WORSENING" ]; then
  score=$((score - 20))
elif [ "$trend_label" = "UNKNOWN" ]; then
  score=$((score - 5))
fi

# File breadth bonus (narrow focus is not always bad, but diversity is a sign of progress)
if [ "$unique_files" -le 1 ] && [ "$N" -gt 5 ]; then
  score=$((score - 10))
fi

# Clamp
[ "$score" -lt 0 ] && score=0

# Grade
if [ "$score" -ge 80 ]; then
  grade="A"
  grade_desc="Healthy"
elif [ "$score" -ge 60 ]; then
  grade="B"
  grade_desc="Minor concerns"
elif [ "$score" -ge 40 ]; then
  grade="C"
  grade_desc="Needs attention"
elif [ "$score" -ge 20 ]; then
  grade="D"
  grade_desc="Significant problems"
else
  grade="F"
  grade_desc="Critical"
fi

# ── Output ──

echo "┌─────────────────────────────────────────────┐"
printf "│  Overall Grade: %-1s (%s)%*s│\n" "$grade" "$grade_desc" $((24 - ${#grade_desc})) ""
printf "│  Score: %d/100%*s│\n" "$score" 30 ""
echo "└─────────────────────────────────────────────┘"
echo ""

echo "Dimensions:"
echo ""

printf "  Churn:      %3d%% rewrite ratio  |  +%d/-%d lines  |  net %+d\n" \
  "$rewrite_pct" "$total_added" "$total_deleted" "$net_change"

printf "  Hotspots:   %d file(s) churning heavily" "$hotspot_count"
if [ -n "$top_hotspot" ]; then
  printf "  (worst: %s)" "$top_hotspot"
fi
echo ""

printf "  Coupling:   %d tightly-coupled file pairs" "$coupled_pairs"
if [ -n "$top_couple" ] && [ "$coupled_pairs" -gt 0 ]; then
  printf "  (top: %s)" "$top_couple"
fi
echo ""

printf "  Trend:      %s" "$trend_label"
if [ -n "${trend_detail:-}" ]; then
  printf "  (%s)" "$trend_detail"
fi
echo ""

printf "  Breadth:    %d unique files, %d new files created\n" "$unique_files" "$new_files"

echo ""

# ── Recommendations ──

rec_count=0
echo "Recommendations:"

if [ "$rewrite_pct" -gt 70 ]; then
  rec_count=$((rec_count + 1))
  echo "  $rec_count. High rewrite ratio suggests indecision or thrashing. Consider"
  echo "     stabilizing interfaces before iterating on implementation."
fi

if [ "$hotspot_count" -gt 0 ]; then
  rec_count=$((rec_count + 1))
  echo "  $rec_count. $hotspot_count hotspot file(s) detected. Run ./hotspots.sh for details."
  echo "     Consider breaking these files into smaller, more stable units."
fi

if [ "$coupled_pairs" -gt 2 ]; then
  rec_count=$((rec_count + 1))
  echo "  $rec_count. $coupled_pairs coupled file pairs found. Run ./coupling.sh for details."
  echo "     Files that always change together may belong together."
fi

if [ "$trend_label" = "WORSENING" ]; then
  rec_count=$((rec_count + 1))
  echo "  $rec_count. Churn trend is worsening. Run ./trend.sh to see the trajectory."
  echo "     Consider pausing feature work to stabilize."
fi

if [ "$unique_files" -le 1 ] && [ "$N" -gt 5 ]; then
  rec_count=$((rec_count + 1))
  echo "  $rec_count. Only $unique_files file(s) touched across $N commits. This may"
  echo "     indicate tunnel vision or a very focused refactor."
fi

if [ "$rec_count" -eq 0 ]; then
  echo "  None — the codebase looks healthy. Keep going."
fi

echo ""
echo "Run individual tools for deeper analysis:"
echo "  ./churn.sh $N      — full churn breakdown"
echo "  ./hotspots.sh $N   — per-file rewrite rates"
echo "  ./coupling.sh $N   — temporal coupling between files"
echo "  ./trend.sh          — churn trajectory over time"
echo ""
echo "=== End of report ==="
