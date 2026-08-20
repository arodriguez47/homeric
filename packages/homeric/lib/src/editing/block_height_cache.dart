/// Measured natural-height index for a virtualized Homeric document.
library;

import 'dart:math' as math;

/// Immutable authority token for one row measurement.
final class BlockHeightWitness {
  const BlockHeightWitness._({
    required this.blockId,
    required this.documentRevision,
    required this.layoutSignature,
    required this.generation,
  });

  final String blockId;
  final int documentRevision;
  final Object? layoutSignature;
  final int generation;
}

/// Accepted height delta at [index].
final class BlockHeightChange {
  const BlockHeightChange({required this.index, required this.delta});

  final int index;
  final double delta;

  @override
  bool operator ==(Object other) =>
      other is BlockHeightChange &&
      index == other.index &&
      delta == other.delta;

  @override
  int get hashCode => Object.hash(index, delta);
}

/// Stores measured heights without constraining children to estimates.
///
/// Unknown or invalidated rows contribute [estimatedHeight] to prefix queries.
/// Point updates and offset queries use a Fenwick tree; structural order
/// replacement is the only linear rebuild.
final class BlockHeightCache {
  BlockHeightCache({
    required this.estimatedHeight,
    this.measurementTolerance = 0.5,
  })  : assert(estimatedHeight > 0),
        assert(measurementTolerance >= 0);

  final double estimatedHeight;
  final double measurementTolerance;

  List<String> _order = const <String>[];
  Map<String, int> _indices = const <String, int>{};
  final Map<String, double> _heights = <String, double>{};
  final Map<String, BlockHeightWitness> _witnesses =
      <String, BlockHeightWitness>{};
  List<double> _tree = const <double>[];
  int _nextGeneration = 0;

  int get length => _order.length;
  int get retainedEntryCount => _heights.length;

  double? heightFor(String blockId) => _heights[blockId];

  /// Returns the current stable-order index for [blockId], if retained.
  int? indexOf(String blockId) => _indices[blockId];

  void replaceOrder(List<String> blockIds) {
    final retained = blockIds.toSet();
    _heights.removeWhere((blockId, _) => !retained.contains(blockId));
    _witnesses.removeWhere((blockId, _) => !retained.contains(blockId));
    _order = List<String>.unmodifiable(blockIds);
    _indices = <String, int>{
      for (var index = 0; index < blockIds.length; index++)
        blockIds[index]: index,
    };
    _tree = List<double>.filled(blockIds.length + 1, 0);
    for (var index = 0; index < blockIds.length; index++) {
      _add(index, _heightAt(index));
    }
  }

  void invalidateAll() {
    _heights.clear();
    _witnesses.clear();
    _tree = List<double>.filled(_order.length + 1, 0);
    for (var index = 0; index < _order.length; index++) {
      _add(index, estimatedHeight);
    }
  }

  BlockHeightWitness prepareMeasurement({
    required String blockId,
    required int documentRevision,
    required Object? layoutSignature,
  }) {
    final previous = _witnesses[blockId];
    if (previous != null && previous.layoutSignature != layoutSignature) {
      final index = _indices[blockId];
      final oldHeight = _heights.remove(blockId);
      if (index != null && oldHeight != null) {
        _add(index, estimatedHeight - oldHeight);
      }
    }
    final witness = BlockHeightWitness._(
      blockId: blockId,
      documentRevision: documentRevision,
      layoutSignature: layoutSignature,
      generation: ++_nextGeneration,
    );
    _witnesses[blockId] = witness;
    return witness;
  }

  BlockHeightChange? record(BlockHeightWitness witness, double height) {
    final index = _indices[witness.blockId];
    if (index == null ||
        !identical(_witnesses[witness.blockId], witness) ||
        !height.isFinite ||
        height < 0) {
      return null;
    }
    final previous = _heights[witness.blockId] ?? estimatedHeight;
    final delta = height - previous;
    if (delta.abs() <= measurementTolerance) return null;
    _heights[witness.blockId] = height;
    _add(index, delta);
    return BlockHeightChange(index: index, delta: delta);
  }

  double offsetBefore(int index) {
    final clamped = index.clamp(0, _order.length);
    var cursor = clamped;
    var total = 0.0;
    while (cursor > 0) {
      total += _tree[cursor];
      cursor -= cursor & -cursor;
    }
    return total;
  }

  int? indexAtOffset(double offset) {
    if (_order.isEmpty) return null;
    final target = math.max(0.0, offset);
    var low = 0;
    var high = _order.length - 1;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (offsetBefore(middle + 1) > target) {
        high = middle;
      } else {
        low = middle + 1;
      }
    }
    return low;
  }

  double _heightAt(int index) => _heights[_order[index]] ?? estimatedHeight;

  void _add(int index, double delta) {
    var cursor = index + 1;
    while (cursor < _tree.length) {
      _tree[cursor] += delta;
      cursor += cursor & -cursor;
    }
  }
}
