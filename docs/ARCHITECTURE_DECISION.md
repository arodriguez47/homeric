# A Flutter Editor for Ulysses-Class Writing

**Architecture recommendation · June 2026**
Target: desktop (macOS/Windows/Linux) + Android + Web · no collaboration · snappy on 100k+ word documents · footnotes, comments, annotations, backlinks, writing goals, diff/version history.

---

## TL;DR

**Fork [super_editor](https://pub.dev/packages/super_editor) at the `0.3.x` dev line and bolt on three things it does not have: a virtualized viewport, a ProseMirror-style `StepMap`, and a `DecorationSet` for range-anchored overlays. Everything else (footnotes, comments, backlinks, writing goals, diff view) is a feature built *on top* of those three primitives.**

The other candidates fail for hard reasons:

| Option | Verdict | Reason |
|---|---|---|
| Fork [AppFlowy Editor](https://pub.dev/packages/appflowy_editor) | Reject | AGPL-3.0 — toxic for a commercial library. Also path-based addressing (`List<int>`) makes annotation anchors fragile. |
| Fork [fleather/parchment](https://pub.dev/packages/fleather) or [flutter_quill](https://pub.dev/packages/flutter_quill) | Reject | Flat Quill Delta model: no real nesting, weak extensibility, custom block types are second-class. |
| Build from scratch on `RenderObject` | Reject | IME across six platforms is a 12–18 month project on its own. Superlist has already paid that cost. |
| **Fork super_editor 0.3.x** | **Accept** | Immutable node list, `Request → Command → ChangeList → Reaction` pipeline (an honest ProseMirror analogue), MIT, production-tested by Superlist, the only model in Flutter that *can* be retrofitted with virtualization cleanly. |

None of the existing Flutter editors virtualize. That gap is yours to fill, and super_editor's typed-node-list model is the easiest to retrofit.

---

## Why the existing editors will not get you there

A condensed view of what the [research notes](#deliverables) found:

| Editor | Model | License | Virtualization | Extensibility | Verdict |
|---|---|---|---|---|---|
| **super_editor** 0.3.x | Immutable typed node list + `AttributedText` spans | MIT | None | Excellent (ComponentBuilder + Reactions) | **Best foundation** |
| **AppFlowy Editor** 6.x | Node tree + Quill Delta hybrid | **AGPL-3.0** | None | Excellent (slash menu + block builders) | Killed by license |
| **fleather/parchment** | Flat Quill Delta | MIT | None | Weak — no block nesting | Wrong shape for Ulysses |
| **flutter_quill** | Flat Quill Delta | MIT | None | Weakest of the four | Wrong shape |

Three observations matter:

1. **Performance is universally bad on large documents.** All four wrap their content in `Column` inside `SingleChildScrollView`. Every paragraph is built, laid out, and painted whether or not it is on screen. For 100k words (~700 paragraphs), each frame pays the cost of ~700 `Paragraph.layout()` calls. Per [Flutter #92173](https://github.com/flutter/flutter/issues/92173), `Paragraph.layout()` is synchronous, runs on the platform thread, and cannot be isolated — the only sane mitigation is *to not call it for off-screen blocks*.
2. **Tree+Delta hybrids (AppFlowy) double your diff and annotation surface.** You must track positions through both the tree (paths) and Delta offsets inside text nodes. For visual diff and comment anchoring, this is a substantial liability.
3. **`AttributedText` (super_editor's flat span overlay) is simpler than Delta and easier to map through edits.** It is not OT-ready, but you said no collaboration — so OT readiness is the wrong thing to optimize for.

---

## The three things you must add

### 1. Virtualized viewport (the hard one)

Replace `SuperEditor`'s `SingleChildScrollView → Column` with a sliver-based virtualized list. The right primitive is [`SliverVariedExtentList`](https://api.flutter.dev/flutter/widgets/SliverVariedExtentList-class.html) (Flutter 3.16+), which lets you provide each block's height via callback so the scrollbar math works *before* the block is built.

```dart
CustomScrollView(
  slivers: [
    SliverVariedExtentList(
      itemExtentBuilder: (i, _) => heightCache.estimate(document.nodes[i].id),
      delegate: SliverChildBuilderDelegate(
        (ctx, i) => DocumentBlock(
          node: document.nodes[i],
          onMeasured: (h) => heightCache.record(document.nodes[i].id, h),
        ),
        childCount: document.nodes.length,
      ),
    ),
  ],
)
```

The non-trivial pieces:

- **`BlockHeightCache`** — per-node measured heights plus a rolling-average estimator for unseen blocks. Persist this across sessions so cold-start scrollbars don't jitter.
- **Selection across virtualized boundaries** — `SelectionLayout` currently assumes every block is built. When a selection extends above or below the viewport, the off-screen endpoints must be represented logically and clamped visually.
- **`DocumentLayerBuilder` overlays** (selection highlight, decorations, find/replace) must iterate only the visible block range, not the whole document.
- **Scroll-to-node** — required for footnote links, backlinks, find/replace. Cache must support targeted scroll without first building the path of intermediate blocks.

Budget: **6–10 weeks for a working prototype, +4–6 weeks of edge-case hardening**. This is the most expensive piece of the project and the part nobody else has shipped.

### 2. `StepMap` — position mapping through edits

This is the single most important idea to steal from ProseMirror, and the reason annotation systems in Flutter editors are usually broken. Every edit must produce a `StepMap` that translates positions from the old document to the new document.

```dart
abstract class StepMap {
  /// Map a position. `bias` controls behavior at insertion seams.
  int map(int pos, {Bias bias = Bias.right});
  StepMap invert();
  static StepMap compose(StepMap a, StepMap b);
}
```

Wire it into super_editor's pipeline so every `EditCommand` returns `(ChangeList, StepMap)`. Then:

- A comment anchored at `[from, to]` re-maps after every transaction and survives arbitrary edits before, within, and after it.
- A footnote back-reference holds onto a virtual position that survives insertions.
- Version history accumulates the composed `StepMap`s — a [`prosemirror-changeset`](https://github.com/ProseMirror/prosemirror-changeset)-style diff falls out almost for free.

Budget: **3–4 weeks**, and you can port ProseMirror's test suite directly — the math is well-specified.

### 3. `DecorationSet` — non-destructive range annotations

Decorations are the ProseMirror primitive for "things that look like part of the document but aren't part of its content" — selection highlights, spell-check squiggles, comment underlines, search hits, diff insertions. They are *not* attributes on the text; they are an overlay that maps through `StepMap`s.

```dart
class Decoration {
  final String nodeId;
  final int fromOffset;
  final int toOffset;
  final DecorationAttrs attrs; // color, css class, custom widget builder
}

class DecorationSet {
  // Interval-tree backed, persistent.
  List<Decoration> forNode(String nodeId, int from, int to);
  DecorationSet add(Decoration d);
  DecorationSet map(StepMap m);
}
```

Render decorations in `super_text_layout` by injecting inline widgets at offsets, which it already supports for the caret and selection. Budget: **2–3 weeks** for the data structure, **2–3 weeks** for renderer integration.

---

## Everything else falls out of those three pieces

With virtualization + `StepMap` + `DecorationSet` in place, your feature list is mostly composition:

| Feature | How it's built |
|---|---|
| **Footnotes** | `FootnoteAnchorAttribution` (inline) renders as a superscript number; `FootnoteNode` (block) holds the body. Markdown round-trips as `[^1]`. |
| **Inline comments / annotations** | `CommentRangeDecoration(from, to, commentId)` — a `Decoration` that survives edits via `StepMap`. Sidebar is a `DocumentLayerBuilder` that anchors panels to the visible Y of each decoration. |
| **Backlinks / wiki-links** | `WikiLinkAttribution(targetId)` as an inline attribution; a `DocumentChangeListener` maintains a reverse index `targetId → [(docId, nodeId), ...]`. Render with custom styling, click navigates. |
| **Word count + writing goals** | `DocumentChangeListener` walks only the nodes in `ChangeList` (cheap), updates a running total. Goals are UI on top. |
| **Visual diff / version history** | Snapshot the document on save; for diff view, compose all `StepMap`s between snapshots → render insertions as decorations, deletions as inline `DeletedContentWidget`s. ([prosemirror-changeset](https://github.com/ProseMirror/prosemirror-changeset) is the reference algorithm.) |
| **Markdown round-trip** | Fork `super_editor_markdown` and add footnote, wiki-link, and GFM table extensions. Additive only — no core changes. |

None of these are research projects once the three primitives exist. They are all "register a node type / attribution / decoration kind, write a serializer." A small team can land them in weeks, not months.

---

## Platform-specific gotchas

- **Flutter Web + CJK IME** is broken framework-wide ([flutter/flutter #120613](https://github.com/flutter/flutter/issues/120613)). super_editor sidesteps Flutter's `EditableText` and goes directly through `TextInputConnection`, which is partially helpful, but you should plan to document this as a known limitation and ship a fallback HTML-renderer mode if web is a hard requirement.
- **Android delta-editing IME** is the riskiest mobile surface; super_editor already handles it but you'll need to re-run the test matrix after virtualization changes.
- **Desktop keyboard handling** (tabs, modifier-arrow word jumps, triple-click paragraph selection) is mostly already correct in super_editor — don't regress it.
- **Impeller helps raster-thread costs, not text layout.** Don't expect the iOS Impeller story to fix anything here; the bottleneck is `Paragraph.layout()` on the UI thread, which Impeller does not touch.

---

## Suggested roadmap (~8 months solo, ~5 months with two engineers)

| Phase | Weeks | Focus |
|---|---|---|
| 1 — Foundation | 1–4 | Fork super_editor at the latest `0.3.0-dev`. Establish benchmark suite at 10k / 50k / 100k words. Audit the rendering path. |
| 2 — Virtualization | 5–12 | `SliverVariedExtentList` + `BlockHeightCache`; selection across viewport boundaries; layer builders viewport-clipped; scroll-to-node. |
| 3 — Primitives | 13–18 | `StepMap` + `DecorationSet` + their integration with the edit pipeline. Port ProseMirror's StepMap test suite. |
| 4 — Features | 19–26 | Footnotes, comments, backlinks, writing goals, visual diff, markdown extensions. |
| 5 — Platform polish | 27–32 | Desktop keyboard, Android IME revalidation, web limitations doc + optional HTML fallback, perf profiling on real 100k-word docs. |

---

## What to do *now* before writing a line of code

1. **Read super_editor's `0.3.x` source end-to-end**, specifically: `Editor.execute`, `MutableDocument`, `DocumentComposer`, `ComponentBuilder`, `DocumentLayerBuilder`, `SuperTextLayout`. You need to understand the pipeline before you touch it.
2. **Reproduce the perf failure.** Build a benchmark app that renders a 100k-word `MutableDocument` and profile it in release mode. Confirm `Paragraph.layout()` dominates. This becomes your regression suite.
3. **Read [`prosemirror-transform`](https://github.com/ProseMirror/prosemirror-transform)** and especially [`StepMap`](https://github.com/ProseMirror/prosemirror-transform/blob/master/src/map.ts). Port the API to Dart on paper. It is ~500 lines.
4. **Decide on a Web stance.** If Web is must-have day one, prototype the CanvasKit renderer + IME story before committing to the fork. If Web can wait until v2, the project is dramatically less risky.
5. **Pick a name and a license.** MIT or Apache-2.0 — anything that does *not* propagate up the dependency chain, since the value proposition is "the editor a commercial Flutter writing app can adopt."

---

## Supporting research

Five companion documents are in `/home/user/workspace/research/`:

- `editor_landscape.md` — full profiles of each Flutter editor
- `reference_architectures.md` — ProseMirror/Tiptap and Lexical, with Dart port notes
- `flutter_perf_notes.md` — `Paragraph.layout()` realities, sliver protocol, height caching
- `diff_strategies.md` — Myers vs tree diff vs `prosemirror-changeset`
- `recommendation.md` — the long-form version of this document
