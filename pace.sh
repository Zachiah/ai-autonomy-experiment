#!/usr/bin/env bash
# pace.sh — measure development velocity and delivery rhythm
#
# The other tools analyze code quality and churn. This one measures
# tempo: how fast is development moving, and is the pace sustainable?
#
# Answers: "How fast and how steadily is this project being developed?"
#
# Metrics:
#   - Commits per day/week: raw velocity
#   - Commit size distribution: small focused vs. large batched
#   - Time gaps: longest pauses and consistency of delivery
#   - Burst detection: periods of intense activity vs. silence
#
# Usage: ./pace.sh [number_of_commits]
#   Default: 50 commits

set -euo pipefail

N=${1:-50}

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "Error: not a git repository" >&2
  exit 1
fi

# Gather commit timestamps and sizes
declare -a timestamps
declare -a sizes
declare -a hashes
commit_count=0

ROOT_HASH=$(git rev-list --max-parents=0 HEAD 2>/dev/null | head -1)

while IFS= read -r line; do
  hash=$(echo "$line" | cut -d' ' -f1)
  ts=$(echo "$line" | cut -d' ' -f2)
  hashes+=("$hash")
  timestamps+=("$ts")

  # Calculate commit size (lines changed)
  if [ "$hash" = "$ROOT_HASH" ]; then
    size=$(git diff --numstat --diff-filter=A "$(git hash-object -t tree /dev/null)" "$hash" 2>/dev/null | awk '{s+=$1+$2} END {print s+0}')
  else
    size=$(git diff --numstat "${hash}^" "$hash" 2>/dev/null | awk '{s+=$1+$2} END {print s+0}')
  fi
  sizes+=("${size:-0}")
  commit_count=$((commit_count + 1))
done < <(git log --format="%H %at" -n "$N" 2>/dev/null)

if [ "$commit_count" -eq 0 ]; then
  echo "No commits found." >&2
  exit 1
fi

echo "=== Pace Report (last $commit_count commits) ==="
echo ""

# --- Time span ---
newest_ts=${timestamps[0]}
oldest_ts=${timestamps[$((commit_count - 1))]}
span_seconds=$((newest_ts - oldest_ts))

if [ "$span_seconds" -le 0 ]; then
  span_days=0
  span_weeks=0
else
  span_days=$((span_seconds / 86400))
  span_weeks=$((span_days / 7))
fi

# Format dates
newest_date=$(date -r "$newest_ts" "+%Y-%m-%d" 2>/dev/null || date -d "@$newest_ts" "+%Y-%m-%d" 2>/dev/null || echo "unknown")
oldest_date=$(date -r "$oldest_ts" "+%Y-%m-%d" 2>/dev/null || date -d "@$oldest_ts" "+%Y-%m-%d" 2>/dev/null || echo "unknown")

echo "Period:              $oldest_date to $newest_date"
if [ "$span_days" -gt 0 ]; then
  echo "Span:                $span_days days ($span_weeks weeks)"
else
  echo "Span:                less than 1 day"
fi

# --- Velocity ---
if [ "$span_days" -gt 0 ]; then
  # Use integer math: commits * 10 / days for one decimal place
  cpd_x10=$((commit_count * 10 / span_days))
  cpd_whole=$((cpd_x10 / 10))
  cpd_frac=$((cpd_x10 % 10))
  echo "Commits/day:         ${cpd_whole}.${cpd_frac}"

  if [ "$span_weeks" -gt 0 ]; then
    cpw=$((commit_count / span_weeks))
    echo "Commits/week:        $cpw"
  fi
else
  echo "Commits/day:         $commit_count (all in one day)"
fi
echo ""

# --- Commit size distribution ---
echo "--- Commit Size Distribution ---"
total_size=0
min_size=${sizes[0]}
max_size=${sizes[0]}
small=0      # <= 10 lines
medium=0     # 11-100 lines
large=0      # 101-500 lines
xlarge=0     # > 500 lines

for s in "${sizes[@]}"; do
  total_size=$((total_size + s))
  [ "$s" -lt "$min_size" ] && min_size=$s
  [ "$s" -gt "$max_size" ] && max_size=$s
  if [ "$s" -le 10 ]; then
    small=$((small + 1))
  elif [ "$s" -le 100 ]; then
    medium=$((medium + 1))
  elif [ "$s" -le 500 ]; then
    large=$((large + 1))
  else
    xlarge=$((xlarge + 1))
  fi
