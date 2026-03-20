#!/usr/bin/env bash
# intent.sh — classify why files are being rewritten
#
# The other tools measure *that* churn is happening. This one asks *why*.
#
# For each file that's been rewritten multiple times, it examines the
# pattern of changes to classify them as:
#
#   LEARNING     — each rewrite is substantially different from the last;
#                  the author is exploring the problem space
#   REFINEMENT   — small incremental adjustments to a stable approach
#   INDECISION   — content oscillates; rewrites undo or redo prior work
#
# Method:
#   For each file touched 3+ times, extract the content at each commit.
#   Compare consecutive versions using line-level similarity.
#   If similarity between non-adjacent versions (A and C) is higher than
#   between adjacent versions (A-B, B-C), the file is oscillating.
#
# Usage: ./intent.sh [number_of_commits] [min_touches]

set -euo pipefail

N=${1:-50}
MIN_TOUCHES=${2:-3}

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "Error: not a git repository" >&2
  exit 1
fi

echo "=== Intent Report (last $N commits, files touched $MIN_TOUCHES+ times) ==="
echo ""

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Collect per-file touch data using a flat file (avoids bash 4 associative arrays)
touch_log="$tmpdir/touches"
> "$touch_log"

while IFS= read -r hash; do
  while IFS=$'\t' read -r added deleted file; do
    [ -z "$file" ] && continue
    echo "$file	$hash" >> "$touch_log"
  done < <(git diff --numstat "${hash}^" "$hash" 2>/dev/null || true)
done < <(git log --format="%H" -n "$N" 2>/dev/null)

# Find files touched MIN_TOUCHES or more times
candidate_file="$tmpdir/candidates"
awk -F'\t' '{ count[$1]++ } END { for (f in count) if (count[f] >= '"$MIN_TOUCHES"') print f }' "$touch_log" | sort > "$candidate_file"

if [ ! -s "$candidate_file" ]; then
  echo "No files touched $MIN_TOUCHES+ times in the last $N commits."
  echo ""
  echo "=== End of report ==="
  exit 0
fi

# similarity: count shared lines between two files as a percentage
# Uses comm on sorted lines. Returns 0-100.
similarity() {
  local a="$1" b="$2"
  local total_a total_b shared
  total_a=$(wc -l < "$a" | tr -d ' ')
  total_b=$(wc -l < "$b" | tr -d ' ')
  if [ "$total_a" -eq 0 ] && [ "$total_b" -eq 0 ]; then
    echo 100
    return
  fi
  if [ "$total_a" -eq 0 ] || [ "$total_b" -eq 0 ]; then
    echo 0
    return
  fi
  shared=$(comm -12 <(sort "$a") <(sort "$b") | wc -l | tr -d ' ')
  local max=$total_a
  [ "$total_b" -gt "$max" ] && max=$total_b
  echo $((shared * 100 / max))
}

echo "File                                      Touches  Class        Evidence"
echo "---------------------------------------------------------------------------------"

learning=0
refinement=0
indecision=0

