#!/usr/bin/env bash
# authors.sh — analyze code ownership and knowledge distribution
#
# The other tools answer what's changing, where, and why. This one
# answers *who*: who owns what, where knowledge is concentrated,
# and where the bus factor is dangerously low.
#
# Metrics:
#   - Commits per author across the analyzed window
#   - Per-file ownership concentration (% of changes from top author)
#   - Bus factor: files touched by only one author
#   - Knowledge silos: files where one person did >80% of the work
#
# Usage: ./authors.sh [number_of_commits] [top_n_files]

set -euo pipefail

N=${1:-50}
TOP=${2:-10}

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "Error: not a git repository" >&2
  exit 1
fi

available=$(git log --format="%H" | wc -l | tr -d ' ')
if [ "$available" -lt 2 ]; then
  echo "Error: need at least 2 commits for ownership analysis (found $available)" >&2
  exit 1
fi

if [ "$N" -gt "$available" ]; then
  N=$available
fi

echo "=== Ownership Report (last $N commits) ==="
echo ""

# Detect root commit
ROOT_HASH=$(git rev-list --max-parents=0 HEAD 2>/dev/null | head -1)

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Collect per-commit author and file data
touch_log="$tmpdir/touches"
author_log="$tmpdir/authors"
> "$touch_log"
> "$author_log"

while IFS= read -r hash; do
  author=$(git log -1 --format="%aN" "$hash")
  echo "$author" >> "$author_log"
  [ "$hash" = "$ROOT_HASH" ] && continue
  while IFS=$'\t' read -r added deleted file; do
    [ -z "$file" ] && continue
    [ "$added" = "-" ] && added=0
    [ "$deleted" = "-" ] && deleted=0
    churn=$((added + deleted))
    printf '%s\t%s\t%s\n' "$file" "$author" "$churn" >> "$touch_log"
  done < <(git diff --numstat "${hash}^" "$hash" 2>/dev/null || true)
done < <(git log --format="%H" -n "$N" 2>/dev/null)

# ── 1. Commits per author ──

echo "--- Commits per author ---"
sort "$author_log" | uniq -c | sort -rn | while read -r count name; do
  pct=$((count * 100 / N))
  printf "  %-30s %4d commits  (%d%%)\n" "$name" "$count" "$pct"
done
echo ""

total_authors=$(sort -u "$author_log" | wc -l | tr -d ' ')
echo "Total authors: $total_authors"
echo ""

# ── 2. Per-file ownership (by churn volume) ──

echo "--- File ownership (top $TOP files by churn, top author's share) ---"
echo ""
echo "File                                     Top Author                       Share  Touches"
echo "----------------------------------------------------------------------------------------"

# For each file, compute total churn and each author's share
awk -F'\t' '
{
  file = $1; author = $2; churn = $3
  total[file] += churn
  by_author[file, author] += churn
  # Track all authors per file
  if (!seen[file, author]++) {
    author_list[file] = (author_list[file] ? author_list[file] SUBSEP : "") author
    author_count[file]++
  }
  touches[file]++
}
END {
  for (f in total) {
    # Find top author for this file
    max_churn = 0; top = ""
    n = split(author_list[f], authors, SUBSEP)
    for (i = 1; i <= n; i++) {
      a = authors[i]
      if (by_author[f, a] > max_churn) {
        max_churn = by_author[f, a]
        top = a
      }
    }
    share = (total[f] > 0) ? int(max_churn * 100 / total[f]) : 0
    printf "%s\t%s\t%d\t%d\t%d\n", f, top, share, touches[f], total[f]
  }
}
' "$touch_log" | sort -t$'\t' -k5 -nr | head -n "$TOP" | while IFS=$'\t' read -r file top_author share touch_count total_churn; do
  printf "%-40s %-30s %4d%%  %5d\n" "$file" "$top_author" "$share" "$touch_count"
done

echo ""

# ── 3. Bus factor and knowledge silos ──

silo_file="$tmpdir/silos"
bus_factor_file="$tmpdir/busfactor"

awk -F'\t' '
{
  file = $1; author = $2; churn = $3
  total[file] += churn
  by_author[file, author] += churn
  if (!seen[file, author]++) {
    author_list[file] = (author_list[file] ? author_list[file] SUBSEP : "") author
    author_count[file]++
  }
}
END {
  silos = 0; single_author = 0
  for (f in total) {
    n = split(author_list[f], authors, SUBSEP)
    # Find top author share
    max_churn = 0
    for (i = 1; i <= n; i++) {
      a = authors[i]
      if (by_author[f, a] > max_churn) max_churn = by_author[f, a]
    }
    share = (total[f] > 0) ? int(max_churn * 100 / total[f]) : 0
    if (n == 1) single_author++
    if (share > 80) silos++
    printf "%s\t%d\t%d\n", f, n, share
  }
  # Print summary to stderr so we can capture it
  printf "SINGLE_AUTHOR=%d\nSILOS=%d\nTOTAL_FILES=%d\n", single_author, silos, length(total) > "/dev/stderr"
}
' "$touch_log" > "$silo_file" 2> "$bus_factor_file"

# Read summary values
single_author=$(grep "SINGLE_AUTHOR=" "$bus_factor_file" | cut -d= -f2)
silos=$(grep "SILOS=" "$bus_factor_file" | cut -d= -f2)
total_files=$(grep "TOTAL_FILES=" "$bus_factor_file" | cut -d= -f2)

echo "--- Knowledge distribution ---"
echo ""
echo "  Files touched:              $total_files"
echo "  Single-author files:        $single_author"
echo "  Knowledge silos (>80%):     $silos"
echo ""

if [ "$total_files" -gt 0 ]; then
  silo_pct=$((silos * 100 / total_files))
  single_pct=$((single_author * 100 / total_files))
else
  silo_pct=0
  single_pct=0
fi

# ── 4. Files at risk (single author + high churn) ──

at_risk=$(awk -F'\t' '$2 == 1 { print $1 }' "$silo_file" | while IFS= read -r file; do
  # Check if this file has significant churn
  file_churn=$(awk -F'\t' -v f="$file" '$1 == f { sum += $3 } END { print sum+0 }' "$touch_log")
  file_touches=$(awk -F'\t' -v f="$file" '$1 == f { count++ } END { print count+0 }' "$touch_log")
  if [ "$file_touches" -ge 3 ]; then
    author=$(awk -F'\t' -v f="$file" '$1 == f { print $2; exit }' "$touch_log")
    printf "  %-40s  sole author: %s  (%d touches)\n" "$file" "$author" "$file_touches"
  fi
done)

if [ -n "$at_risk" ]; then
  echo "--- Bus factor risks (single author, 3+ touches) ---"
  echo ""
  echo "$at_risk"
  echo ""
fi

# ── Assessment ──

echo "--- Assessment ---"

if [ "$total_authors" -eq 1 ]; then
  echo "Solo project: all changes by one author. Bus factor metrics"
  echo "don't apply, but ownership tracking can still reveal which"
  echo "areas get the most attention."
elif [ "$silo_pct" -gt 60 ]; then
  echo "High knowledge concentration: ${silo_pct}% of files have >80% of their"
  echo "changes from a single author. Consider cross-training or code review"
  echo "to spread knowledge."
elif [ "$silo_pct" -gt 30 ]; then
  echo "Moderate knowledge concentration: ${silo_pct}% of files are dominated by"
  echo "one author. Some specialization is normal, but watch for silos in"
  echo "critical paths."
else
  echo "Healthy distribution: knowledge is spread across the team."
  echo "Most files have contributions from multiple authors."
fi

echo ""
echo "=== End of report ==="
