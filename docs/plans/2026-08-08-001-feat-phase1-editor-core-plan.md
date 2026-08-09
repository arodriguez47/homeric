---
title: "feat: Phase 1 editor core — document model, StepMap, DecorationSet, view text"
type: feat
status: completed
date: 2026-08-08
origin: https://linear.app/xana-studios/issue/HOM-3/phase-1-document-model-positions-stepmap-decorationset
---

# feat: Phase 1 editor core — document model, StepMap, DecorationSet, view text

## Summary

Build Homeric's pure-Dart editor core (Linear HOM-3): an immutable block-based document model whose attribute bag hosts Nexus metadata untranslated, a step/transaction layer where every edit emits a ProseMirror-style `StepMap`, a three-kind `DecorationSet`, and first-class view-text derivation with a bidirectional offset map — all verified by property tests with zero Flutter imports. A first unit aligns the repo docs with the Linear plan (Phase 0 remainder).

---

## Problem Frame

Nexus (the first consumer) has four features working around one missing primitive: rendered text length must equal document text length, so hidden markdown delimiters, inline asides, multi-char anchors, and footnote markers are all hacks today. The previous Homeric attempt (a super_editor fork) died at scaffolding without ever writing the primitives. This phase builds the only layer provable completely in isolation — the layer every later phase (rendering, input, virtualization) depends on for correctness. Full rationale: HOM-1 epic and `docs/ARCHITECTURE_DECISION.md`.

---

## Requirements

- R1. Pure Dart, **zero Flutter imports** anywhere in Phase 1 modules; the whole layer is testable with `dart test`-style unit/property tests, no widgets.
- R2. Document model: an ordered sequence of blocks with **stable block ids** and ordered inline runs carrying attributes. The block attribute bag is a JSON-compatible map that hosts Nexus's `nexus` metadata (`blockId`, `schemaVersion`, `mirror{mirrorId, source, capturedAt, sourceContentHash, sourceSnapshotText, groupId}`) **without translation**. Stable ids are also what block-based drag/move (a stated product requirement) keys on.
- R3. Every edit returns `(ChangeList, StepMap)`. Anchors, decorations, and selections map forward through arbitrary edit sequences; inversion is lossless (recover/mirror semantics), so undo and version diff can be built later without anchor corruption.
- R4. `DecorationSet` with exactly three kinds — `inline` (restyle a range), `replace` (range → view text of different length, including empty; this is how a delimiter is hidden), `widget` (range → a measured child placeholder) — non-destructive, mapped through StepMaps, with **per-end inclusivity** on each decoration.
- R5. View-text derivation: document text + decorations → view text plus a **bidirectional** offset map, first-class from the start.
- R6. Verification is property-based, per HOM-3: round-trip identity outside replaced runs, map composition under sequential edits, decoration survival across every step kind, boundary behavior at run edges / overlapping and adjacent decorations / empty and whole-block replacements.
- R7. **No source copied** from ProseMirror, super_editor, or AppFlowy — read to learn, then write. Where ProseMirror's algorithmic math is ported (StepMap ranges/recover), the file header cites the upstream file and commit.
- R8. Decorations and annotations carry **no presentation semantics**. Margin note vs popover is the consumer's decision; the library exposes anchored ranges (and, in Phase 2, their geometry) only.
- R9. Repo docs align with the Linear plan: `docs/ROADMAP.md` phase table matches HOM-1, `docs/ARCHITECTURE_DECISION.md` conclusion records the from-fundamentals decision and layer diagram, `LEARNINGS.md` + `AGENTS.md` exist with the cross-repo mirroring clause (HOM-2 remainder).

---

## Scope Boundaries

