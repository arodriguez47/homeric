# Benchmarks

`melos run benchmark` generates the deterministic corpus, builds the real
playground editor in profile mode on macOS, and writes ignored JSON results to
`benchmarks/results/`. Pass one or more case names to the runner directly for a
focused run, for example:

```sh
dart run benchmarks/run.dart tiny-generated large-generated
```

`baseline.json` preserves the pre-HOM-6 `ListView.builder` control. Current
runs exercise the production `HomericEditableDocument` playground route with
a 1440×900 logical viewport, DPR 1, text scale 1, and 250px cache extent. Every
case runs one warm-up round trip followed by three interleaved, identical
five-second disabled and instrumented scroll traces. Flutter's `FrameTiming`
summary records frame latencies; Homeric records mounted-row high water and
every actual paragraph layout split across live, intrinsic/dry,
empty-template, and paint-rebuild paths.

The default matrix covers all generated sizes plus one-huge-block,
many-small-block, alternating-height, biased-estimate, and height-churn
pathologies. The biased-estimate case stresses the measured-height index
rather than assuming estimates are final child extents.
Debug timings are not a gate. The median of the three paired instrumented
versus disabled p95 deltas must stay within 5% on `large-generated`, or the
runner rejects the evidence as noisy. `run-metadata.json`
captures the machine, Dart, Flutter, mode, and policy used for the evidence.

`baseline.json` is the immutable pre-viewport structural/timing summary. It
records the old control's cumulative-layout budget failure explicitly; it is
not a declaration that the current viewport is accepted.
`results/` stays ignored. Baseline changes require a `perf:` commit explaining
the comparison. Targets live in [`../docs/PERF_BUDGET.md`](../docs/PERF_BUDGET.md).

## Latest HOM-6 qualification

The 2026-08-19 local macOS profile matrix completed all ten generated and
pathological cases, including 500,000 words and 25,000 tiny blocks. The
100,000-word case mounted at most 11 rows, loaded its first frame in 56.8 ms,
and recorded disabled scroll p50/p95 of 10.8/16.6 ms. Instrumentation overhead
was 4.8%, within the 5% validity limit. Its median cumulative live-paragraph
layout time was 718.0 ms, so the 200 ms absolute budget remains failed. HOM-6
must not be described as performance-accepted until that owning-layer cost is
reduced or the contract is deliberately re-reviewed with new evidence. The
runner now exits nonzero for this result instead of accepting a calibrated but
over-budget trace.
