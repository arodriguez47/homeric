# Benchmarks

The benchmark harness is being rebuilt for the from-scratch core (the previous harness targeted the super_editor fork, removed 2026-08-08).

Once rebuilt:

- `baseline.json` — the current accepted baseline numbers. CI diffs against this.
- `results/` — gitignored. Local benchmark runs write here.

Baseline updates require a `perf:` commit explaining the change. Targets live in [`../docs/PERF_BUDGET.md`](../docs/PERF_BUDGET.md).
