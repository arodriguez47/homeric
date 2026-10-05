/// Mount-stable margin placement.
///
/// [solveMarginLayout] places whatever blocks it is given, but a margin layer
/// only ever sees the blocks the editor has mounted. A group's form depends
/// on the next annotated block and its position on the cascade from the
/// previous one, so a fresh solve per frame would let a note that stays on
/// screen change form or jump when an off-screen neighbour mounts or
/// unmounts. [MarginLayoutMemory] remembers the last placements and re-solves
/// only what an edit actually changed. Like the solver it is pure Dart and
/// makes every placement decision from numbers alone.
library;

import 'margin_layout_solver.dart';

/// Pixels two block offsets may differ by and still count as unchanged.
const double _kTolerance = 1e-3;

/// Solves margin placements across frames so that mounting and unmounting
/// never moves a note that stays mounted.
///
/// The rule, applied on every [solve]:
///
/// * A block is **kept** when it was in the previous solve, its notes are
///   unchanged (ids, block-relative anchors, range starts, heights) and it
///   moved by the same amount as the first such block, which is what
///   scrolling does to every block. A kept block that lost a neighbour it
///   had in the previous solve, or gained one between it and the previous
///   kept block, is not kept.
/// * Kept blocks reuse their previous placements, translated with them.
/// * Blocks after the last kept block that were not there before, which is
///   what mounting below the viewport looks like, are solved below the kept
///   ones, starting at the last kept note's bottom plus the gap. They never
///   reopen a kept block, so a newly mounted neighbour cannot compact a group
///   already on screen.
/// * Blocks before the first kept block, which is what mounting above the
///   viewport looks like, are solved with the first kept note as their
///   limit. If even their compact previews would run into it, keeping the
///   lower placements is impossible without an overlap, and everything is
///   solved fresh.
/// * Any other change, such as an edited anchor, a resized note, or a block
///   that moved relative to the others, reopens the kept block just before
///   it, since that block's form depends on the next anchor, and solves from
///   there to the end.
///
/// Unmounting needs no rule: a block that left the input because it
/// unmounted simply leaves the remaining placements as they were. A block
/// that left for any other reason, such as losing its last note or being
/// deleted, is a change to the block after it. [solve]'s `isUnmounted`
/// tells the two apart.
///
/// Placements therefore depend on the order in which blocks were seen, not
/// only on the current input. That is the point: what is on screen stays
/// put until the writer changes something.
final class MarginLayoutMemory {
  List<_Retained>? _previous;
  _Parameters? _parameters;

  /// Forgets every previous placement; the next [solve] starts fresh.
  void reset() {
    _previous = null;
    _parameters = null;
  }

  /// Places [blocks], which must be in document order, reusing previous
  /// placements per the class rules. Other arguments mean what they mean
  /// for [solveMarginLayout] and are validated the same way.
  ///
  /// [isUnmounted] answers, for a previously placed block missing from
  /// [blocks], whether it is missing only because it is not mounted. It
  /// defaults to treating every missing block that way.
  List<MarginNotePlacement> solve(
    List<MarginBlockInput> blocks, {
    required double lineHeight,
    double gap = kMarginNoteGap,
    double maxShiftLines = kMarginMaxShiftLines,
    double maxFullLines = kMarginMaxFullLines,
    bool Function(String blockId)? isUnmounted,
  }) {
    final parameters =
        _Parameters(lineHeight, gap, maxShiftLines, maxFullLines);
    // Validates the parameters even when nothing needs solving.
    parameters.solve(const <MarginBlockInput>[]);
    final current = <_Current>[
      for (final block in blocks)
        if (_Current.from(block) case final group?) group,
    ];
    final previous = _previous;
    final placements = (previous != null && parameters == _parameters
            ? _incremental(current, previous, parameters, isUnmounted)
            : null) ??
        parameters.solve([for (final group in current) group.block]);
    _remember(current, placements, parameters);
    return placements;
  }

