# Reflection: HOM-6 benchmark qualification

The initial saved calibration looked acceptable only because the warmed product
trace performed zero paragraph layouts. Increasing the pair count fixed the
order imbalance but did not make that trace measure probe overhead. The useful
correction was to separate product performance from instrumentation calibration:
keep the warmed trace for the user-facing scroll metric, and use a fresh-cache
trace to exercise the bookkeeping branch.

Exact frame windows also mattered. The old unconditional two-second tail mixed
100 intended pumps with 100-106 reported frames, so modes were not summarized
over identical work. The corrected callback preflushes before registration,
stops the probe immediately after the action, and rejects missing or extra
timings.

The final cold failure was a measurement-policy problem, not an editor problem.
The old callback accepted unbounded two-or-three-frame batches that could
include a prior unmount. The corrected cold trace preflushes callbacks and
requires exactly the one explicitly pumped first frame. That method is not
comparable to the older accepted summary, so the binding 50 ms absolute budget
remains meaningful while the accepted relative comparison remains binding for
exact 100-frame warmed scroll.

Finally, profiling found one real candidate cost: all default rows mounted
hover and opacity machinery even though the default opacity never changes.
Keeping the default widget tree lean recovered steady-scroll headroom without
changing Nexus's hover-only grabber behavior.

Exact windows also exposed a scenario-level assumption: height churn used a
drag plus an extra pump inside a nominal 100-pump trace. Applying the same
slider state change before the loop's existing pump preserves three real height
changes without expanding the window; the direct pathological profile now
records 4x100 frames per mode.
