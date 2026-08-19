/// ParagraphGeometry: the document-coordinate geometry service (U4) — the
/// API a `SelectableMixin`-shaped seam delegates to.
///
/// Every public query takes and returns **document** offsets/ranges — the
/// block-local content coordinates `Decoration`, `Block.contentLength`, and
/// `ViewMap.docToView`/`viewToDoc` already use. View-text offsets (the
/// `ui.Paragraph`'s own coordinate system) are an implementation detail of
/// this file: they are computed, passed to `dart:ui` query methods, and
/// mapped back before anything crosses this module's public surface. This
/// is the Nexus postmortem's rule ("classify every offset consumer as
/// document-space or view-space before wiring the map") applied at the
/// render-layer boundary: [DocOffset] and [DocRange] are distinct types
/// specifically so a view-text `int` can never be passed where a document
/// offset is expected, or vice versa, without an explicit, visible
/// conversion through a [RenderHomericParagraph.viewMap] call.
///
/// [DocOffset] is a zero-cost `extension type` over `int` — chosen over a
/// full wrapper class because the query surface below does a lot of
/// arithmetic on offsets and a class would make every call site noisier
/// for no safety gain over the extension type (both are equally "not an
/// int" to the type checker; `DocOffset` values are never assignable from a
/// bare `int` without going through the constructor). It intentionally
/// declares no `==`/`hashCode`/`toString` overrides: on the Dart version
/// this package targets, extension types forward [Object] members to their
/// representation (`int`) by default, which is exactly the value equality
/// this type wants, and (empirically, see the analyzer crash this
/// discovery avoided) explicit overrides on a non-`implements` extension
/// type are unreliable on this SDK. Comparison/arithmetic operators are
/// declared explicitly because those are not `Object` members and would
/// not otherwise exist on the type.
///
/// Generation staleness (R9): every query result is a [GeometryResult]
/// stamped with the [RenderHomericParagraph.layoutGeneration] current when
/// the owning [ParagraphGeometry] was *constructed* — not read live from
/// the render object at query time (see [ParagraphGeometry.generation]).
/// Reading [GeometryResult.value] after a later relayout — i.e. consuming a
/// result computed against a `ui.Paragraph` that no longer exists — trips a
/// debug assert, and so does querying a held [ParagraphGeometry] instance
/// itself after its render object has relaid out (the instance's own
/// `_docLength`/placeholder-box caches would otherwise answer from
/// pre-relayout state while silently claiming to be current). This catches
/// the class of bug where a caller caches a caret rect, or the geometry
/// service instance itself, across a frame that changed the block's
/// content or width.
///
/// Provenance (framework sources read, not copied): `TextPainter`'s
/// `_computeCaretMetrics` (GlyphInfo-based caret placement: anchor-to-
/// leading/trailing-edge by affinity, the zero-size-placeholder recursion
/// workaround for https://github.com/flutter/flutter/issues/120836, the
/// end-of-text fallback). We deliberately do **not** reproduce
/// `getOffsetForCaret`'s content-width clamp: that hides trailing spaces
/// in a display `Text` widget, and Homeric is editor geometry. See
/// [_endOfTextCaretMetrics]. `RenderEditable`'s selection box style
/// defaults. See also `../view/view_map.dart` for the `assoc`
/// convention this file reuses verbatim (`-1` associates with content
/// before a position, `1` — the default — with content after it) rather
/// than introducing a second, competing affinity vocabulary: the same
/// value both chooses the visible edge of a folded doc span
/// (`ViewMap.docToView`) and, threaded into `dart:ui`'s `TextAffinity`,
/// disambiguates a view offset that also happens to sit at a line-wrap
/// point. This is deliberate, not incidental — see [wordBoundaryAt] and
/// [lineBoundaryAt].
library;

import 'dart:ui' as ui;

import 'package:flutter/rendering.dart'
    show Offset, Rect, TextAlign, TextDirection;

import '../model/selection.dart' show HomericCaretAffinity;
import '../view/view_map.dart';
import 'homeric_paragraph.dart';
import 'paragraph_source.dart' show ParagraphDirection;

/// A document-content offset, block-local, in `[0, docLength]` — never a
/// view-text offset. See the library documentation for why this is a
/// distinct type rather than a bare `int`.
extension type const DocOffset(int value) {
  /// Offset zero.
  static const DocOffset zero = DocOffset(0);

  /// Offset shifted by [delta] (which may be negative).
  DocOffset operator +(int delta) => DocOffset(value + delta);

  /// The (possibly negative) distance from [other] to this offset.
  int operator -(DocOffset other) => value - other.value;

  bool operator <(DocOffset other) => value < other.value;
  bool operator <=(DocOffset other) => value <= other.value;
  bool operator >(DocOffset other) => value > other.value;
  bool operator >=(DocOffset other) => value >= other.value;
}

/// A half-open document-content range `[start, end)`, block-local.
final class DocRange {
  /// Creates a range. Throws [ArgumentError] if [end] precedes [start].
  DocRange(this.start, this.end) {
    if (end < start) {
      throw ArgumentError.value(
          end, 'end', 'must not precede start (${start.value})');
    }
  }

  /// A collapsed range at [offset] — the doc-range shape of a caret.
  factory DocRange.collapsed(DocOffset offset) => DocRange(offset, offset);

