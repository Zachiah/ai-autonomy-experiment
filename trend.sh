#!/usr/bin/env bash
# trend.sh — track whether codebase health is improving or deteriorating
#
# The other tools give snapshots. This gives trajectory.
# Divides recent history into windows and measures churn metrics
# across each, showing whether the repo is stabilizing or spiraling.
#
# Answers the question: "Are things getting better or worse?"
#
# Usage: ./trend.sh [total_commits] [window_size]
#   total_commits: how far back to look (default: 60)
#   window_size:   commits per window (default: 10)

set -euo pipefail

TOTAL=${1:-60}
WINDOW=${2:-10}

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "Error: not a git repository" >&2
  exit 1
fi

# Get available commits
ALL_HASHES=()
while IFS= read -r h; do
  ALL_HASHES+=("$h")
done < <(git log --format="%H" -n "$TOTAL" 2>/dev/null)
available=${#ALL_HASHES[@]}

if [ "$available" -lt "$WINDOW" ]; then
  echo "Not enough commits. Found $available, need at least $WINDOW." >&2
  exit 1
fi

# Calculate number of complete windows
num_windows=$((available / WINDOW))
if [ "$num_windows" -lt 2 ]; then
  echo "Need at least 2 windows. Have $available commits with window size $WINDOW." >&2
  echo "Try: ./trend.sh $available $((available / 2))" >&2
  exit 1
fi

echo "=== Trend Report ==="
echo "Analyzing $available commits in $num_windows windows of $WINDOW commits each"
echo ""
echo "Window   Period                      Added  Deleted  Rewrt%  Files  New  Net"
echo "---------------------------------------------------------------------------------"

# Store metrics for trend calculation
declare -a window_rewrite_pcts
declare -a window_net_changes
declare -a window_unique_files

for ((w = 0; w < num_windows; w++)); do
  start=$((w * WINDOW))
  end=$((start + WINDOW - 1))

  # Date range for this window
  first_date=$(git log --format="%as" -1 --skip=$end "${ALL_HASHES[0]}" 2>/dev/null || git show -s --format="%as" "${ALL_HASHES[$end]}" 2>/dev/null)
  last_date=$(git show -s --format="%as" "${ALL_HASHES[$start]}" 2>/dev/null)

  w_added=0
  w_deleted=0
  w_new=0
  w_files=""

  for ((i = start; i <= end && i < available; i++)); do
    hash="${ALL_HASHES[$i]}"

    while IFS=$'\t' read -r added deleted file; do
      [ -z "$file" ] && continue
      [ "$added" = "-" ] && added=0
      [ "$deleted" = "-" ] && deleted=0
      w_added=$((w_added + added))
      w_deleted=$((w_deleted + deleted))
      w_files="$w_files"$'\n'"$file"
    done < <(git diff --numstat "${hash}^" "$hash" 2>/dev/null || true)

    new_count=$(git diff --diff-filter=A --name-only "${hash}^" "$hash" 2>/dev/null | wc -l | tr -d ' ')
    w_new=$((w_new + new_count))
  done

  w_net=$((w_added - w_deleted))
  if [ "$w_added" -gt 0 ]; then
    w_rewrite=$((w_deleted * 100 / w_added))
  else
    w_rewrite=0
  fi
  w_unique=$(echo "$w_files" | sort -u | grep -c '.' 2>/dev/null || echo 0)

  window_rewrite_pcts+=("$w_rewrite")
  window_net_changes+=("$w_net")
  window_unique_files+=("$w_unique")

  # Window label: oldest first
  window_label=$((num_windows - w))
  period="${first_date}..${last_date}"

  printf "  %2d     %-27s %5d  %7d   %3d%%  %5d  %3d  %+d\n" \
    "$window_label" "$period" "$w_added" "$w_deleted" "$w_rewrite" "$w_unique" "$w_new" "$w_net"
done

echo ""
echo "--- Trend Analysis ---"

# Compare first half vs second half of windows
if [ "$num_windows" -ge 2 ]; then
  mid=$((num_windows / 2))

  # Older windows (higher indices = older commits)
  old_rewrite_sum=0
  old_rewrite_count=0
  for ((w = mid; w < num_windows; w++)); do
    old_rewrite_sum=$((old_rewrite_sum + window_rewrite_pcts[w]))
    old_rewrite_count=$((old_rewrite_count + 1))
  done

  # Newer windows (lower indices = newer commits)
  new_rewrite_sum=0
  new_rewrite_count=0
  for ((w = 0; w < mid; w++)); do
    new_rewrite_sum=$((new_rewrite_sum + window_rewrite_pcts[w]))
    new_rewrite_count=$((new_rewrite_count + 1))
  done

  if [ "$old_rewrite_count" -gt 0 ] && [ "$new_rewrite_count" -gt 0 ]; then
    old_avg=$((old_rewrite_sum / old_rewrite_count))
    new_avg=$((new_rewrite_sum / new_rewrite_count))
    delta=$((new_avg - old_avg))

    echo "Rewrite ratio: ${old_avg}% (older) -> ${new_avg}% (recent)"
    if [ "$delta" -gt 15 ]; then
      echo "  Churn is INCREASING. The codebase is becoming less stable."
    elif [ "$delta" -lt -15 ]; then
      echo "  Churn is DECREASING. The codebase is stabilizing."
    else
      echo "  Churn is STABLE. No significant trend."
    fi
  fi

  # File breadth trend
  old_files_sum=0
  new_files_sum=0
  for ((w = mid; w < num_windows; w++)); do
    old_files_sum=$((old_files_sum + window_unique_files[w]))
  done
  for ((w = 0; w < mid; w++)); do
    new_files_sum=$((new_files_sum + window_unique_files[w]))
  done
  old_files_avg=$((old_files_sum / old_rewrite_count))
  new_files_avg=$((new_files_sum / new_rewrite_count))

  echo ""
  echo "File breadth: ${old_files_avg} files/window (older) -> ${new_files_avg} files/window (recent)"
  if [ "$new_files_avg" -gt "$((old_files_avg + 2))" ]; then
    echo "  Scope is EXPANDING. More parts of the codebase being touched."
  elif [ "$new_files_avg" -lt "$((old_files_avg - 2))" ]; then
    echo "  Scope is NARROWING. Work is concentrating on fewer files."
  else
    echo "  Scope is STABLE."
  fi
fi

echo ""
echo "=== End of report ==="
