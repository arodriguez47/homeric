# Benchmarks

- `baseline.json` — the current accepted baseline numbers. Updated by `melos run benchmark-baseline` when intentionally accepting a perf change. CI diffs against this.
- `results/` — gitignored. Local runs of `melos run benchmark` write here.

Baseline updates require a `perf:` commit explaining the change.
