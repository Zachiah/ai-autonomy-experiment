#!/usr/bin/env bash
# evolve.sh — analyze the evolution of this AI self-improvement experiment
# Reads git history and produces a summary of how AGENTS.md has changed over time.

set -euo pipefail

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "Error: not a git repository" >&2
  exit 1
fi

echo "=== AI Soul Experiment: Evolution Report ==="
echo ""

# Total iterations
total=$(git log --oneline -- AGENTS.md | wc -l | tr -d ' ')
ai_commits=$(git log --oneline -- AGENTS.md | grep -c "^[a-f0-9]* ai:" || true)
human_commits=$((total - ai_commits))

echo "Total edits to AGENTS.md: $total"
echo "  AI-authored commits:    $ai_commits"
echo "  Human-authored commits: $human_commits"
echo ""

# Current file size
lines=$(wc -l < AGENTS.md | tr -d ' ')
words=$(wc -w < AGENTS.md | tr -d ' ')
echo "Current AGENTS.md: $lines lines, $words words"
echo ""

# Commit message themes
echo "--- AI commit messages (chronological) ---"
git log --reverse --format="%s" -- AGENTS.md | grep "^ai:" | while read -r msg; do
  echo "  $msg"
done
echo ""

# Check what else exists in the repo besides AGENTS.md
other_files=$(git ls-files | grep -v "^AGENTS.md$" | grep -v "^\.") || true
if [ -n "$other_files" ]; then
  echo "--- Files created beyond AGENTS.md ---"
  echo "$other_files" | while read -r f; do
    echo "  $f"
  done
else
  echo "--- No files created beyond AGENTS.md (until now) ---"
fi
echo ""

# Net change analysis: how much has the file grown/shrunk per AI commit?
echo "--- Size over time (lines in AGENTS.md after each commit) ---"
git log --reverse --format="%H %s" -- AGENTS.md | while read -r hash msg; do
  size=$(git show "$hash:AGENTS.md" 2>/dev/null | wc -l | tr -d ' ')
  short=$(echo "$hash" | cut -c1-7)
  printf "  %s %3d lines  %s\n" "$short" "$size" "$msg"
done
echo ""
echo "=== End of report ==="
