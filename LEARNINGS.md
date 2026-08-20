# Learnings

Editor-layer learnings, mirrored with Nexus per the compounding rule in [`AGENTS.md`](AGENTS.md): a learning about text layout, offset mapping, selection geometry, or editor architecture is written to **both** repos in the same change.

## editor-architect — 2026-08-20 — Capture a commit before awaiting its normalization

**What:** A consumer session facade may need two distinct post-mutation
boundaries: a synchronous lossless capture for durability and one settled event
after compatibility normalization. Nexus's temporary AppFlowy host stages a
detached canonical snapshot into its existing save buffer during the engine's
after-transaction dispatch, then awaits structural repair. The repair stays in
the triggering undo group and its tagged nested transaction is folded into the
single settled event.

**Why it mattered:** If the only change event waits on asynchronous
normalization, the controller mutation can return before any durable owner has
seen it. Immediate teardown then correctly invalidates the delayed callback but
silently drops the latest edit. Conversely, publishing repair as a second user
commit exposes transient structure and creates duplicate autosave semantics.

**Rule going forward:** A host adapter transfers a detached lossless snapshot
to its durability owner synchronously at the canonical commit boundary, before
awaiting normalization. It publishes one settled consumer event afterward.
Session/input generations guard both paths, and disposal may cancel delayed
observation but never erase content that was already committed by the core.

## editor-architect — 2026-08-19 — Height reuse and glyph-layout reuse are separate caches

**What:** Natural-height virtualization retained scalar row measurements by
stable block ID, but every recycled `RenderHomericParagraph` still disposed its
shaped `ui.Paragraph`. A reverse traversal therefore repeated every engine
layout even though the height index was warm. The document viewport now owns a
separate bounded LRU of detached shaped paragraphs. A row releases exactly one
paragraph on disposal and can reclaim it only when block ID, source, resolved
styles, scaler, alignment, placeholder dimensions, paint styler, and wrap width
all still match. The cache never supplies a child extent; a miss performs the
same natural layout as before.

**Why it mattered:** Render-object-local caching cannot survive the lifecycle
virtualization deliberately creates. Conversely, putting engine objects into
the height index would couple scroll targeting to presentation ownership and
turn stale estimates into a correctness risk. Keeping the caches separate made
the 100k warmed trace perform zero repeated layouts while preserving 11 mounted
rows and bounding detached state to 2,048 entries and one million UTF-16 code
units.

**Rule going forward:** Cache compact measurements for indexing and cache shaped
engine resources for reuse under different owners. Transfer each engine object
between exactly one render object and one bounded document cache; validate the
complete layout witness before reuse, clear on system-font changes, dispose on
eviction/viewport teardown, and measure cold mount separately from warmed
scroll. Never improve a layout metric by retaining rows or by letting cached
heights constrain natural content.

## editor-architect — 2026-08-19 — A recycled row cannot own a document drag

**What:** Multi-block pointer selection began inside a paragraph, but the
selection anchor, autoscroll generation, and platform-input suspension had to
move to `HomericEditableDocument`. As the pointer autoscrolled, Flutter
recycled unrelated paragraph gesture detectors and invoked their reset
callbacks. Allowing any reset callback to cancel the global drag stopped
selection at the first recycled row. The document now binds each drag to its
starting host capability, keeps the input row alive through release, and
accepts end/cancel only from that owner or from a document-level invalidation.

**Why it mattered:** Virtualization turns ordinary widget disposal into a
high-frequency event. Lifecycle callbacks that are correct for a standalone
paragraph become stale capabilities once selection spans blocks. Without an
owner and generation, recycling can cancel current work, retarget the platform
connection through every intermediate row, or let a disposed row mutate the
current selection.

**Rule going forward:** Canonical document state and any transient operation
that can outlive one mounted row belong to the document host. Row callbacks
carry owner identity and current geometry; document mutation, dependency
replacement, focus loss, pointer cancellation, boundaries, and disposal stop
the operation centrally. Keep natural-height virtualization and input
capability lifetimes separate: a row may recycle freely unless it owns the
active platform epoch, while no recycled row may resurrect selection state.

