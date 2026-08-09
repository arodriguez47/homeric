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
