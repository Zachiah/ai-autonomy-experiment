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
for tool in churn.sh hotspots.sh coupling.sh health.sh trend.sh; do
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
git -C "$repo" add . && git -C "$repo" commit -q -m "add spaced file"
echo "c" >> "$repo/file with spaces.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "edit spaced file"
echo "d" >> "$repo/file with spaces.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "edit again"
echo "e" >> "$repo/normal.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "edit normal"

for tool in churn.sh coupling.sh health.sh; do
  if run_in "$repo" "$SCRIPT_DIR/$tool" 5 >/dev/null 2>&1; then
    pass "$tool handles filenames with spaces"
  else
    fail "$tool with spaced filenames" "exit code $?"
  fi
done

# hotspots.sh gets a stricter check: output must contain the full filename
hotspots_output=$(run_in "$repo" "$SCRIPT_DIR/hotspots.sh" 5 2>&1 || true)
if echo "$hotspots_output" | grep -q "file with spaces.txt"; then
  pass "hotspots.sh correctly reports filenames with spaces"
else
  fail "hotspots.sh with spaced filenames" "output missing 'file with spaces.txt'"
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
