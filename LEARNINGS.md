# Learnings

Editor-layer learnings, mirrored with Nexus per the compounding rule in [`AGENTS.md`](AGENTS.md): a learning about text layout, offset mapping, selection geometry, or editor architecture is written to **both** repos in the same change.

## editor-architect — 2026-08-08 — StepMap semantics that anchor survival depends on

ProseMirror's position mapping is small but exact: `[start, oldSize, newSize]` triples in old-doc coordinates, an `assoc` bias for boundary positions, four deletion flags, and `recover`/mirror machinery. Two traps: (1) `deleted` fires too eagerly for anchor-removal policies — `deletedAcross` (content removed on both sides) is the real "this anchor's content is gone" signal; (2) a block **move** expressed as delete+insert marks everything inside as `deletedAcross` — moves must register their delete/insert StepMaps as a mirror pair so positions recover into the destination, or every anchor and decoration in a moved block dies.

## editor-architect — 2026-08-08 — Token counting is open+close, not fence-post

PM positions: each character costs 1 and each block contributes an opening *and* closing token (block size = content + 2). The fence-post misreading ("one token between blocks") is self-consistent enough to pass its own tests while diverging from every PM reference value, collapsing "between blocks" and "at block start" into one position, and making empty blocks unaddressable. Pin the scheme with hand-computed values on day one (two blocks "Hi"/"yo" → doc size 8, "y" at position 5, empty block size 2).

## editor-architect — 2026-08-08 — Decorations: per-end inclusivity and mapping context

A single global bias for decoration endpoints is a documented PM bug class (prosemirror issue #849) — each decoration needs `inclusiveStart`/`inclusiveEnd`. And a DecorationSet storing block-local offsets cannot remap from a Mapping alone: StepMaps speak global coordinates, so mapping needs document/change context (PM's `DecorationSet.map(mapping, doc)`; Homeric's `map(mapping, changeList)` with split/join/move id outcomes carried in the ChangeList).

## editor-architect — 2026-08-08 — Dart persistence and the PM reference landscape

For a per-keystroke hot path, hand-rolled structural sharing (shallow-copy small arrays, share children, cache sizes — what PM itself does) beats persistent-collection packages: `fast_immutable_collections`' unflushed-diff indirection adds unpredictable latency, and `built_collection` is copy-on-build, not sharing. Keep StepMap ranges as plain `List<int>`; pack recover values with multiplication, not `<<`, for dart2js/wasm safety. Reference note: all ProseMirror GitHub repos were archived April 2026 — mirrors remain stable porting references; current development is at code.haverbeke.berlin. Non-JS semantic cross-checks: the `prosemirror` PyPI port and `cozy/prosemirror-go`.

## editor-architect — 2026-08-09 — DocOffset/DocRange: typed offsets, not bare ints, at the render-layer boundary

The Phase 2 render layer's `ParagraphGeometry` (U4) never takes or returns a bare view-space `int`: every public method's signature is `DocOffset`/`DocRange` in, `DocOffset`/`DocRange` out, with `ui.Paragraph`-facing view-text math confined to private helpers (`_viewRangeOf`, `_docRangeOf`, `_caretMetrics`) that convert at the boundary and never leak the raw `int` back out. `DocOffset` is a zero-cost `extension type` over `int` specifically so this costs nothing at runtime while still making "which coordinate space is this" a compile-time question — a view-text offset literally cannot be passed where a document offset is expected without an explicit `ViewMap` call standing in the way. This directly operationalizes Nexus's 2026-08-08 "classify every offset consumer as document-space or view-space before wiring the map" postmortem at a new layer: the render layer is exactly where a silent view/doc mixup would previously have been easiest to introduce (every `dart:ui` query is view-space; every caller-facing API must be document-space), so making the type system enforce it there, not just in review, is the reusable pattern.

## editor-architect — 2026-08-09 — Two deliberately different opaque-payload equality conventions in one library

Homeric's render layer now has two families of caller-supplied opaque payload: `Decoration.spec`/`BlockParagraphSpec` (identity-equality — "same instance means same state, don't over-fire a rebuild") and `PaintLayer.spec` (value-equality — "same visual meaning even if freshly reconstructed this frame, don't over-repaint"). Both are correct for their own caller shape: decorations are typically held and mutated in place, so identity tracks real state changes; paint layers are typically rebuilt fresh every frame from animation state, so identity would make every frame register as "changed" and value equality is what actually detects "nothing visually different happened." The risk is a future opaque-spec type assuming a library-wide default and picking the wrong one silently. Rule: a new opaque-spec type must state which convention it uses in its own doc comment and pick deliberately based on how callers are expected to construct it (held-and-mutated vs. rebuilt-per-frame) — never inherit an assumption from a sibling type.
