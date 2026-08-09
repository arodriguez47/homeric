// Position-mapping semantics ported from prosemirror-transform src/map.ts
// @ 662b7a937bafde19b7e2a83241dbc8888e257c89; MIT (c) Marijn Haverbeke.
// The upstream source was read to learn the semantics; this implementation
// is original Dart and no source code was copied.

import 'dart:collection';

/// Thrown when a [StepMap] is constructed from a malformed range list.
final class MalformedStepMapError extends Error {
  MalformedStepMapError(this.message);

  /// Describes what is wrong with the range list.
  final String message;

  @override
  String toString() => 'MalformedStepMapError: $message';
}

/// Thrown when a position outside the mappable range (a negative position)
/// is passed to a mapping operation.
final class PositionRangeError extends Error {
  PositionRangeError(this.position);

  /// The offending position.
  final int position;

  @override
  String toString() => 'PositionRangeError: position $position is out of range';
}

/// Something positions can be mapped through.
abstract interface class Mappable {
  /// Maps [pos] through this object. [assoc] (1 or -1, default 1) determines
  /// which side the position associates with: when content is inserted at
  /// the mapped position, it decides whether the position moves after
  /// (1) or stays before (-1) the insertion.
  int map(int pos, {int assoc});

  /// Like [map], but returns a [MapResult] carrying deletion information
  /// about the mapping.
  MapResult mapResult(int pos, {int assoc});
}

// Deletion-info bit flags.
const int _delBefore = 1;
const int _delAfter = 2;
const int _delAcross = 4;
const int _delSide = 8;

// Recover values pack a range index (lower 16 bits) and an offset into that
// range (remaining bits) into one integer. Multiplication and integer
// division are used instead of bit shifts on purpose: shifts clip to 32 bits
// under dart2js, while 64-bit floats represent 48-bit integers exactly.
const int _factor16 = 0x10000;

int _makeRecover(int index, int offset) => index + offset * _factor16;
int _recoverIndex(int value) => value % _factor16;
int _recoverOffset(int value) => value ~/ _factor16;

/// A mapped position together with information about how the mapping
/// affected it.
final class MapResult {
  /// Creates a result. Normally produced by [StepMap.mapResult] rather than
  /// constructed directly.
  const MapResult(this.pos, this.delInfo, this.recoverValue);

  /// The mapped position.
  final int pos;

  /// Raw deletion-info bit flags. Prefer the boolean getters.
  final int delInfo;

  /// When the position was inside a replaced range, a packed value that a
  /// mirror-image [StepMap] can pass to [StepMap.recover] to restore the
  /// exact offset. Null when the position sat at the kept edge of the range.
  final int? recoverValue;

  /// Whether the token on the queried side (per `assoc`) was deleted, which
  /// makes the position itself count as deleted.
  bool get deleted => delInfo & _delSide != 0;

  /// Whether the token before the position was deleted.
  bool get deletedBefore => delInfo & (_delBefore | _delAcross) != 0;

  /// Whether the token after the position was deleted.
  bool get deletedAfter => delInfo & (_delAfter | _delAcross) != 0;

  /// Whether the deletion covered both sides of the position — the signal
  /// that anchors at this position lost their surrounding content.
  bool get deletedAcross => delInfo & _delAcross != 0;
}

/// A map describing the deletions and insertions made by a step: an
/// immutable list of `[start, oldSize, newSize]` triples, sorted and
/// non-overlapping, expressed in pre-step (old document) coordinates.
final class StepMap implements Mappable {
  /// Creates a position map from `[start, oldSize, newSize]` triples.
  ///
  /// Throws [MalformedStepMapError] when the list length is not a multiple
  /// of three, contains negative values, or has unsorted or overlapping
  /// ranges.
  StepMap(List<int> ranges)
      : this._(UnmodifiableListView(List.of(_checkRanges(ranges))), false);

  const StepMap._(this.ranges, this.inverted);

  /// A StepMap that contains no changed ranges.
  static const StepMap empty = StepMap._([], false);

  /// Creates a map that moves every position by [n] (possibly negative).
  factory StepMap.offset(int n) {
    if (n == 0) return empty;
    return StepMap(n < 0 ? [0, -n, 0] : [0, 0, n]);
  }

  /// The `[start, oldSize, newSize]` triples, flattened.
  final List<int> ranges;