  /// Start of the range (inclusive).
  final DocOffset start;

  /// End of the range (exclusive).
  final DocOffset end;

  /// Whether the range is empty (a caret position).
  bool get isCollapsed => start == end;

  /// The range's length in document content units.
  int get length => end - start;

  @override
  bool operator ==(Object other) =>
      other is DocRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start.value, end.value);

  @override
  String toString() => 'DocRange([${start.value}, ${end.value}))';
}

/// Thrown when a [DocOffset] passed to a [ParagraphGeometry] query lies
/// outside `[0, docLength]` for the block being queried.
///
/// An [Exception], not an [Error]: an out-of-range document offset is an
/// expected, recoverable condition a caller can be handed (e.g. a caret
/// position computed against a document that changed underneath it before
/// the query ran) — not a programmer bug the way [UnknownSlotError] is.
/// Callers are expected to catch this and recover (see
/// `examples/playground/lib/views/editor_page.dart`'s caret-overlay build,
/// which does exactly that), matching Dart's Error-vs-Exception convention.
final class DocOffsetOutOfRangeError implements Exception {
  /// Creates the error for [offset] against a block whose content is
  /// [docLength] units long.
  DocOffsetOutOfRangeError(this.offset, this.docLength);

  /// The offending offset.
  final DocOffset offset;

  /// The block's document content length at the time of the failed query.
  final int docLength;

  @override
  String toString() => 'DocOffsetOutOfRangeError: offset $offset is outside '
      'the document range [0, $docLength]';
}

/// Thrown when a slot is addressed by an index or spec identity that does
/// not exist among the paragraph's current slots.
final class UnknownSlotError extends Error {
  /// Creates the error. Exactly one of [index] or [spec] is set, matching
  /// which lookup failed.
  UnknownSlotError({this.index, this.spec})
      : assert((index == null) != (spec == null),
            'exactly one of index/spec identifies the failed lookup');

  /// The out-of-range slot index, if that was the failed lookup.
  final int? index;

  /// The unmatched slot spec identity, if that was the failed lookup.
  final Object? spec;

  @override
  String toString() => index != null
      ? 'UnknownSlotError: no slot at index $index'
      : 'UnknownSlotError: no slot with spec identity '
          '${Error.safeToString(spec)}';
}

/// A geometry query result stamped with the [RenderHomericParagraph.
/// layoutGeneration] current when it was computed (R9).
///
/// [value] asserts, in debug mode, that the owning paragraph has not been
/// relaid out since — the mechanism that turns a stale-geometry bug (a
/// cached rect surviving a relayout) into an assert instead of a silently
/// wrong pixel position. [isStale] offers a non-asserting check for callers
/// that want to detect and re-query rather than crash (release builds skip
/// the assert entirely, matching every other debug assert in this
/// library).
///
/// To learn *when* to re-query rather than polling [isStale], take
/// [HomericParagraph.onGeometryChanged] — it fires once per relayout and
/// carries the new generation.
final class GeometryResult<T> {
  const GeometryResult._(this._value, this.generation, this._owner);

  final T _value;
  final ParagraphGeometry _owner;

  /// The layout generation this result was computed against.
  final int generation;

  /// Whether the owning render object has been relaid out since this
  /// result was computed.
  ///
  /// Deliberately compares against [ParagraphGeometry._render]'s **live**
  /// `layoutGeneration` — not [ParagraphGeometry.generation], which is
  /// fixed at the owning instance's construction time (see that getter's
  /// doc comment) and so cannot, by itself, detect a relayout that happens
  /// after this result was already computed. The two staleness checks in
  /// this file are complementary, not redundant: [ParagraphGeometry]'s own
  /// `_checkNotStale` catches a *held instance* queried after a relayout;
  /// this getter catches a *held result* consumed after one.
  bool get isStale => generation != _owner._render.layoutGeneration;

  /// The computed value.
  ///
  /// Asserts (debug mode only) that [generation] still matches the owning
  /// render object's current layout generation. Consuming a stale result in
  /// a release build returns the value as computed — geometry from a
  /// superseded layout, not a crash — since only debug builds pay for the
  /// check.
  T get value {
    assert(
        !isStale,
        'Stale ParagraphGeometry result: computed at generation $generation '
        'but the paragraph is now at generation '
        '${_owner._render.layoutGeneration}. Re-query after relayout '
        'instead of holding a result across it.');
    return _value;
  }

  @override
  String toString() =>
      'GeometryResult<$T>(gen $generation${isStale ? ', STALE' : ''}, '
      '$_value)';
}

/// A physical direction in which to move a visual caret.
///
/// These are deliberately visual directions rather than logical document
/// directions. In particular, [left] and [right] follow the laid-out glyph
/// order through bidi runs, while [up] and [down] target adjacent visual
/// lines.
enum CaretMovementDirection { left, right, up, down }

/// The result of one visual caret movement in document coordinates.
///
/// [position] and [affinity] together identify a visible caret stop. The
/// affinity is essential where one document position has two visual homes,
/// such as a soft wrap, bidi boundary, or inline slot. [caretRect] is the
/// exact rect from the same geometry generation as the movement query.
///
/// [preferredX] is non-null only after vertical movement. Feed it into the
/// next vertical query to retain the original column across short lines;
/// horizontal movement returns null so the controller can reset that state.
final class CaretMovementResult {
  const CaretMovementResult({
    required this.position,
    required this.affinity,
    required this.caretRect,
    required this.preferredX,
  });

