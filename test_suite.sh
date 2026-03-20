#!/usr/bin/env bash
# test_suite.sh — validate codebase analysis tools against edge cases
#
# Creates synthetic git repos and verifies the tools produce correct output.
# Covers: non-repo dirs, single-commit repos, binary files, filenames with
# spaces, scoring sanity, minimum-commit guards, and pace analysis.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1 — $2"; }

cleanup_dirs=()
make_temp_repo() {
  local d
  d=$(mktemp -d)
  cleanup_dirs+=("$d")
  git -C "$d" init -q
  git -C "$d" config user.email "test@test.com"
  git -C "$d" config user.name "Test"
  echo "$d"
}

# Run a tool inside a specific directory (subshell to isolate cd)
run_in() {
  local dir="$1"; shift
  (cd "$dir" && bash "$@" 2>&1)
}

cleanup() {
  for d in "${cleanup_dirs[@]}"; do
    rm -rf "$d"
  done
}
trap cleanup EXIT

echo "=== Test Suite ==="
echo ""

# ── Test 1: Non-git directory ──
echo "1. Non-git directory handling"
tmpdir=$(mktemp -d)
cleanup_dirs+=("$tmpdir")
for tool in churn.sh hotspots.sh coupling.sh health.sh trend.sh evolve.sh intent.sh authors.sh; do
  if run_in "$tmpdir" "$SCRIPT_DIR/$tool" >/dev/null 2>&1; then
    fail "$tool on non-git dir" "should exit non-zero"
  else
    pass "$tool rejects non-git directory"
  fi
done

# ── Test 2: Single-commit repo ──
echo ""
echo "2. Single-commit repo"
repo=$(make_temp_repo)
echo "hello" > "$repo/file.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "first"

output=$(run_in "$repo" "$SCRIPT_DIR/churn.sh" 1 || true)
if echo "$output" | grep -q "Commits analyzed"; then
  pass "churn.sh runs on single-commit repo"
elif echo "$output" | grep -qi "error\|not enough"; then
  pass "churn.sh gracefully rejects single-commit repo"
else
  fail "churn.sh on single commit" "unexpected output"
fi

if run_in "$repo" "$SCRIPT_DIR/health.sh" 1 >/dev/null 2>&1; then
  fail "health.sh on single commit" "should require more commits"
else
  pass "health.sh rejects single-commit repo"
fi

# ── Test 3: Filenames with spaces ──
echo ""
echo "3. Filenames with spaces"
repo=$(make_temp_repo)
echo "a" > "$repo/normal.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "first"
echo "b" > "$repo/file with spaces.txt"
echo "b2" >> "$repo/normal.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "add spaced file and edit normal"
echo "c" >> "$repo/file with spaces.txt"
echo "c2" >> "$repo/normal.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "edit both files"
echo "d" >> "$repo/file with spaces.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "edit spaced only"
echo "e" >> "$repo/normal.txt"
echo "e2" >> "$repo/file with spaces.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "edit both again"

if run_in "$repo" "$SCRIPT_DIR/churn.sh" 5 >/dev/null 2>&1; then
  pass "churn.sh handles filenames with spaces"
else
  fail "churn.sh with spaced filenames" "exit code $?"
fi

# health.sh: the top hotspot must reference the spaced filename
health_output=$(run_in "$repo" "$SCRIPT_DIR/health.sh" 5 2>&1 || true)
if echo "$health_output" | grep -q "file with spaces.txt"; then
  pass "health.sh correctly reports filenames with spaces in hotspot analysis"
else
  fail "health.sh with spaced filenames" "output missing 'file with spaces.txt' in hotspot analysis"
fi

# hotspots.sh: output must contain the full filename
hotspots_output=$(run_in "$repo" "$SCRIPT_DIR/hotspots.sh" 5 2>&1 || true)
if echo "$hotspots_output" | grep -q "file with spaces.txt"; then
  pass "hotspots.sh correctly reports filenames with spaces"
else
  fail "hotspots.sh with spaced filenames" "output missing 'file with spaces.txt'"
fi

# coupling.sh: output must contain the spaced filename in coupling pairs
coupling_output=$(run_in "$repo" "$SCRIPT_DIR/coupling.sh" 5 2 2>&1 || true)
if echo "$coupling_output" | grep -q "file with spaces.txt"; then
  pass "coupling.sh correctly reports filenames with spaces in coupling output"
