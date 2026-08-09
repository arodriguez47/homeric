# Homeric Roadmap

> **Status: being re-planned.** On 2026-08-08 the project pivoted from forking super_editor to building from scratch in pure Dart (see [`STRATEGY.md`](../STRATEGY.md)). The previous fork-based phase plan is superseded; a new phase plan needs to account for from-scratch costs the fork avoided (document model, text input/IME, selection, rendering). The historical analysis is preserved in [`ARCHITECTURE_DECISION.md`](ARCHITECTURE_DECISION.md).

## Broad shape (to be re-planned in detail)

| Phase | Theme | Exit criterion |
|---|---|---|
| 1 | **Foundation** | From-scratch core: document model, transaction pipeline emitting `StepMap`s; benchmark harness rebuilt; 100k-word baseline recorded. |
| 2 | **Rendering + virtualization** | Virtualized viewport rendering the document model; benchmark inside `PERF_BUDGET.md` targets on 100k-word docs. |
| 3 | **Input** | Text input, IME, and selection across desktop, Android, and Web (Latin-script). |
| 4 | **Features** | Footnotes, inline comments, backlinks, writing goals, visual diff — all as compositions on the primitives; Markdown ser/de. |
| 5 | **Platform polish** | Desktop keyboard parity, Android IME revalidation, Web (Latin) with documented limitations, perf validated across all v1 platforms. |

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
