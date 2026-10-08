/// Host-facing snapshot of the current directional selection.
library;

import '../model/selection.dart';

/// One block-local span covered by a [HomericSelectionSnapshot].
final class HomericBlockSpan {
  /// Creates a span over `[start, end)` of [blockId]'s content.
  const HomericBlockSpan({
    required this.blockId,
    required this.start,
    required this.end,
  })  : assert(start >= 0),
        assert(end >= start);

  /// Stable identity of the spanned block.
  final String blockId;

  /// Inclusive local content start offset.
  final int start;

  /// Exclusive local content end offset.
  final int end;

  /// Whether the span covers no characters.
  bool get isEmpty => start == end;

  @override
  bool operator ==(Object other) =>
      other is HomericBlockSpan &&
      other.blockId == blockId &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(blockId, start, end);

  @override
  String toString() => 'HomericBlockSpan($blockId, [$start, $end))';
}

/// Plain-text and per-block span projection of a directional selection.
///
/// Used by hosts that promote the current selection into another document
/// (e.g. "selection → note") without waiting on a listener tick.
final class HomericSelectionSnapshot {
  /// Creates a snapshot over [plainText] and [spans].
  const HomericSelectionSnapshot({
    required this.plainText,
    required this.spans,
    this.selection,
  });

  /// Empty snapshot used for a collapsed or inactive selection.
  static const empty = HomericSelectionSnapshot(
    plainText: '',
    spans: <HomericBlockSpan>[],
  );

  /// Concatenated selected plain text with `\n` between blocks.
  final String plainText;

  /// Ordered per-block content spans covered by the selection.
  final List<HomericBlockSpan> spans;

  /// Canonical selection that produced this snapshot, when known.
  final HomericSelection? selection;

  /// Whether no characters are selected.
  bool get isEmpty => plainText.isEmpty && spans.every((span) => span.isEmpty);

  @override
  bool operator ==(Object other) =>
      other is HomericSelectionSnapshot &&
      other.plainText == plainText &&
      other.selection == selection &&
      _listEquals(other.spans, spans);

  @override
  int get hashCode => Object.hash(plainText, selection, Object.hashAll(spans));

  @override
  String toString() => 'HomericSelectionSnapshot(${spans.length} spans, '
      '${Error.safeToString(plainText)})';

  static bool _listEquals(List<HomericBlockSpan> a, List<HomericBlockSpan> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