else
  fail "coupling.sh with spaced filenames" "output missing 'file with spaces.txt' in coupling output"
fi

# trend.sh: must handle spaced filenames without error
if run_in "$repo" "$SCRIPT_DIR/trend.sh" 5 2 >/dev/null 2>&1; then
  pass "trend.sh handles filenames with spaces"
else
  fail "trend.sh with spaced filenames" "exit code $?"
fi

# ── Test 4: Binary files ──
echo ""
echo "4. Binary files"
repo=$(make_temp_repo)
echo "text" > "$repo/readme.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "first"
dd if=/dev/urandom of="$repo/image.bin" bs=64 count=1 2>/dev/null
git -C "$repo" add . && git -C "$repo" commit -q -m "add binary"
dd if=/dev/urandom of="$repo/image.bin" bs=64 count=1 2>/dev/null
git -C "$repo" add . && git -C "$repo" commit -q -m "update binary"
echo "more" >> "$repo/readme.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "edit text"
echo "more2" >> "$repo/readme.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "edit text again"

for tool in churn.sh hotspots.sh health.sh; do
  if run_in "$repo" "$SCRIPT_DIR/$tool" 5 >/dev/null 2>&1; then
    pass "$tool handles binary files"
  else
    fail "$tool with binary files" "exit code $?"
  fi
done

# ── Test 5: Scoring sanity ──
echo ""
echo "5. Health scoring sanity"
repo=$(make_temp_repo)
for i in $(seq 1 10); do
  echo "line $i" >> "$repo/growing.txt"
  git -C "$repo" add . && git -C "$repo" commit -q -m "add line $i"
done
output=$(run_in "$repo" "$SCRIPT_DIR/health.sh" 10)
score=$(echo "$output" | grep "Score:" | grep -o '[0-9]*' | head -1)
if [ -n "$score" ] && [ "$score" -ge 70 ]; then
  pass "healthy repo scores >= 70 (got $score)"
else
  fail "healthy repo scoring" "expected >= 70, got ${score:-empty}"
fi

# ── Test 6: trend.sh minimum commits ──
echo ""
echo "6. trend.sh minimum commit handling"
repo=$(make_temp_repo)
echo "a" > "$repo/f.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "one"
echo "b" >> "$repo/f.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "two"

if run_in "$repo" "$SCRIPT_DIR/trend.sh" 2 2 >/dev/null 2>&1; then
  fail "trend.sh minimum commits" "should reject 2 commits with window 2"
else
  pass "trend.sh rejects insufficient commits"
fi

# ── Test 7: High-churn repo gets lower score ──
echo ""
echo "7. High-churn repo scores lower"
repo=$(make_temp_repo)
for i in $(seq 1 8); do
  # Write then immediately rewrite — pure churn
  echo "version $i content that will be replaced" > "$repo/churn_target.txt"
  git -C "$repo" add . && git -C "$repo" commit -q -m "rewrite $i"
done
output=$(run_in "$repo" "$SCRIPT_DIR/health.sh" 8)
churn_score=$(echo "$output" | grep "Score:" | grep -o '[0-9]*' | head -1)
if [ -n "$churn_score" ] && [ -n "$score" ] && [ "$churn_score" -le "$score" ]; then
  pass "high-churn repo scores <= healthy repo ($churn_score <= $score)"
else
  fail "churn scoring comparison" "churn=$churn_score should be <= healthy=$score"
fi

# ── Test 8: evolve.sh output ──
echo ""
echo "8. evolve.sh output"
repo=$(make_temp_repo)
echo "initial" > "$repo/AGENTS.md"
git -C "$repo" add . && git -C "$repo" commit -q -m "ai: initial identity"
echo "evolved" >> "$repo/AGENTS.md"
git -C "$repo" add . && git -C "$repo" commit -q -m "ai: second iteration"

evolve_output=$(run_in "$repo" "$SCRIPT_DIR/evolve.sh" 2>&1 || true)
if echo "$evolve_output" | grep -q "Evolution Report"; then
  pass "evolve.sh produces evolution report"
else
  fail "evolve.sh output" "missing Evolution Report header"
fi
if echo "$evolve_output" | grep -q "ai: initial identity"; then
  pass "evolve.sh lists ai commit messages"
else
  fail "evolve.sh output" "missing ai commit messages"
fi

