#!/usr/bin/env bash
# churn.sh — measure whether a project is progressing or just churning
#
# Analyzes git history to distinguish real progress from busy work.
# Works on any git repo. Run with: ./churn.sh [number_of_commits]
#
# Metrics:
#   - Net growth: are files/lines accumulating or just being rewritten?
#   - Rewrite ratio: how often are recently-written lines deleted?
#   - Unique files touched: breadth of change vs. same-file churn
#   - New file rate: is the project expanding or just editing in place?

set -euo pipefail

N=${1:-20}

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "Error: not a git repository" >&2
  exit 1
fi

echo "=== Churn Report (last $N commits) ==="
echo ""

# Gather stats
total_added=0
total_deleted=0
total_files_changed=0
new_files=0
commits_analyzed=0
declare -A file_touch_count 2>/dev/null || true
touched_files=""

# Detect root commit (has no parent)
ROOT_HASH=$(git rev-list --max-parents=0 HEAD 2>/dev/null | head -1)

while IFS= read -r hash; do
  commits_analyzed=$((commits_analyzed + 1))
  [ "$hash" = "$ROOT_HASH" ] && continue
  
  # Get diffstat for this commit
  while IFS=$'\t' read -r added deleted file; do
    [ -z "$file" ] && continue
    [ "$added" = "-" ] && added=0
    [ "$deleted" = "-" ] && deleted=0
    total_added=$((total_added + added))
    total_deleted=$((total_deleted + deleted))
    total_files_changed=$((total_files_changed + 1))
    touched_files="$touched_files"$'\n'"$file"
  done < <(git diff --numstat "${hash}^" "$hash" 2>/dev/null || true)
  
  # Count new files in this commit
  new_in_commit=$(git diff --diff-filter=A --name-only "${hash}^" "$hash" 2>/dev/null | wc -l | tr -d ' ')
  new_files=$((new_files + new_in_commit))
  
done < <(git log --format="%H" -n "$N" 2>/dev/null)

# Unique files
unique_files=$(echo "$touched_files" | sort -u | grep -c '.' || echo 0)

# Calculations
net_change=$((total_added - total_deleted))
if [ "$total_added" -gt 0 ]; then
  rewrite_pct=$((total_deleted * 100 / total_added))
else
  rewrite_pct=0
fi

if [ "$total_files_changed" -gt 0 ]; then
  avg_files_per_commit=$((total_files_changed / commits_analyzed))
else
  avg_files_per_commit=0
fi

echo "Commits analyzed:    $commits_analyzed"
echo "Lines added:         +$total_added"
echo "Lines deleted:       -$total_deleted"
echo "Net change:          $net_change lines"
echo "Rewrite ratio:       ${rewrite_pct}% (deleted/added)"
echo ""
echo "Total file edits:    $total_files_changed"
echo "Unique files:        $unique_files"
echo "New files created:   $new_files"
echo "Avg files/commit:    $avg_files_per_commit"
echo ""

# Interpretation
echo "--- Assessment ---"
if [ "$rewrite_pct" -gt 80 ]; then
  echo "High churn: most new lines replace old ones. The project may be"
  echo "thrashing rather than progressing."
elif [ "$rewrite_pct" -gt 50 ]; then
  echo "Moderate churn: significant rewriting happening alongside growth."
  echo "Could be healthy refactoring or indecisive iteration."
elif [ "$net_change" -le 0 ]; then
  echo "Shrinking: the project is getting smaller. This is fine if it's"
  echo "intentional simplification, concerning if features are expected."
else
  echo "Net growth with low rewrite ratio. The project appears to be"
  echo "making forward progress."
fi

if [ "$unique_files" -le 1 ] && [ "$commits_analyzed" -gt 3 ]; then
  echo ""
  echo "Note: only $unique_files unique file(s) touched across $commits_analyzed commits."
  echo "Very narrow focus — either deep work on one thing or tunnel vision."
fi

echo ""
echo "=== End of report ==="
