# AGENTS.md — Homeric

Canonical guidance for all AI coding agents working in this repository.

**Project tracker:** Linear, team `Homeric` (`HOM`). The plan lives in **HOM-1**
with one issue per phase (HOM-2 … HOM-8). Read the phase issue before starting
work in it.

---

## What Homeric is

A Flutter text editing package built from fundamentals: own document model, own
positions and mapping, own decorations, own `RenderObject`, own layout, own input —
calling `dart:ui` for glyph shaping only.

```
homeric:     document model · positions · StepMap · DecorationSet
             selection · hit test · caret geometry · line & block layout
             RenderObject · input & IME wiring · virtualization
                                  │
                                  ▼
dart:ui:     ParagraphBuilder → Paragraph
             (shaping · bidi · line breaking · font fallback · placeholders)
                                  │
                                  ▼
Skia / Impeller: glyph raster
```

**Shaping stays with `dart:ui`.** This is where every serious editor draws the
line — CodeMirror lets the browser shape, Zed uses the system shaper, native macOS
editors use CoreText. `docs/ARCHITECTURE_DECISION.md` rejected going lower before
this plan existed (*"IME across six platforms is a 12–18 month project on its
own"*), and that rejection is load-bearing, not provisional. A proposal to own
shaping is a proposal to restart the project.

## Two hard rules

1. **Do not copy AppFlowy Editor or super_editor source.** Not into `lib/`, not
   "for reference", not commented out. Read to learn, then write. This repo's first
   life was a mechanical rename of super_editor and all of it was deleted; with no
   forked code Homeric can be MIT/Apache rather than inheriting AGPL-3.0/MPL-2.0.
2. **Every phase after Phase 1 lands in Nexus.** Phase 1 (document model,
   `StepMap`, `DecorationSet` — pure Dart, no Flutter) is the sole exception and is
   scoped in weeks. If a phase's definition of done can be met without a consumer
   running the code, the phase is scoped wrong. See `LEARNINGS.md`, "A 32-week
   roadmap with no consumer is a five-minute project."

## Document-space vs view-space

The distinction this package exists to manage. **Document positions and view
positions must not be the same type.** If a bare `int` offset can be handed to both
the IME layer and the paragraph builder, the two will be confused, and the failures
are silent — corrupt composing ranges on one platform, or a caret that stalls on
hidden ranges.

Known classification, carried from the AppFlowy survey:

| Consumer | Space |
|---|---|
| Platform IME (`TextEditingValue`, composing ranges) | **Document** — never map |
| Character movement (arrow keys, backspace, delete) | **Document** — needs a separate atomic-range hook |
| Word movement, vertical movement | **View** — inherits the map |
| Caret rect, selection rects, hit test | **View** |

## Compounding Rule

Append lessons to `LEARNINGS.md` (`## <role> — <date> — <topic>`), with
**What changed** / **Why it mattered** / **Rule going forward**.

**Cross-repo clause — Nexus.** A lesson about **text layout, document↔view offset
mapping, selection or caret geometry, inline decoration, IME, or editor
architecture** is written to **both** `LEARNINGS.md` files in the same change: this
one and `arodriguez47/nexus`'s. Nexus is Homeric's first consumer, and the two will
drift apart precisely on the invariants that are expensive to relearn. There is no
sync job; this instruction is the mechanism, and it is reciprocal — Nexus's
`AGENTS.md` carries the same clause pointing back here. Everything else (Nexus
product behaviour, Firestore, graph/physics) stays in that repo only.

## Testing standards

Inherited from Nexus's `docs/testing-assertions.md`, which applies here verbatim:

- **Every assertion must name the mutation it catches.** If you cannot name the
  edit that turns it red, it is decoration.
- **Mutation protocol, all three steps:** break the code, confirm red, then check
  **which** assertion failed. Red for the wrong reason still certifies a dead test.
- **When a behaviour is protected by more than one guard, delete them one at a
  time.** An assertion that only fails when all of them are gone is an end-to-end
  check, not a unit one, and must say so.
- Phase 1 is property-tested with no widgets. Phase 3 (IME) **cannot** be verified
  in widget tests and must not be claimed done from them — the matrix runs on
  device across macOS, iOS, Android and web.

## Performance

`docs/PERF_BUDGET.md` defines the fixture table (1k → 500k words) and a 5%
regression gate; `tools/corpus/generate.dart` generates the corpus. Wire the gate
into CI at the **start** of Phase 4, not the end — a budget adopted after the
optimization work is a description, not a constraint.
