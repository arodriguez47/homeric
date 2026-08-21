# HOM-6 qualification handoff

## Outcome

HOM-6's 100k-word benchmark now measures the instrumentation path it claims to
calibrate and passes the binding local profile gate. The accepted baseline was
not changed.

## Corrections

- Four balanced trace pairs replace the asymmetric three-pair order.
- Every measured product/calibration trace accepts exactly 100 frame timings.
- A separate fresh-cache calibration executes real paragraph layouts in both
  modes and rejects zero-layout evidence.
- Calibration validity is recomputed from the recorded delta and layout count;
  a serialized `valid: true` cannot bypass the gate.
- The default always-visible grabber keeps the original lean row tree; only
  consumers with distinct idle/hover opacity mount hover/animation machinery.
- Warmed scroll retains the accepted relative +5% gate. Cold mount retains its
  binding `<50 ms` absolute gate after a same-machine accepted-source control
  showed the sparse two-or-three-frame relative statistic was irreproducible.

## Proof-first evidence

- Missing balance/frame helpers failed the playground test at compile time.
- Forged calibration validity and zero-layout evidence failed the gate tests.
- The default grabber test failed while `AnimatedOpacity` remained mounted.
- Two pre-correction profile runs failed with zero calibration layouts.
- The cold trace proof exposed unbounded two-or-three-frame callback batches;
  the final profile records exactly one explicitly pumped frame for all eight
  mounts.

## Final evidence

- Package benchmark/editor tests: 71/71 passed.
- Playground benchmark helper tests: 5/5 passed.
- Scoped package and playground analysis: no issues.
- Final `large-generated` profile gate: passed.
  - first frame: 84,988 us
  - cold mount p95: 8,721 us (eight exact one-frame samples)
  - warmed scroll p50/p95: 7,135 / 8,597 us
  - maximum mounted rows: 11
  - warmed paragraph layouts: 0
  - fresh-cache calibration layouts: 3,768
  - calibration delta: +309 bp (+3.09%)
  - detached cache: 942 entries / 508,084 UTF-16 code units
- `large-height_churn` pathological profile: passed with four exact 100-frame
  samples in each mode, three in-frame height mutations, 5,564 measured
  paragraph layouts, and at most 11 mounted rows.
- `git diff --check`: clean.

## Boundaries

- No accepted baseline update, commit, push, GHA, or deployment.
- The Mac remained locked; VoiceOver, physical-device, prolonged stress, and
  visual/manual acceptance remain separate evidence gates.
- `tool/` remained protected and untouched.
