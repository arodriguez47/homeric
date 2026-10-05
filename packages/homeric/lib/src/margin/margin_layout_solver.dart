/// Pure margin-note placement: anchors, measured heights and thresholds in;
/// each note's form, vertical position and connector flag out.
///
/// The solver makes every placement decision for the margin layer and
/// nothing else does: widget code measures notes and positions them where
/// this function says. It imports no Flutter library, so it is exercised
/// with plain numbers.
///
/// Coordinates are a single shared vertical space chosen by the caller
/// (viewport y, scroll-content y, ...): block tops and anchor tops must all
/// be expressed in it, and the solver never needs to know which one it is.
/// Each placement is returned both in that shared space ([MarginNotePlacement.top])
/// and relative to its own block ([MarginNotePlacement.blockRelativeTop]),
/// the latter being what a follower attached to the block consumes.
library;

/// Default vertical gap, in pixels, between consecutive margin notes.
const double kMarginNoteGap = 8;

/// Default number of note line-heights a full note may shift below its
/// anchor before its group turns compact. A shift of exactly this many
/// lines is still allowed.
const double kMarginMaxShiftLines = 2;

/// Default number of note line-heights a note may measure in full form
/// before its group turns compact. A note of exactly this many lines is
/// still allowed.
const double kMarginMaxFullLines = 8;

/// How a margin note is rendered.
enum MarginNoteForm {
  /// The note's complete contents at their measured height.
  full,

  /// A one-line ellipsised preview; the full contents are reachable through
  /// expansion, which is an overlay and does not take part in placement.
  compact,
}

/// One note to place, attached to a range inside its block.
final class MarginNoteInput {
  /// Creates a note input. All vertical values share the caller's
  /// coordinate space.
  const MarginNoteInput({
    required this.id,
    required this.anchorTop,
    required this.rangeStart,
    required this.fullHeight,
    required this.compactHeight,
  });

  /// Host identifier of the note; ties on [anchorTop] and [rangeStart] are
  /// broken by it.
  final String id;

  /// Top of the first line of the note's range. Notes whose anchor is not
  /// finite are dropped.
  final double anchorTop;

  /// Start offset of the note's range, the first tie-break when two notes
  /// share an [anchorTop].
  final int rangeStart;

  /// Measured height of the note in [MarginNoteForm.full].
  final double fullHeight;

  /// Measured height of the note in [MarginNoteForm.compact], typically one
  /// note line-height.
  final double compactHeight;
}

/// One block's notes, in the caller's document order.
final class MarginBlockInput {
  /// Creates a block input.
  const MarginBlockInput({
    required this.blockId,
    required this.top,
    required this.notes,
  });

  /// The source block's id, copied to each of its placements.
  final String blockId;

  /// Top of the block in the shared coordinate space; used only to express
  /// placements relative to the block.
  final double top;

  /// The notes anchored in this block, in any order.
  final List<MarginNoteInput> notes;
}

/// Where and how one note is drawn.
final class MarginNotePlacement {
  /// Creates a placement. Produced by [solveMarginLayout].
  const MarginNotePlacement({
    required this.id,
    required this.blockId,
    required this.form,
    required this.top,
    required this.blockRelativeTop,
    required this.height,
    required this.anchorTop,
  });

  /// The note's [MarginNoteInput.id].
  final String id;

  /// The [MarginBlockInput.blockId] the note belongs to.
  final String blockId;

  /// The form the note is drawn in. Every note of a block shares one form.
  final MarginNoteForm form;

  /// Top of the note in the shared coordinate space.
  final double top;

  /// Top of the note relative to its block's top.
  final double blockRelativeTop;

  /// Height the note occupies: its full or compact height per [form].
  final double height;

  /// The note's anchor, where a connector from a [displaced] note ends.
  final double anchorTop;

  /// Bottom of the note in the shared coordinate space.
  double get bottom => top + height;

  /// Whether the note sits below its anchor and so shows a connector.
  bool get displaced => top > anchorTop;

  @override
  bool operator ==(Object other) =>
      other is MarginNotePlacement &&
      other.id == id &&
      other.blockId == blockId &&
      other.form == form &&
      other.top == top &&
      other.blockRelativeTop == blockRelativeTop &&
      other.height == height &&
      other.anchorTop == anchorTop;

  @override
  int get hashCode =>
      Object.hash(id, blockId, form, top, blockRelativeTop, height, anchorTop);

