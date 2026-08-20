# Benchmarks

`melos run benchmark` generates the deterministic corpus, builds the real
playground editor in profile mode on macOS, and writes ignored JSON results to
`benchmarks/results/`. Pass one or more case names to the runner directly for a
focused run, for example:

```sh
dart run benchmarks/run.dart tiny-generated large-generated
```

The fixed control is the pre-HOM-6 `ListView.builder` route with a 1440×900
logical viewport, DPR 1, text scale 1, and 250px cache extent. Every case runs
one warm-up round trip followed by three interleaved, identical five-second
disabled and instrumented scroll traces. Flutter's `FrameTiming` summary records frame
latencies; Homeric records mounted-row high water and every actual paragraph
layout split across live, intrinsic/dry, empty-template, and paint-rebuild
paths.

The default matrix covers all generated sizes plus one-huge-block,
many-small-block, alternating-height, biased-estimate, and height-churn
pathologies. The biased-estimate case is the fixed corpus shape that the U5
height index will consume; the pre-viewport control has no estimate cache yet.
Debug timings are not a gate. The median of the three paired instrumented
versus disabled p95 deltas must stay within 5% on `large-generated`, or the
runner rejects the evidence as noisy. `run-metadata.json`
captures the machine, Dart, Flutter, mode, and policy used for the evidence.

`baseline.json` is the immutable pre-viewport structural/timing summary. It
records the current control's cumulative-layout budget failure explicitly; it
is not a declaration that the unfinished HOM-6 viewport is accepted.
`results/` stays ignored. Baseline changes require a `perf:` commit explaining
the comparison. Targets live in [`../docs/PERF_BUDGET.md`](../docs/PERF_BUDGET.md).
