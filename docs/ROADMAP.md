# Homeric Roadmap

See [`ARCHITECTURE_DECISION.md`](ARCHITECTURE_DECISION.md) for the underlying analysis.

| Phase | Weeks | Theme | Exit criterion |
|---|---|---|---|
| 1 | 1–4 | **Foundation** | Fork builds and tests green; 100k-word benchmark baseline recorded; architecture audit complete. |
| 2 | 5–12 | **Virtualization** | `SliverVariedExtentList` + `BlockHeightCache` powering the editor; benchmark shows ≥10× improvement in frame time on 100k-word docs. |
| 3 | 13–18 | **Primitives** | `StepMap` ported from ProseMirror with full test suite; `DecorationSet` integrated with the edit pipeline. |
| 4 | 19–26 | **Features** | Footnotes, inline comments, backlinks, writing goals, visual diff; Markdown extensions for footnotes + wiki-links. |
| 5 | 27–32 | **Platform polish** | Desktop keyboard parity, Android IME revalidation, Web (Latin) shipped with documented limitations, perf validated across all v1 platforms. |

## Non-goals (v1)

- iOS (deferred — Apple Pencil and iPad polish are a project of their own)
- Real-time collaboration
- Native (non-Flutter) bindings
- A theme/design system — Homeric ships unstyled primitives

## Long-term

After v1 stable, the natural next investments:

- iOS
- An Operational Transform or CRDT layer for collaboration (likely Yjs-equivalent in Dart)
- Paginated layout mode (PDF/book-style)
- LSP-style language services for writers (grammar, style)
