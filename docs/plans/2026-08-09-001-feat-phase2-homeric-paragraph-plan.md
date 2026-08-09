---
title: "feat: Phase 2 — HomericParagraph render layer and playground"
type: feat
status: completed
date: 2026-08-09
origin: https://linear.app/xana-studios/issue/HOM-4/phase-2-homericparagraph-one-block-rendered-properly
---

# feat: Phase 2 — HomericParagraph render layer and playground

## Summary

Build the homeric-repo side of Phase 2 (HOM-4): a `HomericParagraph` RenderBox that owns one `ui.Paragraph` built from Phase 1's derived view text, with inline widget decorations as real measured children, all geometry exposed in **document** coordinates, decoration paint layers, read-only correctness guards (differential + semantics), and a runnable playground app that makes the editing primitives testable by hand. Nexus-side integration is a companion plan in the nexus repo once this API is real.

---

## Problem Frame

Phase 1 proved the core in isolation but nothing renders and nothing is touchable. HOM-4 calls this "the phase that decides whether the project survives": four Nexus features work around one missing primitive (rendered length must equal document length), and only a paragraph renderer built on view text ≠ document text kills them. The seam research confirmed the integration contract: AppFlowy's `SelectableMixin` speaks document offsets with global-coordinates-in / local-rects-out, so the geometry surface must be document-coordinate native with the doc↔view mapping fully internal.

---

## Requirements