  @override
  String toString() => 'MarginNotePlacement($id in $blockId, ${form.name}, '
      'top: $top, height: $height, anchor: $anchorTop)';
}

/// Places every note of [blocks], which must be in document order, and
/// returns the placements in that order (notes within a block sorted by
/// anchor top, then range start, then id).
///
/// Groups are solved top to bottom. Within a group each note sits at its
/// anchor or directly below the previous placed note plus [gap], whichever
/// is lower; the previous note may belong to an earlier group, so groups
/// cascade. A group is first tried in full form and turns entirely compact
/// when any of its notes would:
///
/// * shift more than [maxShiftLines] × [lineHeight] below its anchor,
/// * measure more than [maxFullLines] × [lineHeight] in full form, or
/// * end below the first anchor of the next annotated block.
///
/// Compact groups are stacked by the same rule with their compact heights;
/// they are not compacted further, so compact previews that still collide
/// keep stacking downward and push later groups down.
///
/// Notes with a non-finite anchor or height, and notes of a block whose
/// top is not finite, are dropped; negative heights count as zero. Blocks
/// left without notes take no part in placement. Throws [ArgumentError]
/// when [lineHeight] is not finite and positive, or when [gap],
/// [maxShiftLines] or [maxFullLines] is not finite and non-negative.
List<MarginNotePlacement> solveMarginLayout(
  List<MarginBlockInput> blocks, {
  required double lineHeight,
  double gap = kMarginNoteGap,
  double maxShiftLines = kMarginMaxShiftLines,
  double maxFullLines = kMarginMaxFullLines,
}) {
  if (!lineHeight.isFinite || lineHeight <= 0) {
    throw ArgumentError.value(lineHeight, 'lineHeight', 'must be > 0');
  }
  _checkNonNegative(gap, 'gap');
  _checkNonNegative(maxShiftLines, 'maxShiftLines');
  _checkNonNegative(maxFullLines, 'maxFullLines');
  final maxShift = maxShiftLines * lineHeight;
  final maxFullHeight = maxFullLines * lineHeight;

  final groups = <_Group>[];
  for (final block in blocks) {
    if (!block.top.isFinite) continue;
    final notes = [
      for (final note in block.notes)
        if (note.anchorTop.isFinite &&
            note.fullHeight.isFinite &&
            note.compactHeight.isFinite)
          note,
    ]..sort(_compareNotes);
    if (notes.isNotEmpty) groups.add(_Group(block, notes));
  }

  final placements = <MarginNotePlacement>[];
  // Lowest top the next note may take: the previous placement's bottom
  // plus the gap.
  var floor = double.negativeInfinity;
  for (var g = 0; g < groups.length; g++) {
    final group = groups[g];
    final nextAnchor = g + 1 < groups.length
        ? groups[g + 1].notes.first.anchorTop
        : double.infinity;

    var fits = true;
    var cursor = floor;
    for (final note in group.notes) {
      final height = _height(note.fullHeight);
      final top = cursor > note.anchorTop ? cursor : note.anchorTop;
      if (top - note.anchorTop > maxShift ||
          height > maxFullHeight ||
          top + height > nextAnchor) {
        fits = false;
        break;
      }
      cursor = top + height + gap;
    }

    final form = fits ? MarginNoteForm.full : MarginNoteForm.compact;
    for (final note in group.notes) {
      final height = _height(fits ? note.fullHeight : note.compactHeight);
      final top = floor > note.anchorTop ? floor : note.anchorTop;
      placements.add(MarginNotePlacement(
        id: note.id,
        blockId: group.block.blockId,
        form: form,
        top: top,
        blockRelativeTop: top - group.block.top,
        height: height,
        anchorTop: note.anchorTop,
      ));
      floor = top + height + gap;
    }
  }
  return placements;
}

final class _Group {
  _Group(this.block, this.notes);

  final MarginBlockInput block;
  final List<MarginNoteInput> notes;
}

int _compareNotes(MarginNoteInput a, MarginNoteInput b) {
  final byAnchor = a.anchorTop.compareTo(b.anchorTop);
  if (byAnchor != 0) return byAnchor;
  final byRange = a.rangeStart.compareTo(b.rangeStart);
  if (byRange != 0) return byRange;
  return a.id.compareTo(b.id);
}

double _height(double measured) => measured < 0 ? 0 : measured;

void _checkNonNegative(double value, String name) {
  if (!value.isFinite || value < 0) {
    throw ArgumentError.value(value, name, 'must be finite and >= 0');
  }
}