  /// The resulting block-local document position.
  final DocOffset position;

  /// The visual side occupied at [position].
  final HomericCaretAffinity affinity;

  /// The resulting zero-width caret rect in paragraph-local coordinates.
  final Rect caretRect;

  /// The retained vertical target x, or null after horizontal movement.
  final double? preferredX;
}

/// The document-coordinate geometry service over one [RenderHomericParagraph]
/// — every query in, and every result out, in document offsets/ranges; the
/// block's [ViewMap] is an internal implementation detail (R2).
///
/// A thin wrapper: nothing here is cached beyond what
/// [RenderHomericParagraph] itself caches (the live `ui.Paragraph`) plus a
/// couple of per-instance memoizations (see [docLength],
/// [_placeholderBoxes]) that trade "always fresh" for "cheap within one
/// paint's query burst." Construct fresh per query burst — cheap — and
/// discard before the next relayout: holding one across a relayout of its
/// render object is a bug this class catches for you (debug asserts, see
/// [_checkNotStale]), not a supported cache-reuse pattern.
///
/// "Discard before the next relayout" needs a way to know a relayout
/// happened. `ParagraphOverlay` packages that lifecycle for positioned
/// consumer UI; the lower-level [HomericParagraph.onGeometryChanged] signal
/// remains available for other integrations.
class ParagraphGeometry {
  /// Wraps [render] — construct fresh per query burst; cheap. Captures
  /// [RenderHomericParagraph.layoutGeneration] at this exact moment (see
  /// [generation]); every query against this instance is checked against
  /// that captured value, not the render object's current one.
  ParagraphGeometry(this._render)
      : _constructedGeneration = _render.layoutGeneration;

  final RenderHomericParagraph _render;

  /// The layout generation captured when this [ParagraphGeometry] was
  /// constructed.
  final int _constructedGeneration;

  /// The layout generation every [GeometryResult] from this instance is
  /// stamped with (R9) — fixed at construction time via
  /// [_constructedGeneration], deliberately **not** a live read of
  /// [RenderHomericParagraph.layoutGeneration].
  ///
  /// A live read here would defeat R9 for exactly the seam this class
  /// exists to support: a caller that holds one [ParagraphGeometry]
  /// instance across a relayout of its render object (e.g. a
  /// `SelectableMixin`-shaped adapter reusing one instance for its whole
  /// lifetime) would have every result silently re-stamped with the
  /// render object's *current* generation on each query, so
  /// [GeometryResult.isStale] could never observe the relayout — even
  /// though [docLength] and [_placeholderBoxes] below are still answering
  /// from state memoized before that relayout happened. See
  /// [_checkNotStale] for the complementary guard that makes querying such
  /// a held instance fail loudly instead.
  int get generation => _constructedGeneration;

  ViewMap get _viewMap => _render.viewMap;
  ui.Paragraph get _paragraph => _render.layoutParagraph;
  String get _viewText => _render.source.viewText;

  /// Asserts (debug builds only) that [_render] has not been relaid out
  /// since this [ParagraphGeometry] was constructed.
  ///
  /// Every public query funnels through here — the [GeometryResult]-
  /// returning ones via [_stamp], and [docLength] (the one public query
  /// that is not itself wrapped in a [GeometryResult]) directly — so a
  /// stale-instance query fails loudly in debug builds instead of silently
  /// answering from this instance's pre-relayout memoized state
  /// ([_docLength], [_placeholderBoxes]) while claiming, via
  /// [GeometryResult.isStale], to be current.
  void _checkNotStale() {
    assert(
        _render.layoutGeneration == _constructedGeneration,
        'Stale ParagraphGeometry: this instance was constructed at layout '
        'generation $_constructedGeneration but its render object is now '
        'at generation ${_render.layoutGeneration}. A ParagraphGeometry '
        'must not be queried after a relayout of the render object it '
        'wraps — construct a fresh one instead of holding this one across '
        'the relayout.');
  }

  GeometryResult<T> _stamp<T>(T value) {
    _checkNotStale();
    return GeometryResult<T>._(value, generation, this);
  }

  /// The document content length of the block this geometry serves.
  ///
  /// Derived from the block's own [ViewMap], not threaded in separately:
  /// `viewToDoc` extrapolates positions beyond the last folded span by the
  /// cumulative length delta (see `StepMap.mapResult`'s trailing-range
  /// formula) — exactly the document length, since the paragraph's view
  /// text tail beyond every fold is a 1:1 copy of the document's tail.
  ///
  /// Memoized on this instance: this does not change the "construct fresh
  /// per paint" design (a new [ParagraphGeometry] is still built fresh
  /// every `paint()` call per R9's staleness guarantee) — it only removes
  /// redundant re-derivation across the several queries one instance
  /// serves within a single paint (`rectsForRange`/`caretRect`/
  /// `wordBoundaryAt`/`lineBoundaryAt` each call `_checkOffset`/
  /// `_checkRange`, which read [docLength]).
  int get docLength {
    _checkNotStale();
    return _docLength;
  }