  List<MarginNotePlacement>? _incremental(
    List<_Current> current,
    List<_Retained> previous,
    _Parameters parameters,
    bool Function(String blockId)? isUnmounted,
  ) {
    final previousIndex = <String, int>{
      for (var index = 0; index < previous.length; index++)
        previous[index].blockId: index,
    };
    final currentIds = <String>{
      for (final group in current) group.block.blockId,
    };
    final status = List<_Status>.filled(current.length, _Status.added);
    double? shift;
    for (var index = 0; index < current.length; index++) {
      final group = current[index];
      final before = previousIndex[group.block.blockId];
      if (before == null) continue;
      final retained = previous[before];
      if (!_sameNotes(group.notes, retained.notes)) {
        status[index] = _Status.changed;
        continue;
      }
      final moved = group.block.top - retained.top;
      shift ??= moved;
      status[index] =
          (moved - shift).abs() <= _kTolerance ? _Status.kept : _Status.changed;
    }
    // A block that vanished while still mounted changes the next block
    // that was placed after it.
    for (var index = 0; index < previous.length; index++) {
      final blockId = previous[index].blockId;
      if (currentIds.contains(blockId) ||
          (isUnmounted?.call(blockId) ?? true)) {
        continue;
      }
      for (var next = 0; next < current.length; next++) {
        final after = previousIndex[current[next].block.blockId];
        if (after != null && after > index) {
          status[next] = _Status.changed;
          break;
        }
      }
    }
    // A kept block whose previous neighbour differs had something removed
    // or inserted between them, which changes its cascade.
    int? lastKept;
    for (var index = 0; index < current.length; index++) {
      if (status[index] != _Status.kept) continue;
      if (lastKept != null &&
          (index != lastKept + 1 ||
              previousIndex[current[index].block.blockId] !=
                  previousIndex[current[lastKept].block.blockId]! + 1)) {
        status[index] = _Status.changed;
        continue;
      }
      lastKept = index;
    }

    final first = status.indexOf(_Status.kept);
    // Only newly mounted blocks may precede the kept ones; an edited block
    // there changes the cascade into them.
    if (first < 0 || status.take(first).contains(_Status.changed)) {
      return null;
    }
    var end = first;
    while (end < current.length && status[end] == _Status.kept) {
      end++;
    }
    var reuseEnd = end;
    if (end < current.length) {
      // Newly mounted blocks only ever follow the kept ones. Anything else
      // after them is an edit, which can change the last kept block's form.
      final reopen = status[end] == _Status.changed ||
          status.skip(end + 1).any((value) => value != _Status.added);
      if (reopen) reuseEnd = end - 1;
    }
    if (reuseEnd <= first) return null;

    final reused = <MarginNotePlacement>[
      for (var index = first; index < reuseEnd; index++)
        ...previous[previousIndex[current[index].block.blockId]!]
            .placementsAt(current[index].block.top),
    ];
    final head = first == 0
        ? const <MarginNotePlacement>[]
        : parameters.solve(
            [for (final group in current.take(first)) group.block],
            trailingAnchor: _min(
              reused.first.anchorTop,
              reused.first.top - parameters.gap,
            ),
          );
    if (head.isNotEmpty &&
        head.last.bottom > reused.first.top - parameters.gap + _kTolerance) {
      return null;
    }
    final tail = reuseEnd == current.length
        ? const <MarginNotePlacement>[]
        : parameters.solve(
            [for (final group in current.skip(reuseEnd)) group.block],
            floor: reused.last.bottom + parameters.gap,
          );
    return <MarginNotePlacement>[...head, ...reused, ...tail];
  }

