#!/usr/bin/env bash
# coupling.sh — find files that change together, revealing hidden dependencies
#
# If two files always change in the same commit, they're coupled —
# even if they share no imports or references. This temporal coupling
# often signals design problems: shotgun surgery, split responsibilities,
# or undocumented contracts between modules.
#
# Complements churn.sh (repo health) and hotspots.sh (per-file rework)
# by adding a third dimension: relationships between files.
#
# Usage: ./coupling.sh [number_of_commits] [min_coupling_count]

set -euo pipefail

N=${1:-100}
MIN_COUPLED=${2:-3}

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "Error: not a git repository" >&2
  exit 1
fi

echo "=== Coupling Report (last $N commits, min $MIN_COUPLED co-changes) ==="
echo ""

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# For each commit, record which files changed together
commit_count=0
while IFS= read -r hash; do
  commit_count=$((commit_count + 1))
  # Get files changed in this commit (skip root commit which has no parent)
  if git rev-parse "${hash}^" &>/dev/null; then
    git diff --name-only "${hash}^" "$hash" 2>/dev/null | sort > "$tmpdir/files_$hash"
  else
    git diff-tree --no-commit-id --name-only -r "$hash" 2>/dev/null | sort > "$tmpdir/files_$hash"
  fi
done < <(git log --format="%H" -n "$N" 2>/dev/null)

echo "Commits analyzed: $commit_count"
echo ""

# Generate all pairs of files that co-changed and count occurrences
pair_file="$tmpdir/pairs"
> "$pair_file"

for f in "$tmpdir"/files_*; do
  file_count=$(wc -l < "$f" | tr -d ' ')
  # Skip commits with too many files (merges, bulk reformats) or single-file commits
  [ "$file_count" -le 1 ] && continue
  [ "$file_count" -gt 20 ] && continue

  # Generate all pairs using awk (much faster than nested bash loops)
  awk '
  { files[NR] = $0 }
  END {
    for (i = 1; i < NR; i++)
      for (j = i + 1; j <= NR; j++)
        print files[i] "|" files[j]
  }
  ' "$f"
done > "$pair_file"

# Count and rank pairs
echo "File A                                    File B                                    Co-changes"
echo "--------------------------------------------------------------------------------------------------------------"

sort "$pair_file" | uniq -c | sort -rn | head -20 | while read -r count pair; do
  [ "$count" -lt "$MIN_COUPLED" ] && continue
  file_a="${pair%%|*}"
  file_b="${pair##*|}"
  printf "%-41s %-41s %5d\n" "$file_a" "$file_b" "$count"
done

echo ""

# Summary stats
total_pairs=$(sort "$pair_file" | uniq | wc -l | tr -d ' ')
coupled_pairs=$(sort "$pair_file" | uniq -c | sort -rn | awk -v min="$MIN_COUPLED" '$1 >= min { count++ } END { print count+0 }')

echo "Total unique file pairs that co-changed: $total_pairs"
echo "Pairs meeting threshold ($MIN_COUPLED+):  $coupled_pairs"
echo ""

if [ "$coupled_pairs" -gt 0 ]; then
  echo "--- Interpretation ---"
  echo "Tightly coupled files may indicate:"
  echo "  - Responsibilities split across files that belong together"
  echo "  - Undocumented contracts (change one, must change the other)"
  echo "  - Opportunities to refactor or co-locate related code"
else
  echo "--- Interpretation ---"
  echo "No strong coupling detected. Either the codebase is well-decoupled,"
  echo "or there isn't enough history to detect patterns."
fi

echo ""
echo "=== End of report ==="
