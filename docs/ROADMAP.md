# Homeric Roadmap

Canonical tracking lives in Linear (team **Homeric**, epic [HOM-1](https://linear.app/xana-studios/issue/HOM-1/homeric-a-flutter-text-editing-package-built-from-fundamentals)); this file mirrors it. Homeric is built **from fundamentals** in pure Dart — own document model, positions, StepMap, DecorationSet, RenderObject, layout, and input — calling `dart:ui` for glyph shaping only. Nexus is the first consumer and migrates surface by surface as capabilities land.

## Phases

| # | Phase | Estimate | Nexus deliverable | Linear |
|---|-------|----------|-------------------|--------|
| 0 | Reset the repo; Linear; learnings | 1–2 days | — (setup) | HOM-2 |
| 1 | Document, positions, StepMap, DecorationSet | 3–5 weeks | — (only phase without one) | HOM-3 |
| 2 | `HomericParagraph` — one block, rendered properly | 6–10 weeks | All four workarounds die | HOM-4 |
| 3 | Input and editing (the long pole) | 8–12 weeks | Journal on Homeric behind a flag | HOM-5 |
| 4 | Multi-block document and virtualization | 4–6 weeks | Long-document performance | HOM-6 |
| 5 | Nexus parity, then remove AppFlowy | 6–10 weeks | AppFlowy dependency deleted | HOM-7 |
| 6 | Notes and longform on Homeric | TBD | Two more surfaces | HOM-8 |

Phase 1's implementation plan: [`docs/plans/2026-08-08-001-feat-phase1-editor-core-plan.md`](plans/2026-08-08-001-feat-phase1-editor-core-plan.md). The benchmark harness and `.github/workflows/benchmark.yaml` return in Phase 4, wired against [`PERF_BUDGET.md`](PERF_BUDGET.md)'s fixtures and 5% regression gate.

## Checkpoints

Not reasons to stop — reasons to re-scope, checked at each phase boundary:

1. **Phase 1 runs past six weeks.** It is the most tractable layer and the only one provable in isolation. If it resists, the render and input layers will be worse.
2. **Phase 2 does not land in Nexus.** The single most important signal. A Phase 2 that ends without the journal rendering paragraphs through Homeric has reproduced the failure this plan was designed against.
3. **Phase 3 IME stalls on one platform.** Ship the platforms that work; keep AppFlowy mounted for the one that doesn't. The flag exists for this.
4. **Phases 0–2 take more than double their estimate.** That is the point to re-read the brainstorm's ranked options with real numbers in hand — not before, and not as a matter of taste.

## Non-goals (v1)

- iOS (deferred — Apple Pencil and iPad polish are a project of their own)
- Real-time collaboration
- Native (non-Flutter) bindings
- A theme/design system — Homeric ships unstyled primitives
- Owning glyph shaping — `ParagraphBuilder`/`Paragraph` stay with `dart:ui` (every serious editor draws the line here)

## Long-term

After v1 stable, the natural next investments:

- iOS
- An Operational Transform or CRDT layer for collaboration (likely Yjs-equivalent in Dart)
- Paginated layout mode (PDF/book-style)
- LSP-style language services for writers (grammar, style)
