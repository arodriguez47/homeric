/// Directional canonical document selections.
library;

import '../transform/step_map.dart';

/// Which visual side of an ambiguous caret stop the active head occupies.
///
/// This is deliberately independent of Flutter's `TextAffinity`: Homeric's
/// model stays Flutter-free and geometry translates at the rendering edge.
enum HomericCaretAffinity { upstream, downstream }

/// A directional selection in global canonical document coordinates.
///
/// [anchor] is fixed while a selection is extended; [head] is the active
/// caret. Use [start] and [end] only for range mutations, never to reconstruct
/// direction.
final class HomericSelection {
  /// Creates a directional selection.
  const HomericSelection({
    required this.anchor,
    required this.head,
    this.affinity = HomericCaretAffinity.downstream,
  })  : assert(anchor >= 0),
        assert(head >= 0);

  /// Creates a collapsed selection at [position].
  const HomericSelection.collapsed(
    int position, {
    this.affinity = HomericCaretAffinity.downstream,
  })  : anchor = position,
        head = position,
        assert(position >= 0);

  /// The fixed end of the selection.
  final int anchor;

  /// The active end of the selection.
  final int head;

  /// The active head's visual affinity.
  final HomericCaretAffinity affinity;

  /// Whether no canonical content is selected.
  bool get isCollapsed => anchor == head;

  /// Whether the head is at or after the anchor.
  bool get isForward => head >= anchor;

  /// The normalized range start.
  int get start => anchor < head ? anchor : head;

  /// The normalized range end.
  int get end => anchor > head ? anchor : head;

  /// Returns a copy with selected fields replaced.
  HomericSelection copyWith({
    int? anchor,
    int? head,
    HomericCaretAffinity? affinity,
  }) =>
      HomericSelection(
        anchor: anchor ?? this.anchor,
        head: head ?? this.head,
        affinity: affinity ?? this.affinity,
      );

  /// Maps both ends through [mapping] without normalizing away direction.
  ///
  /// A collapsed caret follows inserted content. Expanded endpoints stay
  /// attached to the selected content: the normalized start associates
  /// forward and the normalized end associates backward.
  HomericSelection map(Mappable mapping) {
    if (isCollapsed) {
      return HomericSelection.collapsed(
        mapping.map(head, assoc: 1),
        affinity: affinity,
      );
    }
    final anchorAssoc = anchor == start ? 1 : -1;
    final headAssoc = head == start ? 1 : -1;
    return HomericSelection(
      anchor: mapping.map(anchor, assoc: anchorAssoc),
      head: mapping.map(head, assoc: headAssoc),
      affinity: affinity,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HomericSelection &&
      anchor == other.anchor &&
      head == other.head &&
      affinity == other.affinity;

  @override
  int get hashCode => Object.hash(anchor, head, affinity);

  @override
  String toString() =>
      'HomericSelection(anchor: $anchor, head: $head, affinity: $affinity)';
}

/// A normalized range in global canonical document coordinates.
final class HomericTextRange {
  /// Creates `[start, end)`.
  HomericTextRange(this.start, this.end) {
    if (start < 0 || end < start) {
      throw ArgumentError('invalid text range [$start, $end)');
    }
  }

  /// The inclusive start.
  final int start;

  /// The exclusive end.
  final int end;

  /// Whether the range is empty.
  bool get isCollapsed => start == end;

  /// Maps the range while retaining normalized endpoint association.
  HomericTextRange map(Mappable mapping) {
    if (isCollapsed) {
      final position = mapping.map(start, assoc: 1);
      return HomericTextRange(position, position);
    }
    final mappedStart = mapping.map(start, assoc: 1);
    final mappedEnd = mapping.map(end, assoc: -1);
    return HomericTextRange(
      mappedStart < mappedEnd ? mappedStart : mappedEnd,
      mappedStart < mappedEnd ? mappedEnd : mappedStart,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HomericTextRange && start == other.start && end == other.end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'HomericTextRange($start, $end)';
}