## editor-architect — 2026-08-18 — Undo must invert mapping metadata, not only steps

**What:** Reversing `Step.invert(docBefore)` calls restored the document but
discarded the source transaction's mirror pairs. For a block move, those pairs
are what route positions through the delete into the matching insertion. The
new `Transaction.inverting` constructor applies inverse steps in reverse and
re-registers every pair at reversed indices.

**Why it mattered:** Document equality made the old undo look correct while a
caret or decoration inside the moved block mapped as `deletedAcross` and could
silently disappear. Content restoration and anchor restoration are separate
contracts; testing only the first leaves the editor's durable identity layer
unprotected.

**Rule going forward:** Build undo mappings through `Transaction.inverting`,
never by folding inverse steps alone. Any transform metadata that changes map
routing must define and test its inverse representation. For moves, pin both a
global caret position and a block-sharded decoration through the forward and
inverse transactions, in addition to asserting document equality.

## editor-architect — 2026-08-19 — A demo consumer must not become a second editor core

**What:** The playground used to own its own document, decorations, caret, transaction application, and undo stack. Adding the real editable paragraph on top would have left keyboard input in `HomericEditorController` while debug buttons and decoration controls mutated a parallel view-model. The migration instead made the view-model a thin adapter around one public controller and one shared epoch-bound input session. A narrow undoable `replaceDecorations` controller intent closed the only missing public seam, so decoration-only controls did not need to reconstruct the controller or retain shadow state.

**Why it mattered:** Parallel state can look correct while each path is tested alone, then lose selection, composition, decoration mapping, or undo order when a writer alternates between keyboard input and consumer controls. Active-block switching raises the same risk for platform input: every paragraph can be an entry point, but exactly one shared session must own the live epoch, committing the old block's visible composition before attaching the new one.

**Rule going forward:** A consumer adapter may translate UI commands into editor intents, but it does not own canonical document, decoration, selection, composition, or history state. If a legitimate consumer control cannot express its change through the controller, add and pin the smallest atomic controller intent instead of creating a shadow store. Share one input session across all one-active-block hosts, and treat theme, width, and projection changes as presentation rebuilds that preserve controller identity, focus, and logical selection.

## editor-architect — 2026-08-19 — Geometry overlays need a structural layout boundary and a current-input gate

**What:** Packaging the repeated paragraph-overlay dance exposed two separate responsibilities. First, overlay presentation must not participate in the paragraph's layout: the paragraph is the sole non-positioned child, while every consumer widget lives inside a fixed `Positioned.fill` plane. Second, a parent rebuild can happen *before* the child render object receives its new width, source, style, or scaler. Building from the held render object during that gap briefly reuses the old generation even though its `GeometryResult` is not stale yet; the relayout that would mark it stale has not run.

**Why it mattered:** The first implementation passed first-layout placement but called the overlay builder twice during a width change (`generation 1`, then `generation 2`). That is a one-frame wrong caret/footnote position, and generation stamping alone cannot detect it because the render object still truthfully reports generation 1 during the parent's build. The producer must compare the render object's actual constraints and layout inputs with the inputs being built now, suppress the overlay while they differ, then rebuild from the geometry callback after layout advances.

**Rule going forward:** A reusable geometry-overlay host enforces layout neutrality structurally, not by asking every feature author to remember `Positioned`. It also distinguishes “current for the last completed layout” from “current for the widget inputs being built now.” Render only when constraints, layout-affecting inputs, the caller's explicit slot-layout revision, and the observed generation all agree. If a conservative slot revision changes but the child measures identically, accept the still-current generation after that frame rather than waiting forever for a relayout signal that correctly never fires. Keep `GeometryResult.isStale` as the separate guard for asynchronous work that outlives a completed layout.

## editor-architect — 2026-08-13 — A generation stamp is not a subscription