  late final int _docLength = _viewMap.viewToDoc(_viewText.length, assoc: 1);

  void _checkOffset(DocOffset offset) {
    final length = docLength;
    if (offset.value < 0 || offset.value > length) {
      throw DocOffsetOutOfRangeError(offset, length);
    }
  }

  void _checkRange(DocRange range) {
    _checkOffset(range.start);
    _checkOffset(range.end);
  }

  /// Maps a document range to the view range covering exactly its visible
  /// content — the same "shrink to visible" convention `deriveViewText`
  /// uses for styled ranges: [DocRange.start] associates forward (`assoc:
  /// 1`, the edge after anything folded there) and [DocRange.end]
  /// backward (`assoc: -1`, the edge before). A range entirely inside one
  /// folded span collapses to an empty view range.
  (int, int) _viewRangeOf(DocRange range) => (
        _viewMap.docToView(range.start.value, assoc: 1),
        _viewMap.docToView(range.end.value, assoc: -1),
      );

  /// Maps a view range back to a document range with the **expand**
  /// convention — deliberately the opposite of [_viewRangeOf]: the start
  /// edge looks backward (`assoc: -1`, into whatever is folded
  /// immediately before it) and the end edge looks forward (`assoc: 1`,
  /// into whatever is folded immediately after it).
  ///
  /// This is the documented "view-space word/line" residual: word- and
  /// line-boundary analysis runs over view text, which has no notion of
  /// the hidden document content sitting at its edges. A hidden delimiter
  /// run immediately adjacent to (i.e. touching) a UAX#29 word's view-text
  /// boundary is swallowed into the mapped document range rather than
  /// left dangling outside it — e.g. double-clicking the word "bold" in
  /// "**bold**" with the delimiters hidden selects the whole `**bold**`
  /// document span, not just `bold`, matching the classic hidden-markdown
  /// editor UX (deleting the "word" should not orphan the syntax). Use
  /// [_viewRangeOf]'s shrink convention instead for anything that must
  /// stay inside visible content (selection rects; a range cannot draw a
  /// box over text that was never emitted).
  DocRange _docRangeOf(int viewStart, int viewEnd) => DocRange(
        DocOffset(_viewMap.viewToDoc(viewStart, assoc: -1)),
        DocOffset(_viewMap.viewToDoc(viewEnd, assoc: 1)),
      );

  // --- Block / slot geometry ---------------------------------------------

  /// The paragraph's own bounding box, in its local coordinate space
  /// (`Offset.zero & size`).
  GeometryResult<Rect> get blockRect => _stamp(Offset.zero & _render.size);

  /// The rect of the slot at [slotIndex] (the `addPlaceholder` order —
  /// same as [RenderHomericParagraph.source]'s `slots` list index).
  ///
  /// Throws [UnknownSlotError] if no slot exists at that index, or if the
  /// paragraph has fewer placeholder boxes than slots this layout (a
  /// future ellipsis case — U3 already tolerates it for children, this
  /// query surfaces it instead of returning a wrong box).
  GeometryResult<Rect> slotRectAt(int slotIndex) {
    final slots = _render.source.slots;
    if (slotIndex < 0 || slotIndex >= slots.length) {
      throw UnknownSlotError(index: slotIndex);
    }
    final boxes = _placeholderBoxes;
    if (slotIndex >= boxes.length) {
      throw UnknownSlotError(index: slotIndex);
    }
    return _stamp(boxes[slotIndex].toRect());
  }

  /// `getBoxesForPlaceholders()` is a `dart:ui` engine call; memoized here
  /// so a burst of slot queries against one instance invokes it once
  /// instead of once per query.
  late final List<ui.TextBox> _placeholderBoxes =
      _paragraph.getBoxesForPlaceholders();

  /// The rect of the slot whose decoration carries [spec] as its stable
  /// identity (see `SlotSegment.spec`).
  ///
  /// Throws [UnknownSlotError] if no current slot carries that identity.
  GeometryResult<Rect> slotRectForSpec(Object? spec) {
    final slots = _render.source.slots;
    final index = slots.indexWhere((slot) => slot.spec == spec);
    if (index == -1) {
      throw UnknownSlotError(spec: spec);
    }
    return slotRectAt(index);
  }

  // --- Caret ---------------------------------------------------------------

  /// The caret rect for document offset [doc], with [assoc] choosing both
  /// the visible edge of any folded span [doc] sits inside ("no phantom
  /// caret slots" — see `ViewMap`) and, when the resulting view offset
  /// also happens to fall at a line-wrap point, which line the caret
  /// belongs to.
  ///
  /// The rect is zero-width (`left == right`), positioned at the exact
  /// caret x — painting an actual cursor stroke of some width is the
  /// consumer's layer, matching `TextPainter.getOffsetForCaret`'s split
  /// from `RenderEditable`'s cursor painting.
  ///
  /// An empty block (zero laid-out lines) falls back to
  /// [RenderHomericParagraph.preferredLineHeight] /
  /// [RenderHomericParagraph.preferredLineBaseline] — the only case this
  /// method does not derive from `GlyphInfo`, because there is no glyph.
  ///
  /// Throws [DocOffsetOutOfRangeError] if [doc] is outside `[0,
  /// docLength]`.
  GeometryResult<Rect> caretRect(DocOffset doc, {int assoc = 1}) {
    _checkOffset(doc);
    final viewOffset = _viewMap.docToView(doc.value, assoc: assoc);
    return _stamp(_caretRectForView(viewOffset, assoc));
  }