- R1. One `ui.Paragraph` per block, built via `ParagraphBuilder` from Phase 1's `deriveViewText` output; `widget` decorations become `addPlaceholder` slots measured as real RenderBox children and positioned from `getBoxesForPlaceholders`. Slot bookkeeping matches Phase 1's contract (one U+FFFC code unit per slot — identical to what the engine inserts).
- R2. Geometry in **document coordinates**, sufficient to back every `SelectableMixin` member Nexus exercises: caret rect for a doc position (with affinity), selection rects for a doc range (fragment-correct across inline embeds — kills the ~180-line aside surgery), doc position for a local point, word/line boundary (affinity preserved through the ViewMap), per-embed rect lookup, and block rect. Defined behavior for doc offsets inside hidden runs (assoc-chosen visible edge — "no phantom caret slots") and for view-only trailing content that has no doc offset (queryable geometry, never a doc position).
- R3. Decoration paint layers driven by (doc-range → rects) + opaque paint specs, ordered underlay wash < glyphs < underline/overlay — expressive enough for Nexus's focus dim (animated 0..1 amount per range), mention highlight, and annotation underlay, with zero Nexus-specific semantics in the core (R8 of Phase 1 carries forward).
- R4. Read-only: no text input, IME, or selection gestures (Phase 3). Hit-testing and geometry answer queries; they do not mutate.
- R5. **Differential guard** (HOM-4's named risk): for each decorated corpus block, construct a baseline block whose **document text equals the derived view text** (identity ViewMap, no decorations); assert `caretRect(d, assoc)` on the decorated render equals the baseline's caret rect at `viewMap.docToView(d, assoc)` for every doc offset `d` (hidden-run offsets compared at their assoc-chosen visible edge), and selection rects for doc range `[a,b)` equal the baseline's rects for the mapped view range. Plus mutation-style checks on the translation sites (a perturbed ViewMap must fail the differential).
- R6. Semantics: screen readers receive the **document** text (hidden delimiters never enter the attributed label); inline widget slots participate via child semantics at the correct reading position. VoiceOver announces prose without asterisks (HOM-4's manual check).
- R7. Style contract: per-run style input resolved **per build** (Nexus resolves theme/font at call time — styles must never be captured at registration), block-level `ParagraphStyle` inputs (direction, line height, strut), and `TextScaler` accepted from day one.
- R8. **Playground app** (user requirement): a runnable Flutter app in the homeric repo that renders documents through HomericParagraph and drives real Phase 1 transactions — every builder (insertText, deleteRange, splitBlock, joinBlocks, moveBlock, setBlockType, toggleMark) plus decoration toggles (hide delimiters, comments/annotations, widget slots) — so text editing is hands-on testable before Phase 3 gives it a keyboard.
- R9. Lifecycle correctness: `Paragraph.dispose()` always called (leak-tracker clean); relayout on `TextScaler` change and system-font change (`RelayoutWhenSystemFontsChangeMixin`); paint-only changes (decoration colors) never trigger reshaping in layout (TextPainter's deferred-rebuild pattern); geometry results stamped with a layout generation so stale reads become asserts.
- R10. Reveal-on-selection is expressible as a derivation input (selection state → which replace decorations are suppressed this frame), demonstrated in the playground — the design that lets Nexus delete `MarkerRevealController`.

---

## Scope Boundaries

- No text input, IME, keyboard, or selection gestures — Phase 3 (HOM-5).
- No multi-block selection UI, scrolling, or virtualization — Phase 4 (HOM-6); the playground caps documents at small/medium size and uses a plain ListView.
- No nexus-repo file changes — companion plan (below).
- No markdown parsing or the concrete syntaxes (`%%`, `++`, `(fn)`…) — the playground constructs decorations programmatically.
- No pub.dev publishing or API stabilization; `publish_to: none` stays.

### Deferred to Follow-Up Work

- **Nexus integration plan** (nexus repo): register the paragraph component via `tightBlockComponentBuilders()`, implement `SelectableMixin` by delegating to the U4 geometry API, delete the four workarounds, run the Nexus-side differential test and `make mutants`. Written once U1–U6 are real.
- Nexus-side `LEARNINGS.md` mirror of Phase 1 entries (still outstanding from HOM-2).
- Pre-Phase-3 decision from the Phase 1 review: export a curated `run_ops` step-authoring subset vs `sealed Step` (HOM-9 adjacent).
- `flutter_lints` bump from 4.0.0 (research note; mechanical, separate chore).

---

## Context & Research

### Relevant Code and Patterns

- `packages/homeric/lib/src/view/` — `deriveViewText` → `(viewText, styledRanges, slots, ViewMap)`; `ViewMap.docToView/viewToDoc({assoc})`; U+FFFC slot = exactly 1 view unit. The render layer consumes this and must not reimplement offset math.
- `packages/homeric/lib/src/decoration/` — decorations carry opaque `spec` payloads; paint-layer specs ride the same field.
- Nexus seam (read-only reference): `nexus/lib/utils/editor_config.dart` (`tightBlockComponentBuilders`), AppFlowy fork `selectable.dart` (seven members with no default implementation — `getBlockRect`, `getSelectionInRange`, `getRectsInSelection`, `getPositionInOffset`, `localToGlobal`, `start()`, `end()` — plus the optional-with-default members Nexus exercises; global-in/local-out), `appflowy_rich_text.dart` (caret/selection semantics to reproduce: `getOffsetForCaret` + `getFullHeightForCaret`, `getBoxesForSelection(boxHeightStyle: max)`, empty-text fallback rect).
- Framework references (read, never copied): `RenderParagraph` (two-painter intrinsics pattern, placeholder dance, semantics tiers, `systemFontsDidChange`), `TextPainter` (layout cache, paint-only deferred rebuild), `RenderEditable` (selection box styles, caret pixel snapping).

### Institutional Learnings

- Nexus postmortem (nexus/LEARNINGS.md 2026-08-08): **classify every offset consumer as document-space or view-space before wiring the map** — some consumers (future IME composing ranges) must not be mapped. Phase 2 encodes the spaces in API names/types.
- Phase 1 learnings: per-end inclusivity, mirror-pair moves, structural sharing — all carried by the layers this plan consumes.

### External References

- Flutter 3.44.4 verified: `GlyphInfo` APIs (`getGlyphInfoAt`, `getClosestGlyphInfoForOffset`) are the framework-preferred caret/hit-test basis; `getBoxesForRange` box styles (`includeLineSpacingMiddle` for gapless selection); placeholders = 1 UTF-16 code unit; `Paragraph.dispose()` mandatory; DPR never keys layout; `TextScaler` (not `textScaleFactor`); FlutterTest default test font (exact metrics: 1-em box, ascent 0.75em); `golden_toolkit` discontinued — built-in `matchesGoldenFile`, geometry assertions preferred; web HTML renderer removed in 3.29 (Paragraph fidelity on web is real now).
- super_text_layout design lesson: decoration layers must paint in the same frame as the text (in-RenderBox layers get this for free); make every geometry API's coordinate space explicit in its name.

---

## Key Technical Decisions

- **Raw `ui.Paragraph` per block, not `TextPainter`**: Homeric needs its own per-block paragraph cache (Phase 4 virtualization) and full control of invalidation; TextPainter's cache is tuned for single-Text widgets. We mirror TextPainter's proven triggers: rebuild+relayout on style/direction/strut/TextScaler/system-font change; relayout-only on width change; **paint-only changes defer the rebuild to `paint()`** with a layout-identity assert (the engine has no in-place attribute update).
- **Layout at wrap width; alignment via `ParagraphStyle`**: avoids re-owning TextPainter's `paintOffset`/`contentWidth` arithmetic; document-coordinate transforms then only add block offset.
- **Geometry built on `GlyphInfo`**, not one-char `getBoxesForRange` hacks: grapheme- and direction-aware caret/hit-test, matching the framework's own migration. Selection rects default to `BoxHeightStyle.includeLineSpacingMiddle` + `BoxWidthStyle.max` (gapless), with the style choice a parameter since AppFlowy uses `max`.
- **Coordinate spaces are typed/named, never bare ints in the render layer**: doc offsets and view offsets get distinct wrapper types (or unmissable naming) at the render-layer surface, per the Nexus postmortem. The ViewMap is internal to the geometry service; consumers never see view offsets.
- **Placeholder pattern copied, not mixin-reused**: `RenderInlineChildrenContainerDefaults` assumes `InlineSpan`/`PlaceholderSpan`; Homeric has no InlineSpan. Copy the ~200-line dance (layout children width-only → `PlaceholderDimensions` → `addPlaceholder` → `getBoxesForPlaceholders` → position/paint/hit-test children; count invariant asserted; `scale: 1.0` always, TextScaler applied to dimensions ourselves).
- **Semantics label = document text** via `attributedLabel`; per-run `semanticsLabel` override is the delimiter-hiding mechanism at the a11y layer; widget slots via `childConfigurationsDelegate`. No text-field flags in Phase 2.
- **Two-paragraph intrinsics**: a separate intrinsics/dry paragraph so intrinsic queries never clobber live placeholder dimensions (RenderParagraph's documented trap).
- **Reveal-on-selection is a derivation input**: the block view is derived from `(block, decorations, revealState)`; selection changes re-derive affected blocks rather than external controllers forcing rebuilds.
- **Playground follows the flutter-architecture skill's layering**: Views are lean widgets; a `ChangeNotifier` view-model owns `(Document, DecorationSet, selection/reveal state)` and exposes transaction commands; no business logic in widgets. The library itself stays layered model → transform → decoration → view → render, enforced by convention + the import-guard test.

---

## Open Questions

### Resolved During Planning

- TextPainter vs raw Paragraph → raw, with mirrored invalidation (above).
- Where does doc↔view translation live → inside the render-layer geometry service; SelectableMixin-shaped consumers see only document coordinates.
- Playground editing before Phase 3 → transaction-driver commands, not simulated typing.
- Nexus integration in this plan → no; companion plan in nexus repo (HOM-4's "lands in Nexus" is satisfied across the pair).

### Deferred to Implementation

- Exact shape of the per-run style bridge (Phase 1 `StyledRange` attrs → `ui.TextStyle`) — settle against real Nexus style structures in the companion plan; Phase 2 defines the contract, playground exercises it.
- Whether `getLineBoundary` affinity patching needs extra handling after doc→view mapping — encode as a test first, fix if red.
- Paragraph cache eviction policy beyond "current blocks" — Phase 4's problem; Phase 2 keeps one live paragraph per mounted block.

---

## Output Structure

    packages/homeric/
    ├── lib/src/render/          # NEW — dart:ui/flutter allowed here (guard test stays on the four Phase 1 dirs)
    │   ├── paragraph_source.dart    # U1: view text + styled ranges + slots → builder inputs
    │   ├── homeric_paragraph.dart   # U2/U3/U5/U6: RenderBox + widget wrapper, paint integration, semantics
    │   ├── paragraph_geometry.dart  # U4: document-coordinate geometry service
    │   └── paint_layers.dart        # U5: underlay/overlay range painting
    ├── test/render/             # unit + golden + differential + semantics tests
    └── examples/playground/     # U7: runnable app (MVVM: view_models/ + views/)

---

## Implementation Units

### U1. ParagraphSource — view text to builder inputs

**Goal:** A pure bridge from Phase 1's `DerivedViewText` + per-run styles to `ParagraphBuilder` inputs (text runs with styles, placeholder slots with dimensions-to-be, paragraph-level style).

**Requirements:** R1, R7, R10

**Dependencies:** None (consumes Phase 1 as-is)

**Files:**
- Create: `packages/homeric/lib/src/render/paragraph_source.dart`
- Test: `packages/homeric/test/render/paragraph_source_test.dart`

**Approach:**
- Inputs: block, decorations, reveal state (which replace decorations are suppressed — R10), per-run style resolver (called per build, R7), block-level paragraph inputs (direction, height, strut, TextScaler).
- Output is a value object: ordered styled text segments + slot descriptors (index, decoration identity) + the ViewMap, ready for U2 to feed a builder. Pure and deterministic → unit-testable without Flutter bindings beyond `dart:ui` types.
- Reveal state suppressing a replace decoration re-derives with that decoration skipped — the mechanism `MarkerRevealController` becomes.

**Test scenarios:**
- Happy path: `**bold**` with hide-delimiters on → segments spell `bold` with the bold style range; reveal state on → segments include delimiters.
- Happy path: widget slot yields exactly one slot descriptor at the right view offset; styled ranges clip around it.
- Edge case: empty block; whole-block replace; adjacent replaces; style resolver called exactly once per run per derivation (no caching across builds).
- Integration: same inputs → identical output (determinism pin, extends Phase 1's fixture).

**Verification:** segment/slot/map outputs pinned for the four Nexus workaround shapes.

---

### U2. HomericParagraph RenderBox — lifecycle core

**Goal:** The RenderBox owning one `ui.Paragraph`: build, layout, paint, dispose, and the full invalidation matrix.

**Requirements:** R1, R7, R9

**Dependencies:** U1

**Files:**
- Create: `packages/homeric/lib/src/render/homeric_paragraph.dart` (render object + minimal widget)
- Modify: `packages/homeric/lib/homeric.dart` (export the render-layer public surface: widget, geometry types, paint-layer contract — grown across U2–U5)
- Test: `packages/homeric/test/render/homeric_paragraph_test.dart`

**Approach:**
- Build via `ParagraphBuilder` from U1's output; `layout(ParagraphConstraints(width: wrapWidth))`; alignment through `ParagraphStyle`; paint at offset.
- Invalidation matrix (from research): content/style/direction/strut/TextScaler → rebuild+relayout; width-only → relayout same paragraph; paint-only spec changes → deferred rebuild in `paint()` with layout-identity assert; `RelayoutWhenSystemFontsChangeMixin` + `systemFontsDidChange` → drop cache.
- `dispose()` disposes the paragraph (and intrinsics paragraph); leak-tracker clean under tests.
- `computeDryLayout`/`computeDryBaseline` + minimal intrinsics via a **separate** intrinsics paragraph (never the live one).
- Layout generation counter incremented on every relayout; geometry results (U4) carry it.

**Execution note:** Characterization-first against FlutterTest font metrics — pin expected sizes/baselines for known text before wiring invalidation paths.

**Patterns to follow:** `RenderParagraph`'s property-setter invalidation table and two-painter intrinsics pattern; `TextPainter.paint`'s deferred-rebuild (read, not copied; provenance comment citing the files consulted).

**Test scenarios:**
- Happy path: known text at fontSize 14 lays out to exactly computable size/baseline (FlutterTest metrics); paint produces output (RepaintBoundary golden, Linux/macOS-guarded).
- Edge case: empty view text (whole-block replace) still has a caret-capable line (height from strut/style); width change relayouts without rebuild (paragraph identity observable via a debug hook); TextScaler change rebuilds.
- Error path: use-after-dispose asserts; placeholder count mismatch throws the descriptive error.
- Integration: system-font change notification triggers relayout (test via `PaintingBinding` debug hooks if available, else documented manual check).

**Verification:** invalidation matrix pinned by tests; no leak-tracker findings; `flutter analyze` clean.

---

### U3. Inline widget children (placeholders)

**Goal:** `widget` decorations rendered as real, measured RenderBox children positioned by the paragraph.

**Requirements:** R1, R4

**Dependencies:** U2

**Files:**
- Modify: `packages/homeric/lib/src/render/homeric_paragraph.dart`
- Test: `packages/homeric/test/render/placeholder_test.dart`

**Approach:**
- Copy the framework dance (documented as such): children laid out width-only-constrained → `PlaceholderDimensions` → `addPlaceholder(w, h, alignment, scale: 1.0)` in view-text order → after layout, `getBoxesForPlaceholders` → per-child paint offsets; paint + hit-test children; null offsets (future ellipsis) skipped.
- Slot identity comes from U1's slot descriptors (decoration `spec` = stable identity per Phase 1's contract).
- Count invariant asserted both ways (builder `placeholderCount` == child count).

**Test scenarios:**
- Happy path: one chip child renders at the slot's box; multi-char anchor → single slot (the Nexus workaround #3/#4 shapes); baseline alignment for text-like chips.
- Edge case: slot at block start/end; two adjacent slots; slot inside a line that wraps; child taller than the line (line height grows).
- Integration: hit test at the chip's rect hits the child, not the text; at adjacent glyphs hits text.

**Verification:** placeholder boxes equal child paint offsets; hit-test partition pinned.

---

### U4. Document-coordinate geometry service

**Goal:** The geometry API the Nexus seam delegates to — all queries in document coordinates, ViewMap internal, `SelectableMixin`-sufficient.

**Requirements:** R2, R4, R5, R9

**Dependencies:** U2, U3

**Files:**
- Create: `packages/homeric/lib/src/render/paragraph_geometry.dart`
- Test: `packages/homeric/test/render/geometry_test.dart`, `packages/homeric/test/render/differential_test.dart`

**Approach:**
- Surface (names make spaces explicit, per the postmortem): caret rect for doc offset+affinity (`getGlyphInfoAt`-based; hidden-run offsets land on the assoc-chosen visible edge); rects for doc range (per-fragment across slots/bidi — never naively merged; box style parameterized, default `includeLineSpacingMiddle`/`max`); doc position for local point (`getClosestGlyphInfoForOffset`, grapheme-aware); word boundary (UAX#29 via paragraph, mapped back affinity-correct); line boundary (affinity preserved through docToView — encoded as a test first); per-slot rect; block rect; empty-block caret fallback via line metrics (boxes are empty on newline-only lines).
- View-only trailing content (future Nexus tails): geometry queryable by slot/range identity, never returns a doc position.
- Every result stamped with U2's layout generation; querying against a stale generation asserts in debug.
- **Differential guard (R5):** corpus of marked-up blocks (reuse `tools/corpus` + hand-built decorated fixtures). For each decorated block, build the baseline block from the derived view text itself (identity ViewMap); compare decorated-render geometry at doc offsets against baseline geometry at `docToView`-mapped view offsets (caret rects per assoc; selection rects over mapped ranges). Mutation check: perturb the ViewMap triples → differential must fail (harness has teeth).

**Execution note:** Test-first for the hidden-run and boundary-affinity cases — they are the off-by-N class HOM-4 warns is "the easiest to ship."

**Test scenarios:**
- Happy path: caret rect at every offset of plain text matches FlutterTest hand-computed values; selection rects across a wrap are gapless.
- Edge case: offset inside a hidden delimiter run (both assoc values); offset at slot boundaries; RTL run inside LTR block (fragmented boxes, per-fragment direction); empty block caret; trailing-whitespace caret clamps like the framework.
- Error path: stale-generation query asserts; out-of-range doc offset throws typed error.
- Integration: the full differential test over the corpus; a `SelectableMixin`-shaped adapter in the test harness maps all six required members onto this API (global-in/local-out convention) and passes a contract checklist — the seam-readiness proof this plan owes HOM-4.

**Verification:** differential green over the corpus; the adapter contract test enumerates each SelectableMixin member with a passing mapping.

---

### U5. Decoration paint layers

**Goal:** Range-driven paint layers — underlay wash below glyphs, underline/overlay above — expressive enough for Nexus's focus dim, mention highlight, and annotation underlay.

**Requirements:** R3, R9

**Dependencies:** U4

**Files:**
- Create: `packages/homeric/lib/src/render/paint_layers.dart`
- Modify: `packages/homeric/lib/src/render/homeric_paragraph.dart` (paint order integration)
- Test: `packages/homeric/test/render/paint_layers_test.dart`

**Approach:**
- A paint layer = (doc range, opaque paint spec, band: underlay | overlay); rects resolved through U4 in the same frame (super_text_layout's lesson — no frame lag by construction).
- Spec interpretation is the consumer's via a painter callback contract; homeric ships two reference painters (solid wash, underline) used by the playground. Animated values (dim amount) enter as spec fields; spec-only changes are paint-only (U2's deferred rebuild path — never reshaping).
- Paint order pinned: underlays < paragraph glyphs (+ placeholder children) < overlays.

**Test scenarios:**
- Happy path: wash rects equal U4 range rects; underline sits on overlay band; golden of a decorated paragraph (guarded platform).
- Edge case: range spanning a slot (fragments painted, slot not washed unless included); zero-length range paints nothing; spec change repaints without relayout (paragraph identity stable).
- Integration: layer over a hidden-delimiter range paints in view space correctly (rects follow the visible text).

**Verification:** paint-order pin + spec-change-is-paint-only pin.

---

### U6. Semantics

**Goal:** Screen readers get document text — delimiters absent, widget slots at the right reading position.

**Requirements:** R6

**Dependencies:** U2, U3

**Files:**
- Modify: `packages/homeric/lib/src/render/homeric_paragraph.dart`
- Test: `packages/homeric/test/render/semantics_test.dart`

**Approach:**
- `describeSemanticsConfiguration`: `attributedLabel` built from **document** text (per-run semantic overrides supported), `textDirection`; `childConfigurationsDelegate` merges widget-child semantics between text runs (framework tier-2 pattern). `markNeedsSemanticsUpdate()` when derivation changes semantic content.
- No text-field flags; read-only static text semantics.

**Test scenarios:**
- Happy path: `**bold**` with hidden delimiters → semantics label is `bold` (no asterisks) — the VoiceOver acceptance encoded platform-independently via `SemanticsTester`.
- Edge case: widget slot with child semantics appears between the right text runs; block with only a widget; reveal state on → label still document text (semantics don't flicker with reveal).
- Integration: documented manual check: VoiceOver on macOS reads prose without asterisks (HOM-4 manual verification; known macOS VoiceOver quirks noted, not blocking).

**Verification:** SemanticsTester assertions green; manual VoiceOver check noted in PR.

---

### U7. Playground app + widget layer

**Goal:** The hands-on surface: render corpus documents through HomericParagraph and drive every Phase 1 editing primitive interactively (the user's stated need).

**Requirements:** R8, R10, R7

**Dependencies:** U1–U5 (U6 parallel-safe)

**Files:**
- Create: `examples/playground/` (pubspec, `lib/main.dart`, `lib/view_models/document_view_model.dart`, `lib/views/` — editor page, transaction panel, decoration panel)
- Modify: `melos.yaml` — add `packages/homeric/examples/*` to the `packages:` glob (currently only `packages/*` is listed; examples are not globbed today), so the playground's tests/analyze run under `melos run test`/`analyze`. Also `README.md` (getting-started: run the playground).
- Test: `examples/playground/test/document_view_model_test.dart`

**Approach:**
- MVVM per the flutter-architecture skill: `DocumentViewModel extends ChangeNotifier` owns `(Document, DecorationSet, selection stub, reveal state)`; exposes commands wrapping every Phase 1 builder + decoration add/remove/toggle + undo-last-transaction (via step inverts — exercising R3 of Phase 1 live); views are lean, listen via `ListenableBuilder`.
- Editor page: ListView of HomericParagraph views (small/medium corpus docs; no virtualization), per-build style resolution from app theme (R7 proof), a caret/selection *display* driven by tapping (geometry API demo — display only, no editing gestures beyond tap-to-place).
- Transaction panel: buttons/command field for builders; decoration panel: hide-delimiters toggle (replace decorations over `**`/`%%` fixtures), annotation/mention washes, widget-chip insertion; reveal-on-selection toggle (R10 demo: place caret inside a hidden range → delimiters reveal).
- This is a consumer-grade dogfood of the public API: playground imports `package:homeric/homeric.dart` only — anything it needs from `src/` is an export gap to fix (feeds the run_ops decision).

**Test scenarios:**
- Happy path: view-model command for each builder mutates the document and notifies exactly once per transaction; undo restores prior doc (deep equality).
- Edge case: commands on empty doc/empty selection no-op as values (no throws to the UI).
- Integration: widget test pumps the editor page, taps a caret position, asserts the caret display rect equals the geometry API's answer.
- Test expectation for pure view scaffolding (panels): none — exercised via the page-level widget test.

**Verification:** `flutter run -d macos` from `examples/playground` shows editable-by-command documents; every builder and decoration kind reachable from the UI; playground uses only public exports.

---

## System-Wide Impact

- **Interaction graph:** render layer consumes model/transform/decoration/view strictly downstream; nothing upstream imports render (dependency direction stays acyclic — convention + review, tooling enforcement deferred).
- **Error propagation:** geometry queries throw typed errors on invalid doc offsets (matching Phase 1's resolve discipline); render lifecycle misuse asserts in debug, never corrupts in release.
- **State lifecycle risks:** paragraph leaks (guarded by dispose tests + leak tracker); stale geometry (guarded by generation stamps); style capture at registration (guarded by per-build resolver contract + playground proof).
- **API surface parity:** the `SelectableMixin` adapter contract test is the parity instrument for the Nexus companion plan.
- **Integration coverage:** differential test (U4) and the playground page test are the cross-layer proofs mocks can't give.
- **Unchanged invariants:** the four Phase 1 module dirs stay Flutter-free (guard test untouched); Phase 1 public API unchanged (additive exports only).

---

## Risk Analysis & Mitigation

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Off-by-N caret bugs on decorated lines (HOM-4's named killer) | Med | High | Differential guard is a unit (U4), not an afterthought; hidden-run/affinity cases test-first; GlyphInfo-based geometry. |
| Placeholder pattern divergence from framework behavior (relayout loops, scale drift) | Med | Med | Copy the documented dance with `scale: 1.0` pinned; count invariant asserted; width-only child constraints (no feedback loop by construction). |
| Paint-only changes accidentally reshaping (perf cliff for animated dim) | Med | Med | Deferred-rebuild path pinned by a paragraph-identity test (U2/U5). |
| Semantics regress silently (VoiceOver reads asterisks) | Low | High | SemanticsTester assertion is CI-stable; manual VoiceOver check on the PR checklist. |
| macOS-only golden flakiness | Med | Low | Geometry assertions primary; pixel goldens few and platform-guarded. |
| Phase 2 stalls without landing in Nexus (checkpoint #2, see `docs/ROADMAP.md` checkpoints) | Med | High | The seam-adapter contract test (U4) proves API sufficiency early; the companion Nexus plan is written once U1–U6 are real and does not wait for U7 polish. |

---

## Sources & References

- **Origin:** Linear [HOM-4](https://linear.app/xana-studios/issue/HOM-4/phase-2-homericparagraph-one-block-rendered-properly) within [HOM-1](https://linear.app/xana-studios/issue/HOM-1/homeric-a-flutter-text-editing-package-built-from-fundamentals); Phase 1 plan: `docs/plans/2026-08-08-001-feat-phase1-editor-core-plan.md` (completed).
- Seam research (this session): `nexus/lib/utils/editor_config.dart`, AppFlowy fork `selectable.dart` / `appflowy_rich_text.dart` / `default_selectable_mixin.dart`; the four workarounds' file map.
- Framework research (this session, Flutter 3.44.4 source-verified): `rendering/paragraph.dart`, `painting/text_painter.dart`, `dart:ui text.dart`, `rendering/editable.dart`, super_text_layout design notes.
- User requirement (2026-08-09, in-session): hands-on editing testability → U7 playground.