- No rendering, `RenderObject`, or geometry — Phase 2 (HOM-4).
- No text input, IME, keyboard, or gestures — Phase 3 (HOM-5).
- No multi-block selection UI, scrolling, or virtualization — Phase 4 (HOM-6).
- No markdown serialization/deserialization, and none of the concrete syntaxes (`%%`, `++`, `{{`, `((`, `(fn)`, `(img)`) — input and Nexus-parity phase work (HOM-5, HOM-7/HOM-8). Phase 1 only guarantees the primitives don't preclude them (replace decorations + view text is the mechanism).
- No undo *stack* or history UI — Phase 1 delivers lossless step inversion; history is a later composition.
- No collaboration/CRDT/OT.
- No pub.dev publishing or public API stabilization.
- No benchmark harness — deferred to Phase 4 per the Linear plan (HOM-6 wires the perf gate); `tools/corpus/` stays as-is.

### Deferred to Follow-Up Work

- Nexus-side reciprocal `AGENTS.md` mirroring clause: separate change in the `nexus` repo (HOM-2 requires both repos; this plan can only edit homeric).
- Benchmark harness rebuild + CI perf gate: Phase 4, against `docs/PERF_BUDGET.md`.

---

## Context & Research

### Relevant Code and Patterns

- `packages/homeric/` — fresh scaffold (empty `lib/homeric.dart`); this plan fills it. No legacy code constrains the design.
- `nexus/lib/models/document_block_metadata.dart` — the metadata shape R2 must host: a JSON map under key `nexus`.
- `docs/ARCHITECTURE_DECISION.md` — comparative editor analysis; its three-primitives design still stands.
- `docs/PERF_BUDGET.md` — the eventual contract; Phase 1 only avoids designs that can't meet it (see Key Technical Decisions on structural sharing).

### Institutional Learnings

- gstack learnings (this project): display of syntax elements is the extensible part; annotation presentation is consumer-decided (margin vs popover); block-based movement requires stable block identity.

### External References

- prosemirror-transform `src/map.ts`, `src/step.ts`, `src/replace_step.ts`, `src/transform.ts`, and `test/test-mapping.ts` — the porting blueprint (GitHub repos archived Apr 2026; mirrors stable, current dev at code.haverbeke.berlin).
- prosemirror-model Fragment/ResolvedPos — structural sharing via shallow array copies + cached sizes; 12-entry resolve cache.
- prosemirror-view `decoration.ts` — DecorationSet as a document-shadowing tree; ProseMirror issue #849 — the per-end inclusivity bug class.
- Non-JS ports for semantic cross-checks: `prosemirror` (PyPI), `cozy/prosemirror-go`.
- Cautionary prior art: AppFlowy's path-based addressing (invalidated by structural edits, no composable mapping); super_editor's pipeline (good request/command vocabulary, no position mapping).

---

## Key Technical Decisions