  Rect _caretRectForView(int viewOffset, int assoc) {
    if (_paragraph.numberOfLines == 0) {
      return _emptyBlockCaretRect();
    }
    final metrics = _caretMetrics(viewOffset, assoc);
    return Rect.fromLTRB(metrics.x, metrics.top, metrics.x, metrics.bottom);
  }

  /// The caret rect for an empty (glyph-less) paragraph: the full
  /// preferred line height at the paragraph's start edge. Unlike every
  /// other caret rect in this file, there is no `GlyphInfo` to derive this
  /// from — [RenderHomericParagraph.preferredLineHeight] (from the
  /// space-glyph layout template, see that file's docs) is the only
  /// source of a caret-capable height here.
  Rect _emptyBlockCaretRect() {
    final x = _startEdgeX();
    return Rect.fromLTRB(x, 0, x, _render.preferredLineHeight);
  }

  /// The x-coordinate of the paragraph's start edge — where a caret in an
  /// empty (glyph-less) paragraph belongs, honoring alignment and
  /// direction exactly as an aligned line of text would (mirrors
  /// `TextPainter._computePaintOffsetFraction`, read not copied).
  double _startEdgeX() {
    final direction = switch (_render.source.spec.direction) {
      ParagraphDirection.ltr => TextDirection.ltr,
      ParagraphDirection.rtl => TextDirection.rtl,
    };
    final fraction = switch ((_render.textAlign, direction)) {
      (TextAlign.left, _) => 0.0,
      (TextAlign.right, _) => 1.0,
      (TextAlign.center, _) => 0.5,
      (TextAlign.start || TextAlign.justify, TextDirection.ltr) => 0.0,
      (TextAlign.start || TextAlign.justify, TextDirection.rtl) => 1.0,
      (TextAlign.end, TextDirection.ltr) => 1.0,
      (TextAlign.end, TextDirection.rtl) => 0.0,
    };
    return fraction == 0.0 ? 0.0 : fraction * _render.size.width;
  }

  bool _isNewlineBefore(int viewOffset) =>
      viewOffset > 0 &&
      viewOffset <= _viewText.length &&
      _viewText.codeUnitAt(viewOffset - 1) == 0x0A;

  /// GlyphInfo-based caret placement, mirroring `TextPainter.
  /// _computeCaretMetrics` (provenance in the library doc comment): anchor
  /// to the leading edge of the grapheme at [viewOffset] for a downstream
  /// -like [assoc], or the trailing edge of the previous grapheme for an
  /// upstream-like one — except at the very start of the text or right
  /// after a hard line break, which always anchor downstream (there is no
  /// "previous" grapheme on this line to trail).
  _CaretMetrics _caretMetrics(int viewOffset, int assoc) {
    final (int anchorOffset, bool leading) = switch (viewOffset) {
      0 => (0, true),
      _ when assoc >= 0 => (viewOffset, true),
      _ when _isNewlineBefore(viewOffset) => (viewOffset, true),
      _ => (viewOffset - 1, false),
    };
    return _caretMetricsAt(anchorOffset, leading);
  }

  _CaretMetrics _caretMetricsAt(int anchorOffset, bool leading) {
    final info = _paragraph.getGlyphInfoAt(anchorOffset);
    if (info == null) {
      return _endOfTextCaretMetrics();
    }
    final range = info.graphemeClusterCodeUnitRange;
    if (range.start == range.end) {
      // Works around a SkParagraph bug where zero-size placeholders (a
      // real Homeric case — U3's "empty slot child") report a collapsed
      // (0, 0) range regardless of their true offset: retry one code unit
      // later, matching TextPainter's workaround for the same bug
      // (flutter/flutter#120836).
      return _caretMetricsAt(anchorOffset + 1, true);
    }
    if (leading && range.start != anchorOffset) {
      // anchorOffset lands mid-grapheme (a multi-code-unit character):
      // there is no valid caret there, so treat it as landing right after.
      return _caretMetricsAt(range.end, true);
    }
    final boxes = _paragraph.getBoxesForRange(range.start, range.end,
        boxHeightStyle: ui.BoxHeightStyle.strut);
    final anchorToLeft = switch (info.writingDirection) {
      TextDirection.ltr => leading,
      TextDirection.rtl => !leading,
    };
    final box = anchorToLeft ? boxes.first : boxes.last;
    return _CaretMetrics(
        x: anchorToLeft ? box.left : box.right,
        top: box.top,
        bottom: box.bottom);
  }