**What:** With the journal flag on, inline aside chips rendered and footnote markers, mention hover targets, and annotation tap targets did not. That split *is* the diagnosis, and it localizes the bug before any debugging: chips are slots **inside** the paragraph and land on the first build; everything else is a positioned overlay **derived from** geometry, and geometry does not exist until after layout. The consumer subscribed to the editor's selection notifier and its AppFlowy `Node`; neither fires after first layout, so `overlayBuilder` returned nothing and waited for a next build that only arrived if the writer happened to type in that block.

**Why it mattered:** This is the complement of the 2026-08-09 entry below, and the pair is the whole lesson. There, generation-stamping relocated a missed subscription into a *thrown error* — loud, traceable, fixable. Here there was no signal to subscribe to at all, so the same class of mistake surfaced as **silent absence**: no exception, no wrong pixel, just a feature that never appeared. Silent absence is strictly worse than the throw, and we shipped it by tracking the layout generation privately and documenting "discard before the next relayout" without giving anyone a way to know a relayout happened. A post-frame callback on the consumer side would not have been enough either: geometry also moves on font swap, width change, and edit, and only the render object knows.

**Rule going forward:** Any API whose value only exists after layout ships its change signal **in the same unit**, and the signal is pushed — a callback or `Listenable` — never "the consumer will rebuild for some other reason." Two constraints that fell out and generalize:

* **Deliver the handle, not the derived object.** `onGeometryChanged` hands back the render object, not a `ParagraphGeometry`, because that class memoizes and asserts when held across a relayout — handing one over would manufacture the exact stale-instance case its guard exists to catch.
* **Defer a render-phase signal.** A consumer's natural reaction is `setState`, and mutating render objects during `flushLayout` asserts. The framework's own synchronous-from-`performLayout` notifier (`_RenderSizeChangedWithCallback`) documents the same hazard and dodges it by skipping the initial layout — the opposite of what an overlay signal must do. Use `schedulerPhase == persistentCallbacks → addPostFrameCallback`, coalesced, and read the generation at dispatch rather than at schedule so a double-layout reports the final one. This costs no latency: geometry follows layout follows build, so the consumer's rebuild lands next frame either way.
* **Free when unobserved, structurally.** The dispatch has exactly one call site, the tail of `performLayout`. Paint-only paths (`paintStyler`, `paintLayers`) never reach it, so an animated focus dim ticking every visible block per frame cannot become a rebuild. That is a property of where the call is, not a promise in a doc comment — and it is pinned by a test that mis-wires it and watches the count go from 1 to 11.

## editor-architect — 2026-08-12 — Tokenize the block, not the op, when a layer attribute splits a mark

**What:** A journal-layer attribute on the content character of `**B**` splits the delta into three ops (`**` / `B` / `**`). Homeric's projection tokenized each op in isolation and found no mark; AppFlowy's decorator tokenizes the full block then slices. The comment anchor lost its bold with no error.
**Why it mattered:** The flag flip made this the production path. `journal_markdown_layer_composition_test` was already written to catch per-run parsing — it was the first new failure after the known 19. Matching `_decorateWritingSurfaceRun` on the *branch* (native vs layer-only) is not enough; the tokenizer's *input* has to match too (`buildAscendMarkdownEditorTextSpanForRange` takes the block text).
**Rule going forward:** When a consumer's decorator tokenizes a range of a larger string, the projection that replaces it tokenizes that same larger string. Per-op parsing is only safe when delimiters and content are guaranteed to live in one op.

## editor-architect — 2026-08-12 — A companion plan needs a named owning branch, not just a doc in `docs/plans/`

**What:** Two agents forked the Homeric-paragraph companion plan 17 minutes apart and each implemented U1–U5. The merged branch was not the more advanced one. The plan document landing in `docs/plans/` was treated as a claim on the implementation; it is not.
**Why it mattered:** HOM-12's measurements, the four "closed behind the flag" features, and the flip failure count were all taken on the unmerged duplicate. Reconciling cost more than writing the companion plan. The reusable rule is cheap: a cross-repo companion plan records one owning branch in the plan doc itself, and a second agent starting the same units treats that branch as the work, not a prompt to begin again.
**Rule going forward:** When a plan spans two repos, the plan doc names the single implementation branch. A second session that finds the plan already in `docs/plans/` resumes that branch or stops; it does not open a parallel U1–U5.