  void _remember(
    List<_Current> current,
    List<MarginNotePlacement> placements,
    _Parameters parameters,
  ) {
    final byBlock = <String, List<MarginNotePlacement>>{};
    for (final placement in placements) {
      (byBlock[placement.blockId] ??= <MarginNotePlacement>[]).add(placement);
    }
    _previous = <_Retained>[
      for (final group in current)
        _Retained(
          blockId: group.block.blockId,
          top: group.block.top,
          notes: group.notes,
          placements: byBlock[group.block.blockId] ?? const [],
        ),
    ];
    _parameters = parameters;
  }
}

enum _Status { kept, changed, added }

double _min(double a, double b) => a < b ? a : b;

final class _Parameters {
  const _Parameters(
    this.lineHeight,
    this.gap,
    this.maxShiftLines,
    this.maxFullLines,
  );

  final double lineHeight;
  final double gap;
  final double maxShiftLines;
  final double maxFullLines;

  List<MarginNotePlacement> solve(
    List<MarginBlockInput> blocks, {
    double floor = double.negativeInfinity,
    double trailingAnchor = double.infinity,
  }) =>
      solveMarginLayout(
        blocks,
        lineHeight: lineHeight,
        gap: gap,
        maxShiftLines: maxShiftLines,
        maxFullLines: maxFullLines,
        floor: floor,
        trailingAnchor: trailingAnchor,
      );

  @override
  bool operator ==(Object other) =>
      other is _Parameters &&
      other.lineHeight == lineHeight &&
      other.gap == gap &&
      other.maxShiftLines == maxShiftLines &&
      other.maxFullLines == maxFullLines;

  @override
  int get hashCode => Object.hash(lineHeight, gap, maxShiftLines, maxFullLines);
}

/// One note's placement-relevant inputs, relative to its block.
final class _NoteKey {
  const _NoteKey(
      this.id, this.anchor, this.rangeStart, this.full, this.compact);

  final String id;
  final double anchor;
  final int rangeStart;
  final double full;
  final double compact;

  bool matches(_NoteKey other) =>
      other.id == id &&
      other.rangeStart == rangeStart &&
      (other.anchor - anchor).abs() <= _kTolerance &&
      (other.full - full).abs() <= _kTolerance &&
      (other.compact - compact).abs() <= _kTolerance;
}

bool _sameNotes(List<_NoteKey> a, List<_NoteKey> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (!a[index].matches(b[index])) return false;
  }
  return true;
}

final class _Current {
  const _Current(this.block, this.notes);

  /// The block reduced to the notes the solver would keep, or `null` when it
  /// would keep none.
  static _Current? from(MarginBlockInput block) {
    if (!block.top.isFinite) return null;
    final notes = <MarginNoteInput>[
      for (final note in block.notes)
        if (note.anchorTop.isFinite &&
            note.fullHeight.isFinite &&
            note.compactHeight.isFinite)
          note,
    ];
    if (notes.isEmpty) return null;
    final keys = <_NoteKey>[
      for (final note in notes)
        _NoteKey(note.id, note.anchorTop - block.top, note.rangeStart,
            note.fullHeight, note.compactHeight),
    ]..sort((left, right) => left.id.compareTo(right.id));
    return _Current(
      MarginBlockInput(blockId: block.blockId, top: block.top, notes: notes),
      keys,
    );
  }

  final MarginBlockInput block;
  final List<_NoteKey> notes;
}

final class _Retained {
  const _Retained({
    required this.blockId,
    required this.top,
    required this.notes,
    required this.placements,
  });

  final String blockId;
  final double top;
  final List<_NoteKey> notes;
  final List<MarginNotePlacement> placements;

  /// The retained placements for a block whose top is now [blockTop].
  Iterable<MarginNotePlacement> placementsAt(double blockTop) => placements.map(
        (placement) => MarginNotePlacement(
          id: placement.id,
          blockId: placement.blockId,
          form: placement.form,
          top: blockTop + placement.blockRelativeTop,
          blockRelativeTop: placement.blockRelativeTop,
          height: placement.height,
          anchorTop: blockTop + (placement.anchorTop - top),
        ),
      );
}