  /// The caret at the very end of a non-empty paragraph: anchored to the
  /// trailing edge of the last grapheme, **including trailing spaces**.
  ///
  /// `TextPainter.getOffsetForCaret` clamps to `line.width`, which the
  /// engine reports excluding trailing whitespace. That is the right
  /// behavior for a display `Text` widget. Homeric answers editor
  /// geometry: a caret that snaps back to the last non-space glyph makes
  /// typed spaces invisible until the next non-space keystroke — the
  /// writer cannot tell they were inserted. Glyph boxes for those spaces
  /// still have advance (`getBoxesForRange` on the last space is past
  /// `line.width`); we follow the box, not the clamp.
  _CaretMetrics _endOfTextCaretMetrics() {
    final text = _viewText;
    // No block text ever embeds a hard line break (Homeric splits
    // paragraphs into separate blocks instead — see block.dart), so the
    // last grapheme is always on the paragraph's last line.
    final lastGraphemeStart = _paragraph
        .getGlyphInfoAt(text.length - 1)!
        .graphemeClusterCodeUnitRange
        .start;
    final info = _paragraph.getGlyphInfoAt(lastGraphemeStart)!;
    final range = info.graphemeClusterCodeUnitRange;
    final boxes = _paragraph.getBoxesForRange(range.start, range.end,
        boxHeightStyle: ui.BoxHeightStyle.strut);
    final trailingLtr = info.writingDirection == TextDirection.ltr;
    final box = trailingLtr ? boxes.last : boxes.first;
    final x = trailingLtr ? box.right : box.left;
    return _CaretMetrics(x: x, top: box.top, bottom: box.bottom);
  }

  // --- Selection rects -----------------------------------------------------

  /// The fragment-correct rects covering document range [range]: one
  /// `TextBox` per visually-contiguous fragment (bidi runs and slot
  /// placeholders never merge into a neighboring fragment — that is a
  /// property of `ui.Paragraph.getBoxesForRange` this method deliberately
  /// does not post-process away), each still carrying its own
  /// [ui.TextBox.direction] for callers that must render per-fragment
  /// (e.g. a bidi selection where two adjacent boxes read in opposite
  /// directions).
  ///
  /// [heightStyle]/[widthStyle] default to `includeLineSpacingMiddle` /
  /// `max` — AppFlowy's own default, and the shape that yields gapless
  /// selection rects across a wrapped line.
  ///
  /// Throws [DocOffsetOutOfRangeError] if either end of [range] is outside
  /// `[0, docLength]`.
  GeometryResult<List<ui.TextBox>> rectsForRange(
    DocRange range, {
    ui.BoxHeightStyle heightStyle = ui.BoxHeightStyle.includeLineSpacingMiddle,
    ui.BoxWidthStyle widthStyle = ui.BoxWidthStyle.max,
  }) {
    _checkRange(range);
    final (viewStart, viewEnd) = _viewRangeOf(range);
    if (viewEnd <= viewStart) {
      return _stamp(const <ui.TextBox>[]);
    }
    return _stamp(_paragraph.getBoxesForRange(viewStart, viewEnd,
        boxHeightStyle: heightStyle, boxWidthStyle: widthStyle));
  }

  // --- Hit testing -----------------------------------------------------------

  /// The document position closest to local point [point] — grapheme-aware
  /// (`getClosestGlyphInfoForOffset`), landing on whichever half of the
  /// closest grapheme's box [point] falls in, then mapped back to document
  /// coordinates through [ViewMap.viewToDoc].
  ///
  /// Every point resolves to a real document position: one of the two
  /// boundary edges of whatever folded/view-only content (a hidden
  /// delimiter run, a widget slot) the point happens to land on or near.
  /// There is no "position inside a replacement" or "position inside a
  /// slot" — neither exists in the document, so a point query never
  /// invents one; it always answers with the nearest edge that does.
  ///
  /// An empty paragraph (no glyphs at all — e.g. a whole-block replace)
  /// has no geometry to be closest to and falls back to document offset
  /// zero.
  GeometryResult<DocOffset> positionForPoint(Offset point) {
    final info = _paragraph.getClosestGlyphInfoForOffset(point);
    if (info == null) {
      return _stamp(DocOffset.zero);
    }
    final range = info.graphemeClusterCodeUnitRange;
    final bounds = info.graphemeClusterLayoutBounds;
    final midX = bounds.left + bounds.width / 2;
    final leading = switch (info.writingDirection) {
      TextDirection.ltr => point.dx <= midX,
      TextDirection.rtl => point.dx >= midX,
    };
    final viewOffset = leading ? range.start : range.end;
    final assoc = leading ? -1 : 1;
    return _stamp(DocOffset(_viewMap.viewToDoc(viewOffset, assoc: assoc)));
  }

  // --- Visual caret navigation --------------------------------------------

  /// Moves the caret at [position] to an adjacent visual stop.
  ///
  /// Horizontal movement follows laid-out grapheme edges, including distinct
  /// sides of bidi boundaries, soft wraps, folds, and inline slots. Vertical
  /// movement chooses the closest stop on the adjacent visual line to
  /// [preferredX], or to the current caret x when no preferred x is supplied.
  /// Movement clamps at paragraph edges.
  ///
  /// Every returned position is in block-local document space. View offsets
  /// and glyph-cluster boundaries remain private implementation details; this
  /// method does not provide deletion ranges or otherwise define canonical
  /// mutation boundaries.
  GeometryResult<CaretMovementResult> moveCaret(
    DocOffset position, {
    HomericCaretAffinity affinity = HomericCaretAffinity.downstream,
    required CaretMovementDirection direction,
    double? preferredX,
  }) {
    _checkOffset(position);
    final current = _stopFor(position, affinity);
    final target = switch (direction) {
      CaretMovementDirection.left => _horizontalStop(current, -1),
      CaretMovementDirection.right => _horizontalStop(current, 1),
      CaretMovementDirection.up =>
        _verticalStop(current, -1, preferredX ?? current.rect.left),
      CaretMovementDirection.down =>
        _verticalStop(current, 1, preferredX ?? current.rect.left),
    };
    final retainedX = switch (direction) {
      CaretMovementDirection.left || CaretMovementDirection.right => null,
      CaretMovementDirection.up ||
      CaretMovementDirection.down =>
        preferredX ?? current.rect.left,
    };
    return _stamp(CaretMovementResult(
      position: target.position,
      affinity: target.affinity,
      caretRect: target.rect,
      preferredX: retainedX,
    ));
  }