# ── Test 9: intent.sh classifies refinement ──
echo ""
echo "9. intent.sh refinement detection"
repo=$(make_temp_repo)
echo "line 1" > "$repo/stable.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "init"
echo "line 2" >> "$repo/stable.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "add line 2"
echo "line 3" >> "$repo/stable.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "add line 3"
echo "line 4" >> "$repo/stable.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "add line 4"

intent_output=$(run_in "$repo" "$SCRIPT_DIR/intent.sh" 5 3 2>&1 || true)
if echo "$intent_output" | grep -q "Intent Report"; then
  pass "intent.sh produces intent report"
else
  fail "intent.sh output" "missing Intent Report header"
fi
if echo "$intent_output" | grep -q "REFINEMENT"; then
  pass "intent.sh classifies incremental additions as REFINEMENT"
else
  fail "intent.sh refinement" "expected REFINEMENT for incremental appends"
fi

# ── Test 10: intent.sh classifies indecision ──
echo ""
echo "10. intent.sh indecision detection"
repo=$(make_temp_repo)
echo "approach A" > "$repo/flip.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "init A"
echo "completely different approach B" > "$repo/flip.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "switch to B"
echo "approach A" > "$repo/flip.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "back to A"
echo "completely different approach B" > "$repo/flip.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "back to B"
echo "approach A" > "$repo/flip.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "back to A again"

intent_output=$(run_in "$repo" "$SCRIPT_DIR/intent.sh" 6 3 2>&1 || true)
if echo "$intent_output" | grep -q "INDECISION"; then
  pass "intent.sh classifies oscillating rewrites as INDECISION"
else
  fail "intent.sh indecision" "expected INDECISION for oscillating content"
fi

# ── Test 11: intent.sh handles filenames with spaces ──
echo ""
echo "11. intent.sh with filenames with spaces"
repo=$(make_temp_repo)
echo "a" > "$repo/my file.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "init"
echo "b" >> "$repo/my file.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "edit 1"
echo "c" >> "$repo/my file.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "edit 2"
echo "d" >> "$repo/my file.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "edit 3"

if run_in "$repo" "$SCRIPT_DIR/intent.sh" 5 3 >/dev/null 2>&1; then
  pass "intent.sh handles filenames with spaces"
else
  fail "intent.sh with spaced filenames" "exit code $?"
fi

# ── Test 12: health.sh shows intent dimension ──
echo ""
echo "12. health.sh intent dimension in output"
repo=$(make_temp_repo)
echo "line 1" > "$repo/evolving.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "init"
echo "line 2" >> "$repo/evolving.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "edit 1"
echo "line 3" >> "$repo/evolving.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "edit 2"
echo "line 4" >> "$repo/evolving.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "edit 3"

health_output=$(run_in "$repo" "$SCRIPT_DIR/health.sh" 5 2>&1 || true)
if echo "$health_output" | grep -q "Intent:"; then
  pass "health.sh includes Intent dimension"
else
  fail "health.sh intent dimension" "missing Intent: line in output"
fi

# ── Test 13: indecisive churn penalizes health score ──
echo ""
echo "13. Indecisive churn penalizes health score"
# Create a high-churn repo with oscillating content (indecision)
repo_indecisive=$(make_temp_repo)
echo "padding" > "$repo_indecisive/other.txt"
git -C "$repo_indecisive" add . && git -C "$repo_indecisive" commit -q -m "init other"
for i in $(seq 1 3); do
  printf '%s\n' "approach A line 1" "approach A line 2" "approach A line 3" "approach A line 4" "approach A line 5" > "$repo_indecisive/flip.txt"
  echo "more padding $i" >> "$repo_indecisive/other.txt"
  git -C "$repo_indecisive" add . && git -C "$repo_indecisive" commit -q -m "approach A round $i"
  printf '%s\n' "totally different B1" "totally different B2" "totally different B3" "totally different B4" "totally different B5" > "$repo_indecisive/flip.txt"
  echo "yet more $i" >> "$repo_indecisive/other.txt"
  git -C "$repo_indecisive" add . && git -C "$repo_indecisive" commit -q -m "approach B round $i"
done

