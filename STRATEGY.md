---
name: Homeric
last_updated: 2026-08-08
---

# Homeric Strategy

## Target problem

There is no long-form Flutter editor good enough to build a serious writing app on. I want to build my own apps — a Ulysses substitute, a knowledge-management app — and no existing Flutter editor is a viable foundation: they collapse on book-length documents and have no primitives for keeping comments, footnotes, and diffs anchored through edits.

## Our approach

Build from scratch, natively in Dart and Flutter — no fork of super_editor, no embedding of ProseMirror or CodeMirror. We own every line. Three primitives (viewport virtualization, StepMap position mapping, DecorationSet overlays) carry everything; every feature must compose on top of them, so that one library can serve every app I want to build.

## Who it's for

**Primary:** Me (Alvaro), building my own apps — hiring Homeric to be the long-form editor foundation for a Ulysses substitute and a knowledge-management app. My apps drive every v1 decision.

**Secondary:** Open-source Flutter developers building writing/notes/PKM apps — they become primary once the primitives are proven.

## Key metrics

- **100k-word perf budget** - typing latency, frame time, and scroll jank at 100k words stay inside `docs/PERF_BUDGET.md`; measured by `melos run benchmark`.
- **Anchor survival rate** - comments, footnotes, and decorations survive randomized edit fuzzing with zero broken anchors; measured in the test suite.
- **Features without core changes** - each new feature ships as a composition on the three primitives with zero or near-zero core-package changes; checked per feature PR.
- **My apps on Homeric** - the lagging metric: the Ulysses substitute (and later the PKM app) running on Homeric for daily writing.

## Tracks

### Editing primitives

The from-scratch editor core: document model, transactions, StepMap position mapping, and DecorationSet — correctness, fuzzing, and the composition model everything else builds on.

_Why it serves the approach:_ These are the native-Dart primitives the whole bet rests on; if they're right, every feature is a composition.

### Performance at scale

Viewport virtualization, the 100k-word benchmark harness, and holding the perf budget as documents grow.

_Why it serves the approach:_ Long-form is the point — a primitive set that can't hold 100k words doesn't solve the problem.

### Writing feature layer

Footnotes, inline comments, annotations, backlinks, writing goals, version diff — each built purely as compositions on the primitives.

_Why it serves the approach:_ Each feature is both user value and a proof that the primitives are sufficient.

## Milestones

- **TBD** - Phase 1 foundation done: primitives landed, benchmark green.
- **TBD** - First app dogfooding: the Ulysses substitute writing real documents on Homeric.
- **TBD** - Public 0.1 release on pub.dev.

## Marketing

**One-liner:** Ulysses-class writing UX with Tiptap-class extensibility — a ProseMirror for Flutter, in pure Dart.