while IFS= read -r file; do
  # Get commit hashes for this file in chronological order
  # touch_log has newest-first; use awk to extract and tac to reverse
  hash_file="$tmpdir/hashes"
  awk -F'\t' -v target="$file" '$1 == target { print $2 }' "$touch_log" | tail -r > "$hash_file" 2>/dev/null \
    || awk -F'\t' -v target="$file" '$1 == target { print $2 }' "$touch_log" | tac > "$hash_file" 2>/dev/null \
    || awk -F'\t' -v target="$file" '$1 == target { a[NR]=$2 } END { for(i=NR;i>=1;i--) print a[i] }' "$touch_log" > "$hash_file"

  touch_count=$(wc -l < "$hash_file" | tr -d ' ')
  if [ "$touch_count" -eq 0 ]; then
    continue
  fi

  # Extract file content at each version
  version_files=()
  valid_versions=0
  while IFS= read -r h; do
    vfile="$tmpdir/v_${valid_versions}"
    if git show "$h:$file" > "$vfile" 2>/dev/null; then
      version_files+=("$vfile")
      valid_versions=$((valid_versions + 1))
    fi
  done < "$hash_file"

  if [ "$valid_versions" -lt 3 ]; then
    printf "%-41s %5d  %-11s  %s\n" "$file" "$touch_count" "UNKNOWN" "too few extractable versions"
    rm -f "$tmpdir"/v_*
    continue
  fi

  # Compute adjacent similarities (A-B, B-C, C-D, ...)
  adj_sim_sum=0
  adj_sim_count=0
  for ((i = 0; i < valid_versions - 1; i++)); do
    s=$(similarity "${version_files[$i]}" "${version_files[$((i+1))]}")
    adj_sim_sum=$((adj_sim_sum + s))
    adj_sim_count=$((adj_sim_count + 1))
  done

  # Compute skip-one similarities (A-C, B-D, ...) — detects oscillation
  skip_sim_sum=0
  skip_sim_count=0
  for ((i = 0; i < valid_versions - 2; i++)); do
    s=$(similarity "${version_files[$i]}" "${version_files[$((i+2))]}")
    skip_sim_sum=$((skip_sim_sum + s))
    skip_sim_count=$((skip_sim_count + 1))
  done

  # Compute first-to-last similarity — detects circular return
  first_last_sim=$(similarity "${version_files[0]}" "${version_files[$((valid_versions-1))]}")

  if [ "$adj_sim_count" -gt 0 ]; then
    avg_adj=$((adj_sim_sum / adj_sim_count))
  else
    avg_adj=0
  fi
  if [ "$skip_sim_count" -gt 0 ]; then
    avg_skip=$((skip_sim_sum / skip_sim_count))
  else
    avg_skip=0
  fi

  # Classification logic:
  #
  # INDECISION: skip-similarity > adjacent-similarity by a margin,
  #   meaning version C looks more like version A than version B does.
  #   The code is oscillating.
  #
  # REFINEMENT: adjacent similarity is high (>70%). Each version is
  #   a small tweak of the prior one.
  #
  # LEARNING: adjacent similarity is low (lots of change between
  #   versions) AND skip-similarity is also low (not oscillating).
  #   The code is being substantially rethought each time.

  oscillation_gap=$((avg_skip - avg_adj))

  if [ "$oscillation_gap" -gt 10 ] || { [ "$first_last_sim" -gt 80 ] && [ "$avg_adj" -lt 60 ]; }; then
    class="INDECISION"
    evidence="skip-sim ${avg_skip}% > adj-sim ${avg_adj}%, first-last ${first_last_sim}%"
    indecision=$((indecision + 1))
  elif [ "$avg_adj" -ge 70 ]; then
    class="REFINEMENT"
    evidence="adj-sim ${avg_adj}%, small changes between versions"
    refinement=$((refinement + 1))
  else
    class="LEARNING"
    evidence="adj-sim ${avg_adj}%, skip-sim ${avg_skip}%, diverging"
    learning=$((learning + 1))
  fi

  printf "%-41s %5d  %-11s  %s\n" "$file" "$touch_count" "$class" "$evidence"

  # Clean up version files
  rm -f "$tmpdir"/v_*
done < "$candidate_file"

echo ""
echo "--- Summary ---"
echo "  Learning:    $learning file(s) — exploring, each rewrite is new ground"
echo "  Refinement:  $refinement file(s) — stable approach, incremental improvement"
echo "  Indecision:  $indecision file(s) — oscillating, rewrites undo prior work"
echo ""

total_classified=$((learning + refinement + indecision))
if [ "$total_classified" -gt 0 ]; then
  if [ "$indecision" -gt "$learning" ] && [ "$indecision" -gt "$refinement" ]; then
    echo "Assessment: The dominant rewrite pattern is INDECISION."
    echo "  Consider committing to a direction before iterating."
  elif [ "$learning" -ge "$refinement" ]; then
    echo "Assessment: The dominant rewrite pattern is LEARNING."
    echo "  The codebase is actively exploring — churn is productive."
  else
    echo "Assessment: The dominant rewrite pattern is REFINEMENT."
    echo "  The codebase is stabilizing — polish work happening."
  fi
fi

echo ""
echo "=== End of report ==="