  _VisualCaretStop _horizontalStop(_VisualCaretStop current, int delta) {
    final stops = _visualCaretStops;
    final index = stops.indexOf(current);
    final target = (index + delta).clamp(0, stops.length - 1);
    return stops[target];
  }

  _VisualCaretStop _verticalStop(
      _VisualCaretStop current, int lineDelta, double preferredX) {
    final lines = _visualCaretLines;
    final currentLine = lines
        .indexWhere((line) => line.any((stop) => identical(stop, current)));
    final targetLine = (currentLine + lineDelta).clamp(0, lines.length - 1);
    return lines[targetLine].reduce((best, candidate) {
      final bestDistance = (best.rect.left - preferredX).abs();
      final candidateDistance = (candidate.rect.left - preferredX).abs();
      return candidateDistance < bestDistance ? candidate : best;
    });
  }

  _VisualCaretStop _stopFor(DocOffset position, HomericCaretAffinity affinity) {
    final assoc = _assocFor(affinity);
    for (final stop in _visualCaretStops) {
      if (stop.position == position && stop.affinity == affinity) return stop;
    }
    final view = _viewMap.docToView(position.value, assoc: assoc);
    final rect = _caretRectForView(view, assoc);
    final stopsAtRect = _visualCaretStops
        .where((stop) => stop.rect == rect)
        .toList(growable: false);
    for (final stop in stopsAtRect) {
      if (stop.position == position && stop.affinity == affinity) return stop;
    }
    for (final stop in stopsAtRect) {
      if (stop.position == position) return stop;
    }
    if (stopsAtRect.isNotEmpty) {
      // A position inside folded content has no visual identity of its own.
      // Normalize to the visible document edge selected by affinity.
      return affinity == HomericCaretAffinity.upstream
          ? stopsAtRect
              .reduce((a, b) => a.position.value <= b.position.value ? a : b)
          : stopsAtRect
              .reduce((a, b) => a.position.value >= b.position.value ? a : b);
    }
    // Defensive fallback for engine geometry that does not report a glyph
    // edge exactly: choose the closest known stop to the computed caret.
    return _visualCaretStops.reduce((best, candidate) {
      final bestDistance = _rectDistanceSquared(best.rect, rect);
      final candidateDistance = _rectDistanceSquared(candidate.rect, rect);
      return candidateDistance < bestDistance ? candidate : best;
    });
  }

  late final List<List<_VisualCaretStop>> _visualCaretLines = () {
    final lines = <List<_VisualCaretStop>>[];
    for (final stop in _visualCaretStops) {
      if (lines.isEmpty || lines.last.first.rect.top != stop.rect.top) {
        lines.add([stop]);
      } else {
        lines.last.add(stop);
      }
    }
    return lines;
  }();