# Create a similar-volume repo with learning pattern (no oscillation)
repo_learning=$(make_temp_repo)
echo "padding" > "$repo_learning/other.txt"
git -C "$repo_learning" add . && git -C "$repo_learning" commit -q -m "init other"
for i in $(seq 1 6); do
  printf '%s\n' "unique content version $i line 1 $RANDOM" "unique v$i line 2 $RANDOM" "unique v$i line 3 $RANDOM" "unique v$i line 4 $RANDOM" "unique v$i line 5 $RANDOM" > "$repo_learning/evolving.txt"
  echo "more padding $i" >> "$repo_learning/other.txt"
  git -C "$repo_learning" add . && git -C "$repo_learning" commit -q -m "version $i"
done

indecisive_output=$(run_in "$repo_indecisive" "$SCRIPT_DIR/health.sh" 8 2>&1 || true)
learning_output=$(run_in "$repo_learning" "$SCRIPT_DIR/health.sh" 8 2>&1 || true)

indecisive_score=$(echo "$indecisive_output" | grep "Score:" | grep -o '[0-9]*' | head -1)
learning_score=$(echo "$learning_output" | grep "Score:" | grep -o '[0-9]*' | head -1)

if [ -n "$indecisive_score" ] && [ -n "$learning_score" ] && [ "$indecisive_score" -le "$learning_score" ]; then
  pass "indecisive repo scores <= learning repo ($indecisive_score <= $learning_score)"
else
  fail "intent-aware scoring" "indecisive=$indecisive_score should be <= learning=$learning_score"
fi

# ── Test 14: authors.sh basic output ──
echo ""
echo "14. authors.sh basic output"
repo=$(make_temp_repo)
echo "init" > "$repo/code.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "init"
echo "edit" >> "$repo/code.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "edit 1"
echo "more" >> "$repo/code.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "edit 2"

authors_output=$(run_in "$repo" "$SCRIPT_DIR/authors.sh" 5 2>&1 || true)
if echo "$authors_output" | grep -q "Ownership Report"; then
  pass "authors.sh produces ownership report"
else
  fail "authors.sh output" "missing Ownership Report header"
fi
if echo "$authors_output" | grep -q "Test"; then
  pass "authors.sh shows author name"
else
  fail "authors.sh output" "missing author name in output"
fi

# ── Test 15: authors.sh multi-author detection ──
echo ""
echo "15. authors.sh multi-author detection"
repo=$(make_temp_repo)
echo "init" > "$repo/shared.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "init"

git -C "$repo" config user.name "Alice"
echo "alice edit" >> "$repo/shared.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "alice change"

git -C "$repo" config user.name "Bob"
echo "bob edit" >> "$repo/shared.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "bob change"

authors_output=$(run_in "$repo" "$SCRIPT_DIR/authors.sh" 5 2>&1 || true)
if echo "$authors_output" | grep -q "Alice" && echo "$authors_output" | grep -q "Bob"; then
  pass "authors.sh detects multiple authors"
else
  fail "authors.sh multi-author" "expected both Alice and Bob in output"
fi
if echo "$authors_output" | grep -q "Total authors: 3"; then
  pass "authors.sh counts all authors correctly"
else
  fail "authors.sh author count" "expected 3 authors (Test, Alice, Bob)"
fi

# ── Test 16: authors.sh with filenames with spaces ──
echo ""
echo "16. authors.sh with filenames with spaces"
repo=$(make_temp_repo)
echo "a" > "$repo/my file.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "init"
echo "b" >> "$repo/my file.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "edit 1"
echo "c" >> "$repo/my file.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "edit 2"

if run_in "$repo" "$SCRIPT_DIR/authors.sh" 5 >/dev/null 2>&1; then
  pass "authors.sh handles filenames with spaces"
else
  fail "authors.sh with spaced filenames" "exit code $?"
fi

authors_output=$(run_in "$repo" "$SCRIPT_DIR/authors.sh" 5 2>&1 || true)
if echo "$authors_output" | grep -q "my file.txt"; then
  pass "authors.sh correctly reports filenames with spaces"
else
  fail "authors.sh spaced filenames" "output missing 'my file.txt'"
fi

# ── Test 17: authors.sh solo project detection ──
echo ""
echo "17. authors.sh solo project detection"
repo=$(make_temp_repo)
echo "init" > "$repo/code.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "init"
echo "edit" >> "$repo/code.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "edit"

authors_output=$(run_in "$repo" "$SCRIPT_DIR/authors.sh" 5 2>&1 || true)
if echo "$authors_output" | grep -q "Solo project"; then
  pass "authors.sh identifies solo projects"
else
  fail "authors.sh solo detection" "expected Solo project in assessment"
fi

