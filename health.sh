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
#   intent.sh   — is the churn productive or indecisive?
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
    printf '%s\t%s\t%s\n' "$file" "$added" "$deleted"
  done < <(git diff --numstat "${hash}^" "$hash" 2>/dev/null || true)
done < <(git log --format="%H" -n "$N" 2>/dev/null) > "$tmpfile"

hotspot_count=$(awk -F'\t' '
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

top_hotspot=$(awk -F'\t' '
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

# ── 5. Intent analysis (classify churn quality) ──

intent_learning=0
intent_refinement=0
intent_indecision=0
intent_total=0

# Run intent classification inline using the same approach as intent.sh
# but only for hotspot files (touched 3+ times)
intent_candidates=$(awk -F'\t' '{ count[$1]++ } END { for (f in count) if (count[f] >= 3) print f }' "$tmpfile" | sort)

if [ -n "$intent_candidates" ]; then
  intent_tmpdir=$(mktemp -d)
  trap 'rm -f "$tmpfile"; rm -rf "$pair_tmpdir"; rm -rf "$intent_tmpdir"' EXIT

  # Build a touch log with hashes for intent analysis
  intent_touch_log="$intent_tmpdir/touches"
  > "$intent_touch_log"
  while IFS= read -r hash; do
    [ "$hash" = "$ROOT_HASH" ] && continue
    while IFS=$'\t' read -r added deleted file; do
      [ -z "$file" ] && continue
      echo "$file	$hash" >> "$intent_touch_log"
    done < <(git diff --numstat "${hash}^" "$hash" 2>/dev/null || true)
  done < <(git log --format="%H" -n "$N" 2>/dev/null)

  # similarity function (line-level, 0-100)
  _health_similarity() {
    local a="$1" b="$2"
    local total_a total_b shared
    total_a=$(wc -l < "$a" | tr -d ' ')
    total_b=$(wc -l < "$b" | tr -d ' ')
    if [ "$total_a" -eq 0 ] && [ "$total_b" -eq 0 ]; then echo 100; return; fi
    if [ "$total_a" -eq 0 ] || [ "$total_b" -eq 0 ]; then echo 0; return; fi
    shared=$(comm -12 <(sort "$a") <(sort "$b") | wc -l | tr -d ' ')
    local max=$total_a
    [ "$total_b" -gt "$max" ] && max=$total_b
    echo $((shared * 100 / max))
  }

  while IFS= read -r file; do
    [ -z "$file" ] && continue
    hash_file="$intent_tmpdir/hashes"
    awk -F'\t' -v target="$file" '$1 == target { print $2 }' "$intent_touch_log" | tail -r > "$hash_file" 2>/dev/null \
      || awk -F'\t' -v target="$file" '$1 == target { print $2 }' "$intent_touch_log" | tac > "$hash_file" 2>/dev/null \
      || awk -F'\t' -v target="$file" '$1 == target { a[NR]=$2 } END { for(i=NR;i>=1;i--) print a[i] }' "$intent_touch_log" > "$hash_file"

    touch_count=$(wc -l < "$hash_file" | tr -d ' ')
    [ "$touch_count" -lt 3 ] && continue

    version_files=()
    valid_versions=0
    while IFS= read -r h; do
      vfile="$intent_tmpdir/v_${valid_versions}"
      if git show "$h:$file" > "$vfile" 2>/dev/null; then
        version_files+=("$vfile")
        valid_versions=$((valid_versions + 1))
      fi
    done < "$hash_file"

    [ "$valid_versions" -lt 3 ] && { rm -f "$intent_tmpdir"/v_*; continue; }

    adj_sim_sum=0; adj_sim_count=0
    for ((i = 0; i < valid_versions - 1; i++)); do
      s=$(_health_similarity "${version_files[$i]}" "${version_files[$((i+1))]}")
      adj_sim_sum=$((adj_sim_sum + s)); adj_sim_count=$((adj_sim_count + 1))
    done

    skip_sim_sum=0; skip_sim_count=0
    for ((i = 0; i < valid_versions - 2; i++)); do
      s=$(_health_similarity "${version_files[$i]}" "${version_files[$((i+2))]}")
      skip_sim_sum=$((skip_sim_sum + s)); skip_sim_count=$((skip_sim_count + 1))
    done

    first_last_sim=$(_health_similarity "${version_files[0]}" "${version_files[$((valid_versions-1))]}")

    [ "$adj_sim_count" -gt 0 ] && avg_adj=$((adj_sim_sum / adj_sim_count)) || avg_adj=0
    [ "$skip_sim_count" -gt 0 ] && avg_skip=$((skip_sim_sum / skip_sim_count)) || avg_skip=0

    oscillation_gap=$((avg_skip - avg_adj))

    if [ "$oscillation_gap" -gt 10 ] || { [ "$first_last_sim" -gt 80 ] && [ "$avg_adj" -lt 60 ]; }; then
      intent_indecision=$((intent_indecision + 1))
    elif [ "$avg_adj" -ge 70 ]; then
      intent_refinement=$((intent_refinement + 1))
    else
      intent_learning=$((intent_learning + 1))
    fi
    intent_total=$((intent_total + 1))

    rm -f "$intent_tmpdir"/v_*
  done <<< "$intent_candidates"
fi

# ── Scoring ──

score=100

# Rewrite ratio penalty (0-30 points), adjusted by intent
rewrite_penalty=0
if [ "$rewrite_pct" -gt 90 ]; then
  rewrite_penalty=30
elif [ "$rewrite_pct" -gt 70 ]; then
  rewrite_penalty=20
elif [ "$rewrite_pct" -gt 50 ]; then
  rewrite_penalty=10
fi

# Intent adjustment: if churn is mostly productive (learning/refinement),
# reduce the rewrite penalty. If indecisive, increase it.
if [ "$intent_total" -gt 0 ]; then
  if [ "$intent_indecision" -eq 0 ]; then
    # All churn is productive — halve the rewrite penalty
    rewrite_penalty=$((rewrite_penalty / 2))
  elif [ "$intent_indecision" -gt "$intent_learning" ] && [ "$intent_indecision" -gt "$intent_refinement" ]; then
    # Mostly indecisive — add extra penalty (up to 10)
    rewrite_penalty=$((rewrite_penalty + 10))
    [ "$rewrite_penalty" -gt 40 ] && rewrite_penalty=40
  fi
fi
score=$((score - rewrite_penalty))

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

if [ "$intent_total" -gt 0 ]; then
  printf "  Intent:     %d learning, %d refinement, %d indecision (of %d classified)\n" \
    "$intent_learning" "$intent_refinement" "$intent_indecision" "$intent_total"
else
  printf "  Intent:     no files with 3+ touches to classify\n"
fi

printf "  Breadth:    %d unique files, %d new files created\n" "$unique_files" "$new_files"

echo ""

# ── Recommendations ──

rec_count=0
echo "Recommendations:"

if [ "$rewrite_pct" -gt 70 ]; then
  rec_count=$((rec_count + 1))
  if [ "$intent_indecision" -gt 0 ]; then
    echo "  $rec_count. High rewrite ratio with indecisive churn detected. Consider"
    echo "     committing to a direction before iterating further."
  elif [ "$intent_learning" -gt 0 ] && [ "$intent_indecision" -eq 0 ]; then
    echo "  $rec_count. High rewrite ratio, but churn appears productive (learning)."
    echo "     The exploration is healthy — consider when to converge."
  else
    echo "  $rec_count. High rewrite ratio detected. Run ./intent.sh to check whether"
    echo "     the churn is productive or indecisive."
  fi
fi

if [ "$intent_indecision" -gt 0 ]; then
  rec_count=$((rec_count + 1))
  echo "  $rec_count. $intent_indecision file(s) showing indecisive churn (oscillating rewrites)."
  echo "     Run ./intent.sh for details on which files are affected."
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
echo "  ./intent.sh $N     — classify why files are being rewritten"
echo ""
echo "=== End of report ==="