## editor-architect — 2026-08-12 — Phase 2's workarounds narrow to the blocks that stay on AppFlowy; they do not delete

**What:** HOM-11's scope sentence said delete four workarounds when the journal flag flips. Measured: typing `# ` on an anchored paragraph carries both halves of the aside onto a heading, which still renders through AppFlowy. `journalAsideAnchorRunRangesIn` is a pure delta query Homeric's projection depends on. Notes and longform still mount AppFlowy paragraphs via `tightBlockComponentBuilders()`'s default-off flag.
**Why it mattered:** Deleting the composite would make a writer's note vanish with no error after a heading conversion. Gating the journal overlay/composite to non-paragraph blocks, and leaving the shared decorator intact for other surfaces, is the actual retirement. Deletion waits for Phase 5 (HOM-7), when AppFlowy goes.
**Rule going forward:** A workaround that is "only needed because of renderer X" is not dead when one surface leaves X. Check every block type and every surface that still mounts X before deleting. The journal flag is journal-scoped; do not thread it into `writing_surface_config.dart`.
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

## orchestrator — 2026-08-18 — A folded delimiter and a soft wrap share one affinity decision

**What was verified:** In `aaaa **bold**`, hiding both delimiter pairs makes
document offset 6, strictly inside the opening delimiter, map to view offset 5,
exactly where the visible text wraps.
`ParagraphGeometry.caretRect` already carries the same `assoc` through both
the document-to-view fold and the visual-line choice: upstream lands at the
end of line 1, downstream at the start of line 2.

**Rule going forward:** A caret regression involving hidden text and wrapping
needs a fixture where the fold edge and wrap offset are literally identical.
Assert the full rectangle for both associations plus pre-wrap, post-wrap, and
wide-layout controls. Comparing two paths that share the same caret algorithm
is useful for mapping drift, but cannot replace independent pixel expectations.

## editor-architect — 2026-08-09 — A seam-adapter contract test proves sufficiency, never agreement

Phase 2's U4 shipped a `SelectableMixin`-shaped adapter test proving every member AppFlowy requires is implementable purely from `ParagraphGeometry`. That claim was true and the test was worth having, and it could not have caught the first three bugs Nexus hit when it actually rendered through us — because *implementable* and *agrees with the renderer next to it* are different properties, and only the second one matters to a consumer running both. Nexus renders paragraphs through Homeric and headings, lists and quotes through AppFlowy in the same document, so a caret that is internally consistent but 4px off its neighbour is still a defect. The reusable rule: an API-sufficiency test belongs in the producing repo, but a *differential* test — both renderers mounted over the same document, answers compared offset by offset — belongs in the consuming one, and no amount of the former substitutes for the latter. Corollary for future phases: when a Phase's exit criterion is "the consumer uses it", the consumer's differential test is the exit criterion, not the producer's contract test.

## editor-architect — 2026-08-09 — What a second renderer actually disagrees about

Concrete inventory from Nexus's differential run, all found in one sitting, none predicted by the plan. (1) `TextHeightBehavior` was unreachable: `_paragraphStyle()` called `getParagraphStyle` without one and `BlockParagraphSpec` had no passthrough, so vertical metrics could not be matched at all — fixed by an opaque passthrough mirroring `strut`. `lineHeight` cannot express it; a multiplier and "does the multiplier pad the block's outer edges" are independent questions. (2) Box styles are a real fork in the road: our `includeLineSpacingMiddle`/`max` defaults are the gapless-highlight choice, AppFlowy asks for `max`/`tight`, and `max` width silently extends a box to the following whitespace (96px against 80px over `alpha`). Parameterizing them, which U4 did, is what made this a consumer decision instead of a blocker. (3) Fragment granularity is a *producer* virtue and a *consumer* liability: our finer per-fragment boxes are what remove Nexus's inline-aside splicing, and they also show hairline seams when painted as a selection highlight — so merging belongs in the consumer, which is the only layer that knows the rects are about to be painted rather than measured. (4) Tie-breaks differ: at a point exactly on a glyph's horizontal centre we round toward the leading edge and AppFlowy toward the trailing. (5) AppFlowy's end-of-text caret sits half-leading (`fontSize * (lineHeight - 1) / 2`) lower than its own carets at every other offset on the same line; ours is uniform. That last one is worth stating plainly: the "divergence" was the other renderer's bug, and the discipline that surfaced it was refusing to widen the comparison epsilon until the difference stopped showing.