  /// Whether this map runs backwards (post-step to pre-step coordinates).
  final bool inverted;

  static List<int> _checkRanges(List<int> ranges) {
    if (ranges.length % 3 != 0) {
      throw MalformedStepMapError(
          'range list length (${ranges.length}) must be a multiple of 3');
    }
    for (var i = 0; i < ranges.length; i += 3) {
      final start = ranges[i];
      final oldSize = ranges[i + 1];
      final newSize = ranges[i + 2];
      if (start < 0 || oldSize < 0 || newSize < 0) {
        throw MalformedStepMapError(
            'negative value in triple [$start, $oldSize, $newSize]');
      }
      if (i > 0 && start < ranges[i - 3] + ranges[i - 2]) {
        throw MalformedStepMapError('ranges must be sorted and non-overlapping '
            '(range at index ${i ~/ 3} starts at $start, before the previous '
            'range ends at ${ranges[i - 3] + ranges[i - 2]})');
      }
    }
    return ranges;
  }

  static void _checkPosition(int pos) {
    if (pos < 0) throw PositionRangeError(pos);
  }

  int get _oldSizeIndex => inverted ? 2 : 1;
  int get _newSizeIndex => inverted ? 1 : 2;

  @override
  int map(int pos, {int assoc = 1}) => mapResult(pos, assoc: assoc).pos;

  @override
  MapResult mapResult(int pos, {int assoc = 1}) {
    _checkPosition(pos);
    var diff = 0;
    for (var i = 0; i < ranges.length; i += 3) {
      final start = ranges[i] - (inverted ? diff : 0);
      if (start > pos) break;
      final oldSize = ranges[i + _oldSizeIndex];
      final newSize = ranges[i + _newSizeIndex];
      final end = start + oldSize;
      if (pos <= end) {
        final side = _side(pos, start, end, oldSize, assoc);
        final mapped = start + diff + (side < 0 ? 0 : newSize);
        final keptEdge = assoc < 0 ? start : end;
        final recoverValue =
            pos == keptEdge ? null : _makeRecover(i ~/ 3, pos - start);
        var delInfo = pos == start
            ? _delAfter
            : pos == end
                ? _delBefore
                : _delAcross;
        if (assoc < 0 ? pos != start : pos != end) delInfo |= _delSide;
        return MapResult(mapped, delInfo, recoverValue);
      }
      diff += newSize - oldSize;
    }
    return MapResult(pos + diff, 0, null);
  }

  static int _side(int pos, int start, int end, int oldSize, int assoc) {
    if (oldSize == 0) return assoc;
    if (pos == start) return -1;
    if (pos == end) return 1;
    return assoc;
  }

  /// Turns a recover value produced against this map's mirror image back
  /// into a position in this map's output coordinates, restoring the exact
  /// offset into the replaced range.
  int recover(int value) {
    if (value < 0) {
      throw ArgumentError.value(value, 'value', 'recover value is negative');
    }
    final index = _recoverIndex(value);
    if (index * 3 >= ranges.length) {
      throw ArgumentError.value(
          value, 'value', 'range index $index does not exist in this map');
    }
    var diff = 0;
    if (!inverted) {
      for (var i = 0; i < index; i++) {
        diff += ranges[i * 3 + 2] - ranges[i * 3 + 1];
      }
    }
    return ranges[index * 3] + diff + _recoverOffset(value);
  }

  /// Calls [f] for each changed range, with its extent in old and new
  /// document coordinates.
  void forEach(
      void Function(int oldStart, int oldEnd, int newStart, int newEnd) f) {
    var diff = 0;
    for (var i = 0; i < ranges.length; i += 3) {
      final start = ranges[i];
      final oldStart = start - (inverted ? diff : 0);
      final newStart = start + (inverted ? 0 : diff);
      final oldSize = ranges[i + _oldSizeIndex];
      final newSize = ranges[i + _newSizeIndex];
      f(oldStart, oldStart + oldSize, newStart, newStart + newSize);
      diff += newSize - oldSize;
    }
  }

  /// Creates an inverted version of this map, mapping positions in the
  /// post-step document back to the pre-step document. Shares the same
  /// range list.
  StepMap invert() => StepMap._(ranges, !inverted);

  @override
  String toString() => '${inverted ? '-' : ''}$ranges';
}