done

avg_size=$((total_size / commit_count))

echo "Avg lines/commit:    $avg_size"
echo "Min:                 $min_size"
echo "Max:                 $max_size"
echo ""
echo "  Small  (<=10):     $small commits"
echo "  Medium (11-100):   $medium commits"
echo "  Large  (101-500):  $large commits"
echo "  XLarge (>500):     $xlarge commits"
echo ""

# --- Time gaps between commits ---
if [ "$commit_count" -ge 2 ]; then
  echo "--- Delivery Rhythm ---"

  declare -a gaps
  total_gap=0
  max_gap=0
  gap_count=0

  for ((i = 0; i < commit_count - 1; i++)); do
    gap=$((timestamps[i] - timestamps[i + 1]))
    [ "$gap" -lt 0 ] && gap=$((-gap))
    gaps+=("$gap")
    total_gap=$((total_gap + gap))
    [ "$gap" -gt "$max_gap" ] && max_gap=$gap
    gap_count=$((gap_count + 1))
  done

  avg_gap=$((total_gap / gap_count))

  # Format gaps as human-readable
  format_duration() {
    local secs=$1
    if [ "$secs" -lt 60 ]; then
      echo "${secs}s"
    elif [ "$secs" -lt 3600 ]; then
      echo "$((secs / 60))m"
    elif [ "$secs" -lt 86400 ]; then
      echo "$((secs / 3600))h"
    else
      echo "$((secs / 86400))d"
    fi
  }

  echo "Avg time between commits: $(format_duration $avg_gap)"
  echo "Longest gap:              $(format_duration $max_gap)"

  # Count bursts (gaps < 30 min) and pauses (gaps > 3 days)
  bursts=0
  pauses=0
  for g in "${gaps[@]}"; do
    [ "$g" -lt 1800 ] && bursts=$((bursts + 1))
    [ "$g" -gt 259200 ] && pauses=$((pauses + 1))
  done

  echo "Rapid commits (<30m gap):  $bursts"
  echo "Long pauses (>3 day gap):  $pauses"
  echo ""

  # --- Consistency score ---
  # Standard deviation of gaps (approximated: mean absolute deviation)
  mad_total=0
  for g in "${gaps[@]}"; do
    diff=$((g - avg_gap))
    [ "$diff" -lt 0 ] && diff=$((-diff))
    mad_total=$((mad_total + diff))
  done
  mad=$((mad_total / gap_count))

  # Coefficient of variation (MAD/mean, as percentage)
  if [ "$avg_gap" -gt 0 ]; then
    cv=$((mad * 100 / avg_gap))
  else
    cv=0
  fi

  echo "--- Pace Assessment ---"

  # Classify rhythm
  if [ "$cv" -lt 50 ]; then
    echo "Rhythm:    STEADY (variation: ${cv}%)"
    echo "  Commits arrive at a consistent cadence."
  elif [ "$cv" -lt 100 ]; then
    echo "Rhythm:    IRREGULAR (variation: ${cv}%)"
    echo "  Mix of active bursts and quiet periods."
  else
    echo "Rhythm:    ERRATIC (variation: ${cv}%)"
    echo "  Highly uneven delivery — long silences punctuated by bursts."
  fi

  # Classify velocity
  if [ "$span_days" -gt 0 ]; then
    cpd_x10=$((commit_count * 10 / span_days))
    if [ "$cpd_x10" -ge 30 ]; then
      echo "Velocity:  HIGH (${cpd_whole}.${cpd_frac} commits/day)"
    elif [ "$cpd_x10" -ge 5 ]; then
      echo "Velocity:  MODERATE (${cpd_whole}.${cpd_frac} commits/day)"
    else
      echo "Velocity:  LOW (${cpd_whole}.${cpd_frac} commits/day)"
    fi
  fi

  # Sustainability warning
  if [ "$xlarge" -gt "$((commit_count / 3))" ]; then
    echo ""
    echo "Warning: Over a third of commits are extra-large (>500 lines)."
    echo "  Large batched commits are harder to review and more likely to introduce bugs."
  fi

  if [ "$bursts" -gt "$((gap_count * 2 / 3))" ] && [ "$pauses" -gt 0 ]; then
    echo ""
    echo "Warning: Burst-and-pause pattern detected."
    echo "  Most work happens in rapid sessions separated by long silences."
    echo "  This may indicate deadline-driven development."
  fi
fi

echo ""
echo "=== End of report ==="