  late final List<_VisualCaretStop> _visualCaretStops = () {
    if (_paragraph.numberOfLines == 0) {
      return <_VisualCaretStop>[
        _VisualCaretStop(
          position: DocOffset.zero,
          affinity: HomericCaretAffinity.downstream,
          rect: _emptyBlockCaretRect(),
        ),
      ];
    }

    final boundaries = <int>{0, _viewText.length};
    var offset = 0;
    while (offset < _viewText.length) {
      if (_viewText.codeUnitAt(offset) == 0xFFFC) {
        // SkParagraph can report a collapsed (0, 0) glyph range for a
        // placeholder. Its U+FFFC view unit still has two real visual edges.
        boundaries
          ..add(offset)
          ..add(offset + 1);
      }
      final info = _paragraph.getGlyphInfoAt(offset);
      if (info == null) {
        offset++;
        continue;
      }
      final range = info.graphemeClusterCodeUnitRange;
      boundaries
        ..add(range.start)
        ..add(range.end);
      offset = range.end > offset ? range.end : offset + 1;
    }

    final stops = <_VisualCaretStop>[];
    final stopIndexByVisualKey = <(int, Rect), int>{};
    for (final view in boundaries.toList()..sort()) {
      for (final assoc in const [-1, 1]) {
        final doc = _viewMap.viewToDoc(view, assoc: assoc);
        if (doc < 0 || doc > docLength) continue;
        if (_viewMap.docToView(doc, assoc: assoc) != view) continue;
        final candidate = _VisualCaretStop(
          position: DocOffset(doc),
          affinity: _affinityFor(assoc),
          rect: _caretRectForView(view, assoc),
        );
        final key = (candidate.position.value, candidate.rect);
        final duplicate = stopIndexByVisualKey[key];
        if (duplicate == null) {
          stopIndexByVisualKey[key] = stops.length;
          stops.add(candidate);
        } else if (candidate.affinity == HomericCaretAffinity.downstream) {
          // At an unambiguous stop either affinity paints identically.
          // Prefer downstream, Flutter's conventional collapsed-caret value.
          stops[duplicate] = candidate;
        }
      }
    }
    // A slot can share its canonical anchor with a folded span. The composed
    // ViewMap then cannot represent all three visible edges on its one assoc
    // bit, but ParagraphSource still has the authoritative measured slot
    // position. Expose the aggregate before/after slot stops explicitly.
    final slotAnchors =
        _render.source.slots.map((slot) => slot.decoration.start).toSet();
    stops.removeWhere((stop) => slotAnchors.contains(stop.position.value));
    for (final doc in slotAnchors) {
      final slots = _render.source.slots
          .where((slot) => slot.decoration.start == doc)
          .toList(growable: false);
      final first = slots.first;
      final last = slots.last;
      stops.add(_VisualCaretStop(
        position: DocOffset(doc),
        affinity: HomericCaretAffinity.upstream,
        rect: _caretRectForView(first.viewStart, -1),
      ));
      stops.add(_VisualCaretStop(
        position: DocOffset(doc),
        affinity: HomericCaretAffinity.downstream,
        rect: _caretRectForView(last.viewEnd, 1),
      ));
    }
    stops.sort((a, b) {
      final byTop = a.rect.top.compareTo(b.rect.top);
      if (byTop != 0) return byTop;
      final byX = a.rect.left.compareTo(b.rect.left);
      if (byX != 0) return byX;
      final byDoc = a.position.value.compareTo(b.position.value);
      if (byDoc != 0) return byDoc;
      return a.affinity.index.compareTo(b.affinity.index);
    });
    return stops;
  }();

  static int _assocFor(HomericCaretAffinity affinity) =>
      affinity == HomericCaretAffinity.upstream ? -1 : 1;

  static HomericCaretAffinity _affinityFor(int assoc) => assoc < 0
      ? HomericCaretAffinity.upstream
      : HomericCaretAffinity.downstream;

  static double _rectDistanceSquared(Rect a, Rect b) {
    final dx = a.left - b.left;
    final dy = a.top - b.top;
    return dx * dx + dy * dy;
  }

  // --- Word / line boundary -------------------------------------------------

  /// The document range of the word at document offset [doc] (UAX#29 word
  /// boundaries, computed over **view text** and mapped back).
  ///
  /// Word analysis runs over what is on screen, not the document: a hidden
  /// delimiter run strictly inside a view-text word is part of that word's
  /// mapped document range (there is no view content on either side of it
  /// to break the word there), even though the delimiter itself is
  /// invisible. This view-space-word semantics is intentional (documented
  /// residual, not a bug) — Nexus features that need document-word
  /// boundaries insensitive to decoration should be built on document text
  /// directly, not this query.
  GeometryResult<DocRange> wordBoundaryAt(DocOffset doc, {int assoc = 1}) {
    _checkOffset(doc);
    final view = _viewMap.docToView(doc.value, assoc: assoc);
    final position = ui.TextPosition(
        offset: view,
        affinity:
            assoc < 0 ? ui.TextAffinity.upstream : ui.TextAffinity.downstream);
    final range = _paragraph.getWordBoundary(position);
    return _stamp(_docRangeOf(range.start, range.end));
  }

  /// The document range of the line at document offset [doc].
  ///
  /// [assoc] is threaded as the query's `TextAffinity` as well as the
  /// `ViewMap` fold association — deliberately the same value for both
  /// (see the library doc comment): a document offset that maps to a view
  /// offset sitting exactly at a wrap point needs exactly one more bit to
  /// disambiate "end of this line" from "start of the next", and the
  /// caller's `assoc` (upstream = stay on the content before the position,
  /// downstream = move to the content after) is precisely that bit. This
  /// is `dart:ui`'s own `Paragraph.getLineBoundary`, which already
  /// resolves the affinity correctly for a given view `TextPosition` — no
  /// extra patching was needed after threading `assoc` through as
  /// `TextAffinity` (see `geometry_test.dart`'s wrap-boundary-affinity
  /// test, written first per the plan's risk note).
  GeometryResult<DocRange> lineBoundaryAt(DocOffset doc, {int assoc = 1}) {
    _checkOffset(doc);
    final view = _viewMap.docToView(doc.value, assoc: assoc);
    final position = ui.TextPosition(
        offset: view,
        affinity:
            assoc < 0 ? ui.TextAffinity.upstream : ui.TextAffinity.downstream);
    final range = _paragraph.getLineBoundary(position);
    return _stamp(_docRangeOf(range.start, range.end));
  }
}

/// One caret's geometric anchor: an x-coordinate and a vertical span.
final class _CaretMetrics {
  const _CaretMetrics(
      {required this.x, required this.top, required this.bottom});

  final double x;
  final double top;
  final double bottom;
}

final class _VisualCaretStop {
  const _VisualCaretStop({
    required this.position,
    required this.affinity,
    required this.rect,
  });

  final DocOffset position;
  final HomericCaretAffinity affinity;
  final Rect rect;
}
