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
case runs one unmeasured outward warm-up traversal followed by three paired,
identical five-second disabled and instrumented scroll traces. Pair order
alternates to cancel thermal/order drift. Each paired trace shares
one mounted viewport and starts from the same warmed cache state, so the paired
frame delta measures probe overhead rather than first-visit shaping versus
recycled-row reuse. The instrumented pass proves that an identical traversal
reclaims shaped paragraphs rather than hiding layout work behind widget
counts. Cold first-frame timing remains a separate, unwarmed metric. Flutter's
`FrameTiming` summary records frame latencies; Homeric records mounted-row high
water and every actual paragraph layout split across live, intrinsic/dry,
empty-template, and paint-rebuild paths.

The default matrix covers all generated sizes plus one-huge-block,
many-small-block, alternating-height, biased-estimate, and height-churn
pathologies. The biased-estimate case stresses the measured-height index
rather than assuming estimates are final child extents.
Debug timings are not a gate. The median of the three paired instrumented
versus disabled p95 deltas must stay within 5% on `large-generated`, or the
runner rejects the evidence as noisy. `run-metadata.json`
captures the machine, Dart, Flutter, mode, and policy used for the evidence.

`baseline.json` is the immutable pre-viewport structural/timing summary.
`accepted.json` is the current post-HOM-6 regression comparison and records the
explicit rationale for accepting the viewport's 8.4 ms cold-mount p95: the
added natural-height, document-semantics, selection, and reorder work remains
below the 16 ms stretch target while steady-state scroll p95 improves from
12.9 ms to 8.4 ms. `results/` stays ignored. Accepted-baseline changes require
a `perf:` commit explaining the comparison. Targets live in
[`../docs/PERF_BUDGET.md`](../docs/PERF_BUDGET.md).

## Latest HOM-6 qualification

The 2026-08-19 local macOS profile matrix completed all ten generated and
pathological cases, including 500,000 words and 25,000 tiny blocks. The final
focused 100,000-word qualification mounted at most 11 rows, loaded its first
frame in 83.0 ms, and recorded warmed disabled scroll p50/p95 of 6.5/8.8 ms.
Instrumentation delta was -1.9%, within the 5% validity limit. After one
unmeasured outward warm-up traversal, all three measured traces reclaimed shaped
paragraphs and recorded zero engine layout calls; the detached cache retained
942 entries and 508,084 UTF-16 code units, below its 2,048-entry/1,000,000-unit
bounds. Every absolute gate passes. The accepted comparison records the
document viewport's 8.4 ms cold-mount p95 separately from the immutable 5.0 ms
pre-HOM-6 control and explains the explicit acceptance rationale.