# ── Test 18: pace.sh non-git directory ──
echo ""
echo "18. pace.sh non-git directory handling"
if run_in "$tmpdir" "$SCRIPT_DIR/pace.sh" >/dev/null 2>&1; then
  fail "pace.sh on non-git dir" "should exit non-zero"
else
  pass "pace.sh rejects non-git directory"
fi

# ── Test 19: pace.sh basic output ──
echo ""
echo "19. pace.sh basic output"
repo=$(make_temp_repo)
echo "init" > "$repo/code.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "init"
echo "edit1" >> "$repo/code.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "edit 1"
echo "edit2" >> "$repo/code.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "edit 2"
echo "edit3" >> "$repo/code.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "edit 3"

pace_output=$(run_in "$repo" "$SCRIPT_DIR/pace.sh" 5 2>&1 || true)
if echo "$pace_output" | grep -q "Pace Report"; then
  pass "pace.sh produces pace report"
else
  fail "pace.sh output" "missing Pace Report header"
fi
if echo "$pace_output" | grep -q "Commit Size Distribution"; then
  pass "pace.sh shows commit size distribution"
else
  fail "pace.sh output" "missing Commit Size Distribution section"
fi
if echo "$pace_output" | grep -q "Delivery Rhythm"; then
  pass "pace.sh shows delivery rhythm"
else
  fail "pace.sh output" "missing Delivery Rhythm section"
fi

# ── Test 20: pace.sh single commit ──
echo ""
echo "20. pace.sh single-commit repo"
repo=$(make_temp_repo)
echo "hello" > "$repo/file.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "first"

pace_output=$(run_in "$repo" "$SCRIPT_DIR/pace.sh" 1 2>&1 || true)
if echo "$pace_output" | grep -q "Pace Report"; then
  pass "pace.sh runs on single-commit repo"
else
  fail "pace.sh single commit" "unexpected output"
fi
# Single commit should not show rhythm section
if echo "$pace_output" | grep -q "Delivery Rhythm"; then
  fail "pace.sh single commit" "should not show rhythm with only 1 commit"
else
  pass "pace.sh omits rhythm section for single commit"
fi

# ── Test 21: pace.sh with filenames with spaces ──
echo ""
echo "21. pace.sh with filenames with spaces"
repo=$(make_temp_repo)
echo "a" > "$repo/my file.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "init"
echo "b" >> "$repo/my file.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "edit 1"
echo "c" >> "$repo/my file.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "edit 2"

if run_in "$repo" "$SCRIPT_DIR/pace.sh" 5 >/dev/null 2>&1; then
  pass "pace.sh handles filenames with spaces"
else
  fail "pace.sh with spaced filenames" "exit code $?"
fi

# ── Test 22: pace.sh with binary files ──
echo ""
echo "22. pace.sh with binary files"
repo=$(make_temp_repo)
echo "text" > "$repo/readme.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "first"
dd if=/dev/urandom of="$repo/image.bin" bs=64 count=1 2>/dev/null
git -C "$repo" add . && git -C "$repo" commit -q -m "add binary"
echo "more" >> "$repo/readme.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "edit text"

if run_in "$repo" "$SCRIPT_DIR/pace.sh" 5 >/dev/null 2>&1; then
  pass "pace.sh handles binary files"
else
  fail "pace.sh with binary files" "exit code $?"
fi

# ── Test 23: pace.sh assessment output ──
echo ""
echo "23. pace.sh pace assessment"
repo=$(make_temp_repo)
for i in $(seq 1 6); do
  echo "line $i" >> "$repo/growing.txt"
  git -C "$repo" add . && git -C "$repo" commit -q -m "add line $i"
done

pace_output=$(run_in "$repo" "$SCRIPT_DIR/pace.sh" 6 2>&1 || true)
if echo "$pace_output" | grep -q "Rhythm:"; then
  pass "pace.sh provides rhythm assessment"
else
  fail "pace.sh assessment" "missing Rhythm classification"
fi

# ── Summary ──
echo ""
echo "=== Results ==="
echo "  Passed:  $PASS"
echo "  Failed:  $FAIL"
total=$((PASS + FAIL))
if [ "$total" -gt 0 ]; then
  pct=$((PASS * 100 / total))
  echo "  Rate:    ${pct}%"
fi
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "Some tests failed. The tools need hardening."
  exit 1
else
  echo "All tests passed."
  exit 0
fi
