# Git Health Tools

Shell scripts that analyze the health, churn, and evolution of any git repository.

## Quick start

```bash
# Clone and run against any git repo
./health.sh              # Overall health grade (A-F) with recommendations
./test_suite.sh          # Verify everything works (36 tests)
```

## Tools

| Script | What it does |
|--------|-------------|
| `health.sh [N]` | Unified health report: grade, score, and recommendations. Integrates all dimensions below. |
| `churn.sh [N]` | Rewrite ratio — how much code is being replaced vs. added. High churn suggests instability. |
| `hotspots.sh [N]` | Files with the highest rewrite rates. These are where bugs tend to cluster. |
| `coupling.sh [N]` | File pairs that always change together. May indicate hidden dependencies. |
| `trend.sh` | Is churn increasing, decreasing, or stable over time? |
| `intent.sh [N]` | Classifies *why* files are being rewritten: learning, refinement, or indecision. |
| `authors.sh [N]` | Code ownership and knowledge distribution. Who owns what, and where are the bus factor risks? |
| `evolve.sh` | Traces how a specific file changed over time (defaults to AGENTS.md). |

`[N]` = optional number of recent commits to analyze (default: 50).

## Example

```
$ ./health.sh
=== Codebase Health Report ===
Repository: my-project
Commits analyzed: 50

┌─────────────────────────────────────────────┐
│  Overall Grade: B (Solid)                   │
│  Score: 78/100                              │
└─────────────────────────────────────────────┘

Dimensions:
  Churn:       22% rewrite ratio
  Hotspots:    3 file(s) churning heavily
  Coupling:    1 tightly-coupled file pair
  Trend:       STABLE
  Intent:      5 learning, 3 refinement, 1 indecision
```

## What this repo actually is

This repository is an experiment. An AI is given its own description file (`AGENTS.md`) and told to edit it to improve itself, one iteration at a time, with no memory between iterations. The git history *is* the experiment.

The shell tools emerged from that process — the AI started building diagnostic tools to analyze its own patterns. They turned out to be useful on any git repo.

## Requirements

- Bash 3.2+
- Git
- Standard Unix tools (awk, sort, etc.)
