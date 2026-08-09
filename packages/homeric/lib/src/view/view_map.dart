/// Bidirectional offset mapping between a block's document text and its
/// derived view text.
///
/// A [ViewMap] is [StepMap]'s `[start, oldLen, newLen]` triple machinery
/// (see `../transform/step_map.dart` for the ProseMirror provenance of
/// that math — it is reused here, not reimplemented) applied to view-text
/// folding: every span a `replace` decoration substitutes and every
/// `widget` placeholder slot is one triple, expressed in block-local
/// document content offsets.
library;

import '../transform/step_map.dart';

/// A bidirectional map between a block's document content offsets
/// (`0..contentLength`) and its view text offsets (`0..viewText.length`).
///
/// Positions strictly inside a replaced span have no view-text identity of
/// their own: [docToView] maps them to the visible **edge chosen by the
/// caller's `assoc`** — `-1` for the view position before the replacement
/// content, `1` for the position after it. This is the "no phantom caret
/// slots" guarantee: the caret can only land on visible positions, and the
/// caller (not the map) chooses the edge — no "nearest edge" behavior is
/// promised. [viewToDoc] is the exact inverse map, with the same edge
/// semantics for positions inside replacement content.
///
/// Round-trip law: `viewToDoc(docToView(p)) == p` for every position `p`
/// outside replaced spans (see [checkViewMapRoundTrip]).
final class ViewMap {
  /// Creates a map from `[start, oldLen, newLen]` triples in block-local
  /// document coordinates: each triple says the document span
  /// `[start, start + oldLen)` became `newLen` units of view text.
  ///
  /// Throws [MalformedStepMapError] on malformed triples (see [StepMap]).
  ViewMap(List<int> triples) : _forward = StepMap(List<int>.of(triples));

  ViewMap._(this._forward);

  /// The identity map: view text equals document text.
  static final ViewMap identity = ViewMap._(StepMap.empty);

  final StepMap _forward;
  late final StepMap _inverse = _forward.invert();

  /// The `[start, oldLen, newLen]` triples backing this map, flattened
  /// (unmodifiable, in block-local document coordinates).
  List<int> get triples => _forward.ranges;

  /// Whether this map changes nothing (no folded spans).
  bool get isIdentity => triples.isEmpty;

  /// Maps a document content offset to a view text offset.
  ///
  /// For positions strictly inside a replaced span, [assoc] chooses the
  /// visible edge: `-1` maps to the view position before the replacement
  /// content, `1` (the default) to the position after it. Positions
  /// exactly at a replaced span's boundaries map to the matching edge
  /// regardless of [assoc].
  int docToView(int pos, {int assoc = 1}) => _forward.map(pos, assoc: assoc);

  /// Maps a view text offset back to a document content offset.
  ///
  /// The exact inverse of [docToView]: for positions strictly inside
  /// replacement content, [assoc] chooses which edge of the replaced
  /// document span to land on (`-1` start, `1` end).
  int viewToDoc(int pos, {int assoc = 1}) => _inverse.map(pos, assoc: assoc);

  /// Whether document offset [docPos] lies strictly inside a replaced span
  /// — i.e. has no view-text identity of its own, so the round-trip law
  /// does not apply to it.
  bool isInsideReplacedSpan(int docPos) {
    final ranges = triples;
    for (var i = 0; i < ranges.length; i += 3) {
      final start = ranges[i];
      if (start >= docPos) return false;
      if (docPos < start + ranges[i + 1]) return true;
    }
    return false;
  }

  /// Two maps are equal when they carry identical triples.
  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    if (other is! ViewMap) return false;
    final a = triples;
    final b = other.triples;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(triples);

  @override
  String toString() => 'ViewMap($triples)';
}

/// Asserts the round-trip law on [map] for a block of [docLength] content
/// units: for every position `p` in `[0, docLength]` outside replaced
/// spans, `viewToDoc(docToView(p, assoc), assoc) == p`.
///
/// "Outside replaced spans" is per `(position, assoc)` pair, exactly as in
/// ProseMirror's `deleted` criterion: a pair is skipped when the content
/// on the assoc side of the position was folded away — which covers every
/// position strictly inside a replaced span (both assocs) and, at a span's
/// exact boundary, only the assoc looking into the span. Every surviving
/// pair must round-trip exactly.
///
/// Throws [StateError] naming the first violating position. Reusable by
/// the property/fuzz harness (U7) as-is.
void checkViewMapRoundTrip(ViewMap map, int docLength) {
  if (docLength < 0) {
    throw ArgumentError.value(docLength, 'docLength', 'must not be negative');
  }
  for (var pos = 0; pos <= docLength; pos++) {
    for (final assoc in const [-1, 1]) {
      if (map._forward.mapResult(pos, assoc: assoc).deleted) continue;
      final view = map.docToView(pos, assoc: assoc);
      final back = map.viewToDoc(view, assoc: assoc);
      if (back != pos) {
        throw StateError(
            'ViewMap round-trip violated at doc position $pos (assoc '
            '$assoc): docToView -> $view, viewToDoc -> $back ($map)');
      }
    }
  }
}
