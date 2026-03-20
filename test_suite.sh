#!/usr/bin/env bash
# test_suite.sh — validate codebase analysis tools against edge cases
#
# Creates synthetic git repos and verifies the tools produce correct output.
# Covers: non-repo dirs, single-commit repos, binary files, filenames with
# spaces, scoring sanity, and minimum-commit guards.

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
for tool in churn.sh hotspots.sh coupling.sh health.sh trend.sh evolve.sh intent.sh; do
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