## editor-architect — 2026-08-09 — Generation-stamped geometry relocates a missed subscription into a thrown error

`ParagraphGeometry` validates every document offset against the projection it was built from, and results carry a layout generation. That is the right design, and it has a consequence worth knowing before it bites: a consumer that forgets to subscribe to its model's change notifications does not degrade into stale pixels, it *throws*. Nexus's block widget listened to selection changes but not to the AppFlowy `Node` it rendered; AppFlowy mutates nodes in place and announces it with `notify()`, so the first keystroke after mount asked geometry for offset 30 of a zero-length projection and raised `DocOffsetOutOfRangeError` inside a selection notifier — 166 test failures whose stack traces pointed at us and whose cause was a missing `addListener` in the consumer. Two rules fall out. For us: this is a feature, keep the validation, but the error message must name both lengths (it does) because that pair is the entire diagnosis. For consumers: clamp incoming offsets against the geometry's own `docLength`, never against the live model's — between a mutation and the rebuild it triggers those two disagree by construction, and hosts like AppFlowy's selection service are not defensive about exceptions crossing back into them.
## editor-architect — 2026-08-18 — Split block identity is document-scoped, not process-scoped

Process-global counters cannot provide stable editor block identity: unrelated documents perturb their sequence, while undo-restored or consumer-supplied literal namespaces can collide. Implicit production split IDs are canonical lowercase `block-<UUID-v4>`. Transaction allocation guarantees uniqueness only against the current document and reservations in that transaction; history-wide UUID uniqueness remains probabilistic. Deterministic injected suppliers are caller-owned and must retain state across a document's undoable history rather than reset between transactions. An explicit `trailingBlockId` bypasses allocation but still receives structural validation, while seeded property operations continue to provide explicit IDs for reproducible replay. Allocation changes only Homeric `Block.id`; opaque/Nexus metadata is never rewritten.

## editor-architect — 2026-08-20 — Consumer policy belongs before every mutation, and geometry is a revocable capability

**What:** Moving a structured journal onto Homeric required more than exposing the current document. The controller now emits one typed event after each canonical commit, applies one block/range policy to text, structure, external transactions, and history, and runs ordered command interceptors before built-in behavior. Read-only mode closes accepted composition once, detaches platform input, and disables mutation while selection and copy remain available. Editable geometry is exposed only through a document-revision and layout-generation capability; active-caret geometry is flattened into a global rectangle, and a retained capability returns no result as soon as either witness changes.

**Why it mattered:** A consumer-side guard on key events cannot cover platform deltas, clipboard completion, semantics actions, drag reorder, undo/redo, or a custom command that calls back into the controller. Likewise, a retained `ParagraphGeometry` can be internally current for the last layout while already referring to the wrong canonical document. Both gaps create split ownership: one path silently bypasses opaque/read-only policy, while another paints a valid answer for stale input.

**Rule going forward:** Enforce editability and block/range policy at the canonical controller boundary, before callbacks, reveal hooks, history, or state mutation. An interceptor may ignore without mutation, reject without mutation, or handle through at most one observable controller intent. Publish post-commit mappings from the actual transaction—including exact inverse/forward mappings for undo and redo. Expose layout to consumers as a revocable, generation-stamped query capability and publish only flat global geometry outside its synchronous overlay callback.