- **Positions are single integers with ProseMirror token counting** — each character costs 1, and every block contributes an opening *and* a closing token, so a block's total size is its content length + 2, exactly as in ProseMirror; the gap between two adjacent blocks is one position but two tokens. StepMap arithmetic stays pure integer math with proven semantics, and PM's own test suite becomes portable as a spec. Rejected: AppFlowy-style `(path, offset)` pairs — not composable through arbitrary edit sequences. Also rejected: fence-post counting (a single token between blocks) — it silently diverges from every ProseMirror reference value and collapses "between blocks" and "at block start" into one position.
- **Flat block sequence, no nested blocks in v1**: HOM-3 specifies blocks + inline runs; list/quote semantics live in block attributes. This collapses ProseMirror's hardest part (slice fitting with open depths) to a one-level problem — a deliberate scope reduction that makes the 3–5 week estimate credible.
- **StepMap semantics ported faithfully**: `[start, oldSize, newSize]` triples, `assoc` bias, the four deletion flags (`deletedBefore/After/Across`), and recover/mirror for lossless inversion. `deletedAcross` (not mere `deleted`) is the anchor-removal signal.
- **Tiny step vocabulary, smart builders**: ReplaceStep + attribute/mark steps only; block split/join/move are expressed as replaces by builder functions, mirroring PM's design. Block *move* keeps the block's id and attribute bag intact (drag/move requirement).
- **Hand-rolled structural sharing** (shallow-copy arrays, share children, cache sizes), no persistent-collection dependency: keeps the per-keystroke path predictable and the package dependency-free. Root is a plain immutable list — at ~700 blocks per 100k words this is well within budget; an indexed container is a swap-in later if Phase 4 benchmarks demand it.
- **Per-end inclusivity on every decoration and anchor** (`inclusiveStart`/`inclusiveEnd`) rather than a global bias — the documented PM bug class (#849).
- **DecorationSet sharded per block** (keyed by stable block id, offsets local to the block), rebuilt only for touched blocks on map: the flat block model gives the same "untouched subtrees shared" property PM's shadowing tree provides.
- **Zero-Flutter enforcement is a test, not a pubspec change**: the pubspec keeps its Flutter dependency (Phase 2 needs it); a unit test asserts no `package:flutter` (or `dart:ui`) import appears under `lib/src/model|transform|decoration|view`.

---

## Open Questions

### Resolved During Planning

- Does Phase 1 include the benchmark harness? — No; the Linear plan gates perf in Phase 4. Property tests are the Phase 1 verification.
- Single package or multi-package? — Single (`packages/homeric`), per HOM-2's "single package… if the workspace shape is worth keeping."
- Where do `(fn)`/`(img)` triggers and `%%`/`++` syntaxes land? — Input/feature phases; Phase 1's replace-decoration + view-text mechanism is what they'll compose on.

### Deferred to Implementation

- Exact class/method names and file splits below `src/` — directional only.
- Whether the resolve cache needs PM's 12-entry rotation or something simpler — decide when profiling real command patterns (Phase 2+).
- ChangeList granularity (per-block dirty set vs typed events) — settle when U4 meets real consumers; start with the minimal thing U5/U6 need.

---

## Output Structure

    packages/homeric/
    ├── lib/
    │   ├── homeric.dart                  # public exports
    │   └── src/
    │       ├── model/                    # U3: document, block, inline runs, attributes, positions
    │       ├── transform/                # U2+U4: step_map, mapping, steps, transaction, change_list
    │       ├── decoration/               # U5: decoration, decoration_set
    │       └── view/                     # U6: view_text, view_map
    └── test/
        ├── model/ · transform/ · decoration/ · view/   # unit tests per module
        └── property/                     # U7: invariants + fuzz harness (incl. no_flutter_imports test)

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

```
                 edit intent (builder fns: insertText, deleteRange,
                  setBlockAttr, toggleMark, splitBlock, moveBlock)
                                   │
                                   ▼
   Document ──apply──►  Transaction { steps[], docs[], mapping }
   (immutable,                     │
    blocks w/ stable ids,          ├─► new Document        (structural sharing)
    inline runs w/ attrs,          ├─► ChangeList          (what changed, for listeners)
    token positions)               └─► Mapping (StepMaps)  (position translation)
                                                 │
              anchors / selections / DecorationSet.map(mapping, changeList)
                                                 │
                                                 ▼
   view text derivation (per block):
   document text + decorations ──► view text + ViewMap (docToView / viewToDoc)
   • inline decoration  → same length, styled range
   • replace decoration → different length (0..n), hides delimiters
   • widget decoration  → placeholder slot for a measured child (Phase 2 renders it)
```

Layer boundary (from HOM-1): everything above `dart:ui` shaping is Homeric; nothing in Phase 1 touches even `dart:ui`.

---

## Implementation Units

### U1. Phase 0 alignment — docs, learnings, mirroring

**Goal:** Finish the HOM-2 remainder so the repo tells the same story as Linear.

**Requirements:** R9

**Dependencies:** None

**Files:**
- Modify: `docs/ROADMAP.md` (phase table → HOM-1's 7 phases with estimates and Nexus deliverables)
- Modify: `docs/ARCHITECTURE_DECISION.md` (rewrite conclusion: from-fundamentals decision, HOM-1 layer diagram, shaping stays with `dart:ui`; keep the comparative analysis)
- Create: `LEARNINGS.md` (Nexus's `## <role> — <date> — <topic>` format, seeded with editor-layer learnings)
- Create: `AGENTS.md` (project conventions + the reciprocal mirroring clause: text-layout/offset-mapping/selection-geometry/editor-architecture learnings are written to both repos in the same change)
- Modify: `README.md` (status line points at the Linear phases; repo-layout tree gains `docs/plans/`)

**Approach:**
- Content is prescribed by HOM-1/HOM-2 — this is transcription and reconciliation, not invention. Note in ROADMAP that `benchmark.yaml` returns in Phase 4 with the harness.
- Budget note: U1 is HOM-2 remainder work, not HOM-3 scope — its time does **not** count against the 3–5-week estimate or the 6-week re-scope checkpoint.

**Test scenarios:**
- Test expectation: none — documentation-only unit.

**Verification:**
- ROADMAP phase table matches HOM-1's table verbatim in structure; ADR ends with the layer diagram; both learnings files exist; `melos run analyze` and `format-check` stay green.

---

### U2. StepMap and Mapping

**Goal:** The position-mapping heart: StepMap triples, assoc bias, deletion flags, recover/mirror, and Mapping composition — self-contained, zero document dependency.

**Requirements:** R1, R3, R7

**Dependencies:** None

**Files:**
- Create: `packages/homeric/lib/src/transform/step_map.dart`, `.../transform/mapping.dart`
- Test: `packages/homeric/test/transform/step_map_test.dart`, `.../mapping_test.dart`

**Approach:**
- Ranges as a flat int list of `[start, oldSize, newSize]` triples in old-document coordinates; `map(pos, {assoc})` walks triples accumulating the size diff; positions strictly inside a replaced range snap by assoc.
- MapResult carries `deleted`, `deletedBefore`, `deletedAfter`, `deletedAcross`; recover values pack `(rangeIndex, offset)`; `invert()` is the same triples with an inverted flag; Mapping holds StepMaps plus mirror pairs and routes deleted positions through `recover()` on the mirrored inverse.
- Keep recover packing as multiplication (not `<<`) for dart2js/wasm safety.
- File header cites prosemirror-transform `src/map.ts` and the commit consulted (R7).

**Execution note:** Test-first — port `test-mapping.ts` near-verbatim as the spec before implementing.

**Patterns to follow:**
- prosemirror-transform `map.ts` semantics; `cozy/prosemirror-go` and the PyPI port as cross-checks on edge cases.

**Test scenarios:**
- Happy path: mapping through insert-before / delete-after / delete-across / delete-around cases matches PM's expected positions for both assoc values.
- Happy path: composed Mapping over N maps equals sequential application.
- Edge case: position exactly at a replaced range's start/end honors assoc; empty ranges (0 old / 0 new size); adjacent triples.
- Edge case: `deletedAcross` true only when content on both sides is removed; `deletedBefore`/`deletedAfter` for one-sided deletion.
- Happy path: round-trip invertibility — `mapping.invert().map(mapping.map(p)) == p` for every non-deleted position; deleted positions recover exactly through mirrored maps.
- Error path: out-of-range positions and malformed triple lists fail loudly (assert/throw), never silently misplace.

**Verification:**
- The ported PM mapping suite passes; a reviewer can diff test expectations against `test-mapping.ts` case-for-case.

---

### U3. Document model — blocks, inline runs, attributes, positions

**Goal:** The immutable document: ordered blocks with stable ids, attributed inline runs, JSON-compatible attribute bags, token positions, and resolve.

**Requirements:** R1, R2, R7

**Dependencies:** None

**Files:**
- Create: `packages/homeric/lib/src/model/` (document, block, inline runs/attributed text, attributes, position resolve)
- Test: `packages/homeric/test/model/` (one test file per concern)

**Approach:**
- Blocks are immutable, carry a stable id (never regenerated by edits), a type key, an attribute bag (`Map<String, Object?>`, JSON-compatible, deep-frozen), and inline content as ordered runs of text + attribute sets (flat, PM text-node-with-marks shape; never assume one run per block).
- Positions use PM token counting over the flat block sequence; document caches cumulative block sizes so position→block resolve is cheap and recomputed only for blocks after an edit point.
- Structural sharing: edits shallow-copy the block list and the touched block's run list only; everything else shared by reference. No deep copies anywhere (undo/history memory depends on this).
- Verify R2 concretely: construct a block whose attribute bag holds a real `nexus` metadata map lifted from Nexus fixtures; round-trip it untouched.

**Patterns to follow:**
- prosemirror-model Fragment (cached sizes, shallow-copy mutation); Nexus `document_block_metadata.dart` for the hosted metadata shape.

**Test scenarios:**
- Happy path: build → read back text, runs, attrs; position of every block boundary and character matches token-counting rules; resolve returns the right (block, offset) for interior, boundary, start, end positions.
- Happy path: token-scheme pin — document size and boundary positions assert against hand-computed ProseMirror values (e.g., two blocks "Hi"/"yo" → doc size 8, second block's first character at position 5; an empty block has size 2).
- Happy path: `nexus` metadata map stored and retrieved byte-identical (deep-equality), no translation layer.
- Edge case: empty document; empty block; block with empty runs between non-empty ones; run boundaries with identical adjacent attributes.
- Edge case: structural sharing observable — untouched blocks are identical references after an edit elsewhere.
- Error path: resolve of negative / past-end positions throws a typed error.

**Verification:**
- Model tests green; a Nexus metadata fixture survives round-trip; no Flutter imports (enforced in U7's import test from day one).

---

### U4. Steps, Transaction, ChangeList

**Goal:** Every edit is a step; every transaction yields `(new Document, ChangeList, Mapping)`; steps invert losslessly and rebase via mapping.

**Requirements:** R1, R3, R7

**Dependencies:** U2, U3

**Files:**
- Create: `packages/homeric/lib/src/transform/` (step, replace_step, attr steps, transaction, change_list, builder functions)
- Test: `packages/homeric/test/transform/` (step_test, transaction_test, builders_test)

**Approach:**
- Step contract: `apply(doc) → StepResult` (fail, don't throw), `getMap()`, `invert(docBefore)`, `map(Mapping) → Step?` (null = no longer applicable), `merge(other)` for typing coalescing. Port the `structure` guard flag so rebased structural steps can't silently destroy concurrent content.
- Step vocabulary stays tiny: ReplaceStep (text and whole-block replacement over a position range) + attribute steps (block attrs, inline mark add/remove). Builder functions express insertText, deleteRange, splitBlock, joinBlocks, moveBlock, setBlockType as replaces/attr steps.
- `moveBlock` preserves block id and attribute bag (R2's drag/move requirement) — a builder-level invariant with its own test. The builder registers its delete and insert StepMaps as a **mirror pair** in the transaction Mapping, so global positions (selections, anchors) inside the moved block recover into the destination rather than reporting `deletedAcross`.
- Merge rule for cross-block replaces and `joinBlocks`: the **leading** block's id, type, and attribute bag survive; the trailing block's id disappears and its decorations re-key to the leading id with shifted local offsets (PM precedent: join merges the trailing node into the leading one). This one-level head/tail merge is expected work, not "open-depth logic."
- Transaction accumulates `steps[]`, `docs[]`, `mapping`; exposes the ChangeList — touched block ids with their old/new global ranges, plus split/join/move block-id outcomes (which id received which text) — that U5/U6 and future listeners consume.

**Execution note:** Test-first for step invert/rebase semantics; the flat block model means slice-fitting is one-level, and head/tail merges at block boundaries are the expected extent of it — if a case seems to need nesting-depth logic beyond that, the model decision is being violated, stop and reassess.

**Patterns to follow:**
- prosemirror-transform `step.ts`/`replace_step.ts`/`transform.ts` semantics; super_editor's request→command vocabulary only as naming inspiration (no code).

**Test scenarios:**
- Happy path: each builder produces the expected document; transaction mapping maps a position across a multi-step transaction identically to composing per-step maps.
- Happy path: `step.invert(docBefore)` applied to the result restores the original document, for every step kind.
- Happy path: moveBlock keeps id + attribute bag identical; splitBlock assigns a fresh id to exactly one of the halves (decide which and pin it in a test).
- Happy path: joinBlocks / cross-block replace keeps the leading block's id and attribute bag; the trailing block's id disappears from the document.
- Integration: a selection inside a moved block maps to the destination via the mirror pair, not `deletedAcross`.
- Edge case: replace at document start/end; replace spanning a block boundary; empty replace (no-op map); merge of adjacent text inserts coalesces, non-adjacent doesn't.
- Error path: applying a step against a document it doesn't fit returns a failed StepResult (never throws, never corrupts); mapped-away steps return null.
- Integration: a selection (pair of anchored positions) carried through a 3-step transaction lands where PM semantics say it should, including `deletedAcross` cases.

**Verification:**
- All step kinds invert losslessly; transaction-level mapping equals composed step maps; builder invariants pinned by tests.

---

### U5. DecorationSet

**Goal:** Non-destructive range overlays — `inline`, `replace`, `widget` — that survive arbitrary edits via the Mapping.

**Requirements:** R1, R4, R7, R8

**Dependencies:** U2, U4

**Files:**
- Create: `packages/homeric/lib/src/decoration/decoration.dart`, `.../decoration_set.dart`
- Test: `packages/homeric/test/decoration/decoration_set_test.dart`

**Approach:**
- Each decoration: kind, anchored range (block id + local offsets), per-end inclusivity, and an opaque consumer payload (spec/attrs). **No presentation fields** — margin vs popover is the consumer's (R8); the payload is opaque to the library.
- Mapping is `map(mapping, changeList)` — StepMaps alone cannot re-localize block-local offsets, so the ChangeList supplies each touched block's old/new global ranges and split/join/move id outcomes. The set is sharded by block id; only touched shards rebuild, the rest are shared; add/remove are persistent-style updates. Decorations past a split point re-key to the fresh-id block with shifted local offsets; a moved block's shard carries over keyed by the preserved block id.
- Decorations whose range is `deletedAcross` are dropped (with an optional onRemoved callback for consumers like comment systems) — but positions route through `recover()` on mirrored maps *before* the drop rule, so a moved block's decorations never count as deleted; one-sided deletions clamp per inclusivity.
- `widget` decorations occupy a zero-or-one-slot position contract that Phase 2's `addPlaceholder` consumes; Phase 1 only guarantees stable slot identity through mapping.

**Patterns to follow:**
- prosemirror-view `decoration.ts` design (shadow structure, local offsets); issue #849 as the inclusivity regression to design against.

**Test scenarios:**
- Happy path: each kind survives inserts/deletes before, inside, and after its range with correct new offsets, for all four inclusivity combinations.
- Happy path: decoration survival across *every* step kind from U4 (the HOM-3 invariant), including splitBlock (decoration follows its text into the new block) and moveBlock (shard follows the block id).
- Happy path: a decoration and a selection inside a moved block land at the destination with correct offsets (mirror-pair recovery, not `deletedAcross` dropping).
- Edge case: decorations past a split point re-key to the fresh-id block with shifted local offsets.
- Edge case: overlapping decorations; adjacent decorations at a shared boundary; zero-length (collapsed) decorations; decoration spanning an entire block; empty replace decoration (hide entirely).
- Edge case: decoration whose range is deleted across is removed and reported; one-side-deleted ranges clamp per inclusivity, not globally.
- Integration: DecorationSet mapped through a multi-transaction Mapping equals mapping through each transaction sequentially.

**Verification:**
- Survival matrix (kinds × step kinds × inclusivity) fully covered; untouched shards are reference-identical after map.

---

### U6. View text derivation and ViewMap

**Goal:** Document text + decorations → per-block view text plus a bidirectional offset map. The primitive that makes hidden delimiters real (not `fontSize: 0`) and Phase 2's "view text ≠ document text" possible.

**Requirements:** R1, R5, R8

**Dependencies:** U3, U5

**Files:**
- Create: `packages/homeric/lib/src/view/view_text.dart`, `.../view/view_map.dart`
- Test: `packages/homeric/test/view/view_text_test.dart`

**Approach:**
- Per block: fold decorations over the run text — `replace` substitutes ranges (possibly empty), `widget` injects a placeholder slot, `inline` passes text through with a styled-range marker. Output: view text, styled ranges in view coordinates, and a ViewMap.
- ViewMap is the same ranges-triples machinery as StepMap (U2 reused, not reimplemented): `docToView(pos, assoc)` and `viewToDoc(pos, assoc)`, with replaced spans mapping by policy (caret lands at the nearest visible edge — the "no phantom caret slots" guarantee).
- Derivation is pure and per-block, so a later edit re-derives only ChangeList-touched blocks.

**Technical design:** *(directional)* `deriveViewText(block, decorations) → (viewText, styledRanges, ViewMap)`; round-trip law: `viewToDoc(docToView(p)) == p` for all p outside replaced ranges.

**Test scenarios:**
- Happy path: `**bold**` with two replace decorations hiding delimiters yields view text `bold`; docToView/viewToDoc round-trip for every position outside the hidden spans; positions inside hidden spans map to the visible edge chosen by assoc.
- Happy path: widget decoration injects exactly one placeholder slot; multi-char anchor replaced by a single slot (the Nexus workaround-killer cases from HOM-1's table).
- Edge case: replace-to-empty at block start/end; two adjacent replace decorations; replace covering the whole block (view text empty); inline decoration overlapping a replace boundary.
- Edge case: derivation is deterministic and pure — same inputs, identical outputs (fixture-pinned).
- Integration: edit the document, map the DecorationSet, re-derive — view text and ViewMap agree with a from-scratch derivation of the new state (incremental == full).

**Verification:**
- Round-trip law holds; the four Nexus workaround scenarios (hidden delimiters, inline aside, multi-char anchor, footnote marker slot) each have a passing named test proving the primitive covers them.

---

### U7. Property and fuzz harness

**Goal:** The HOM-3 verification contract as an executable suite — stronger than PM's own deterministic tests — plus the zero-Flutter guard.

**Requirements:** R1, R3, R4, R5, R6

**Dependencies:** U4, U5, U6

**Files:**
- Create: `packages/homeric/test/property/` (invariants_test, fuzz_test, no_flutter_imports_test, generators)
- Modify: `melos.yaml` (a `test` run already covers these; add a dedicated long-run fuzz script only if runtime demands separating it)

**Approach:**
- Seeded, reproducible generators: random documents (blocks, runs, attrs, decorations) and random edit sequences over all builder functions. Failures print the seed and a minimal repro script.
- Invariants (the HOM-3 four, plus two from research):
  1. Round-trip identity — U6's law under fuzzing: `viewToDoc(docToView(p)) == p` for every position p outside replaced ranges, and view text equals document text over those spans.
  2. Map composition: composed mapping == sequential per-step mapping, for positions and decorations.
  3. Decoration survival across every step kind.
  4. Boundary behavior: run edges, overlapping/adjacent decorations, empty and whole-block replacements.
  5. Invert round-trip: `mapping.invert()` restores every non-deleted position exactly (recover-backed).
  6. Anchor survival: a tracked anchor's surrounding text (when not deleted across) is the same text before and after arbitrary edit sequences.
- `no_flutter_imports_test`: scans `lib/src/model`, `lib/src/transform`, `lib/src/decoration`, and `lib/src/view` for `package:flutter` / `dart:ui` imports and fails on any hit (R1 as a regression gate, not a convention; scoped to the Phase 1 modules so Phase 2 rendering code in this package doesn't trip it).

**Execution note:** Grow this harness alongside U4–U6 rather than after them — each unit lands with its invariants wired in; U7 is where the cross-cutting fuzz loop and generators live.

**Test scenarios:**
- Happy path: 10k+ random edit-sequence iterations pass all six invariants under a fixed seed set in CI-feasible time.
- Edge case: generators are biased to produce boundary-heavy cases (empty blocks, collapsed ranges, adjacent decorations) — verified by generator self-tests.
- Error path: a deliberately broken StepMap (mutation test on one triple) is caught by invariant 2/5 — proving the harness has teeth.

**Verification:**
- Full suite green under `melos run test`; a seeded failure reproduces deterministically from its printed seed.

---

## System-Wide Impact

- **Interaction graph:** Nothing consumes these APIs yet — Phase 2 (rendering) and the Nexus integration are downstream. The ChangeList and ViewMap shapes are the two surfaces Phase 2 will bind to; both are named as directional in this plan, not frozen.
- **Error propagation:** Steps fail as values (`StepResult`), never throw on bad input; only transaction-level `step()` throws. Resolve/positions throw typed errors on out-of-range input.
- **State lifecycle risks:** Accidental deep copies would silently turn history retention into a memory bomb at 100k words — guarded by the structural-sharing reference-identity tests (U3/U5).
- **API surface parity:** None yet (no published API).
- **Integration coverage:** U6's incremental-equals-full derivation test and U7's cross-layer invariants are the integration proof; unit mocks alone can't show anchors surviving real edit sequences.
- **Unchanged invariants:** `STRATEGY.md`, `docs/PERF_BUDGET.md`, `tools/corpus/`, CI workflow, and the melos workspace shape all stay as they are (U1 touches docs content only).

---

## Risk Analysis & Mitigation

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Phase 1 runs past 6 weeks (HOM-1 checkpoint #1) | Med | High | Flat block model already cut the hardest PM part (open-depth slice fitting); U2 is deliberately first and self-contained — if *it* resists, re-scope immediately per the checkpoint rather than pushing on. U1 (HOM-2 doc remainder) is excluded from this budget. |
| Position semantics subtly diverge from PM, corrupting anchors later | Med | High | Port PM's mapping tests verbatim (U2), cross-check edge cases against the Go/Python ports, and run the U7 fuzz invariants from the first unit that can host them. |
| View-text offset policy (caret at hidden spans) turns out wrong for Phase 2/3 UX | Med | Med | Policy is isolated in ViewMap's assoc handling with pinned tests; changing it later is a local change, and Phase 2's differential test (HOM-4) will catch mismatches. |
| ChangeList shape doesn't fit Phase 2's needs and churns | Med | Low | Kept minimal and explicitly non-frozen; only U5/U6 consume it in Phase 1. |
| Accidental license contamination by copying reference source | Low | High | R7 discipline: read-then-write, algorithm-provenance headers, no AppFlowy/super_editor source opened during implementation. |

---

## Sources & References

- **Origin:** Linear [HOM-3](https://linear.app/xana-studios/issue/HOM-3/phase-1-document-model-positions-stepmap-decorationset) (scope + verification contract), within [HOM-1](https://linear.app/xana-studios/issue/HOM-1/homeric-a-flutter-text-editing-package-built-from-fundamentals) (layer line, checkpoints, licensing rule); [HOM-2](https://linear.app/xana-studios/issue/HOM-2/phase-0-reset-the-repo-seed-linear-and-learnings) (U1 content); [HOM-4](https://linear.app/xana-studios/issue/HOM-4/phase-2-homericparagraph-one-block-rendered-properly) (the Phase 2 boundary U6 hands off to).
- Strategy: `STRATEGY.md`; prior analysis: `docs/ARCHITECTURE_DECISION.md` (superseded conclusion, live analysis).
- Nexus metadata shape: `nexus/lib/models/document_block_metadata.dart` (external repo).
- External: prosemirror-transform/-model/-view sources and tests; `cozy/prosemirror-go`; `prosemirror` (PyPI); ProseMirror issue #849. (HOM-1's referenced brainstorm `2026-08-08-custom-text-rendering-brainstorm.md` was not found in the local Nexus checkout; HOM-1's summary of it is relied on instead.)
