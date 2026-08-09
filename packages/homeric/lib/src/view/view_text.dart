/// View text derivation: document text + decorations → per-block view
/// text with a bidirectional offset map.
///
/// This is the primitive that makes hidden delimiters real (a `replace`
/// decoration folds them out of the view text, rather than rendering them
/// at `fontSize: 0`) and Phase 2's "view text ≠ document text" possible.
///
/// Derivation is a pure per-block function: the same block and decorations
/// always produce identical output, and a later edit only requires
/// re-deriving the blocks its `ChangeList` reports as touched.
library;

import '../decoration/decoration.dart';
import '../model/block.dart';
import 'view_map.dart';

/// The placeholder character a `widget` decoration injects into view text:
/// U+FFFC OBJECT REPLACEMENT CHARACTER.
///
/// A widget slot is always **exactly one** view-text unit long. (This pins
/// the slot-length contract; Phase 2 measures the real child into the
/// slot's geometry.)
const String objectReplacementCharacter = '￼';

/// The payload contract for `replace` decorations with a non-zero
/// [Decoration.replacementLength]: their [Decoration.spec] must implement
/// this interface, and [text] must be exactly `replacementLength` units
/// long — [deriveViewText] validates both and throws [ArgumentError] on a
/// consumer bug.
///
/// Replace decorations with `replacementLength == 0` fold their range to
/// nothing; their spec is never inspected (it stays fully opaque and may
/// carry anything, e.g. the hidden delimiter text for reveal-on-focus).
abstract interface class ReplacementContent {
  /// The view text substituted for the decorated range.
  String get text;
}

/// A styled span of view text contributed by an `inline` decoration:
/// `[start, end)` in **view coordinates**, carrying the source decoration
/// (and through it the consumer's opaque spec).
///
/// Styled ranges may overlap freely — resolving overlaps is the
/// consumer/renderer's job.
final class StyledRange {
  /// Creates a styled range.
  const StyledRange(this.start, this.end, this.decoration);

  /// Start of the range, as a view text offset.
  final int start;

  /// End of the range (exclusive), as a view text offset.
  final int end;

  /// The `inline` decoration that produced this range.
  final Decoration decoration;

  @override
  bool operator ==(Object other) =>
      other is StyledRange &&
      other.start == start &&
      other.end == end &&
      other.decoration == decoration;

  @override
  int get hashCode => Object.hash(start, end, decoration);

  @override
  String toString() => 'StyledRange([$start, $end), $decoration)';
}

/// One widget placeholder slot in view text: the view offset of its
/// [objectReplacementCharacter] and the `widget` decoration whose spec is
/// the slot's stable identity.
final class ViewSlot {
  /// Creates a slot record.
  const ViewSlot(this.viewOffset, this.decoration);

  /// View text offset of the slot's placeholder character.
  final int viewOffset;

  /// The `widget` decoration occupying this slot.
  final Decoration decoration;

  @override
  bool operator ==(Object other) =>
      other is ViewSlot &&
      other.viewOffset == viewOffset &&
      other.decoration == decoration;

  @override
  int get hashCode => Object.hash(viewOffset, decoration);

  @override
  String toString() => 'ViewSlot(@$viewOffset, $decoration)';
}

/// The result of [deriveViewText] for one block.
final class DerivedViewText {
  const DerivedViewText._(
      this.viewText, this.styledRanges, this.slots, this.viewMap);

  /// The block's view text: document text with replaced spans substituted
  /// and widget slots injected.
  final String viewText;

  /// Styled spans contributed by `inline` decorations, in view
  /// coordinates, ordered by start then end (unmodifiable). Ranges that
  /// fold to nothing (entirely inside a hidden span, or zero-length) are
  /// omitted.
  final List<StyledRange> styledRanges;

  /// Widget placeholder slots in view-offset order (unmodifiable).
  final List<ViewSlot> slots;

  /// The bidirectional offset map between document content offsets and
  /// [viewText] offsets.
  final ViewMap viewMap;

  @override
  String toString() => 'DerivedViewText(${Error.safeToString(viewText)}, '
      '${styledRanges.length} styled, ${slots.length} slots, $viewMap)';
}

/// Derives [block]'s view text from [decorations] (typically
/// `DecorationSet.forBlock(block.id)`).
///
/// Folding semantics, per decoration kind:
///
/// - `replace` substitutes its range with replacement content of
///   [Decoration.replacementLength] view units (see [ReplacementContent];
///   zero length hides the range entirely). Replace decorations must not
///   overlap one another — overlap is a consumer bug and throws
///   [ArgumentError] naming the block and both ranges. Adjacent ranges
///   (one ending where the next starts) are fine.
/// - `widget` injects exactly one [objectReplacementCharacter] slot at its
///   offset. Slots at the same offset appear in the order the decorations
///   were given (insertion order — the deterministic tiebreak). A widget
///   exactly at a replaced span's start precedes the replacement content;
///   one exactly at its end follows it; one **strictly inside** a replaced
///   span is hidden along with the span (no slot, reported nowhere — it
///   still exists as a decoration and reappears if the replace is
///   removed).
/// - `inline` passes text through unchanged and contributes a
///   [StyledRange] in view coordinates, clipped to visible text: its start
///   maps with `assoc: 1` and its end with `assoc: -1`, so hidden spans at
///   the edges are excluded (and replacement content or slots strictly
///   inside the range stay covered). Inline ranges may overlap freely.
///
/// Throws [ArgumentError] when a decoration belongs to a different block,
/// lies outside `[0, contentLength]`, or violates the replace contracts
/// above. Derivation is pure and deterministic: identical inputs produce
/// identical outputs.
DerivedViewText deriveViewText(Block block, Iterable<Decoration> decorations) {
  final contentLength = block.contentLength;
  final inlines = <Decoration>[];
  final replaces = <Decoration>[];
  final widgets = <Decoration>[];
  for (final decoration in decorations) {
    if (decoration.blockId != block.id) {
      throw ArgumentError.value(
          decoration,
          'decorations',
          'decoration is anchored to block "${decoration.blockId}", '
              'not "${block.id}"');
    }
    if (decoration.end > contentLength) {
      throw ArgumentError.value(
          decoration,
          'decorations',
          'range [${decoration.start}, ${decoration.end}) exceeds block '
              '"${block.id}" content length $contentLength');
    }
    switch (decoration.kind) {
      case DecorationKind.inline:
        inlines.add(decoration);
      case DecorationKind.replace:
        replaces.add(decoration);
      case DecorationKind.widget:
        widgets.add(decoration);
    }
  }
  _stableSortByStart(replaces);
  _stableSortByStart(widgets);
  for (var i = 1; i < replaces.length; i++) {
    if (replaces[i].start < replaces[i - 1].end) {
      throw ArgumentError('replace decorations overlap in block "${block.id}": '
          '[${replaces[i - 1].start}, ${replaces[i - 1].end}) and '
          '[${replaces[i].start}, ${replaces[i].end})');
    }
  }

  final text = block.text;
  final buffer = StringBuffer();
  final triples = <int>[];
  final slots = <ViewSlot>[];
  var docPos = 0;

  void addTriple(int start, int oldLen, int newLen) {
    if (oldLen == 0 && newLen == 0) return;
    // Canonicalize: a folded span with no view content starting exactly
    // where the previous folded span ends is absorbed into it. Otherwise
    // the two spans would share one view position and the inverse map
    // could not tell their edges apart, breaking the round-trip law at
    // the seam (the seam itself becomes span-interior, mapping to the
    // assoc-chosen visible edge like any other folded position).
    if (triples.isNotEmpty &&
        newLen == 0 &&
        triples[triples.length - 3] + triples[triples.length - 2] == start) {
      triples[triples.length - 2] += oldLen;
      return;
    }
    triples.addAll([start, oldLen, newLen]);
  }

  void emitTextUpTo(int end) {
    if (end > docPos) {
      buffer.write(text.substring(docPos, end));
      docPos = end;
    }
  }

  void emitWidget(Decoration widget) {
    slots.add(ViewSlot(buffer.length, widget));
    addTriple(widget.start, 0, 1);
    buffer.write(objectReplacementCharacter);
  }

  var wi = 0;
  for (final replace in replaces) {
    while (wi < widgets.length && widgets[wi].start <= replace.start) {
      emitTextUpTo(widgets[wi].start);
      emitWidget(widgets[wi]);
      wi++;
    }
    emitTextUpTo(replace.start);
    final replacement = _replacementTextFor(block, replace);
    addTriple(replace.start, replace.length, replacement.length);
    buffer.write(replacement);
    docPos = replace.end;
    // Widgets strictly inside the replaced span are hidden with it.
    while (wi < widgets.length && widgets[wi].start < replace.end) {
      wi++;
    }
  }
  while (wi < widgets.length) {
    emitTextUpTo(widgets[wi].start);
    emitWidget(widgets[wi]);
    wi++;
  }
  emitTextUpTo(contentLength);

  final viewMap = triples.isEmpty ? ViewMap.identity : ViewMap(triples);
  final styled = <StyledRange>[];
  for (final inline in inlines) {
    final start = viewMap.docToView(inline.start, assoc: 1);
    final end = viewMap.docToView(inline.end, assoc: -1);
    if (end > start) styled.add(StyledRange(start, end, inline));
  }
  _stableSortStyled(styled);

  return DerivedViewText._(
    buffer.toString(),
    List<StyledRange>.unmodifiable(styled),
    List<ViewSlot>.unmodifiable(slots),
    viewMap,
  );
}

/// Resolves the replacement view text for a `replace` decoration,
/// validating the [ReplacementContent] payload contract.
String _replacementTextFor(Block block, Decoration decoration) {
  final length = decoration.replacementLength!;
  if (length == 0) return '';
  final spec = decoration.spec;
  if (spec is! ReplacementContent) {
    throw ArgumentError(
        'replace decoration [${decoration.start}, ${decoration.end}) in '
        'block "${block.id}" has replacementLength $length but its spec '
        '(${spec.runtimeType}) does not implement ReplacementContent');
  }
  final text = spec.text;
  if (text.length != length) {
    throw ArgumentError(
        'replace decoration [${decoration.start}, ${decoration.end}) in '
        'block "${block.id}" declares replacementLength $length but its '
        'ReplacementContent text has length ${text.length} '
        '(${Error.safeToString(text)})');
  }
  return text;
}

/// Sorts [decorations] by `start` while preserving the given order among
/// equal starts (Dart's `List.sort` is not stable).
void _stableSortByStart(List<Decoration> decorations) {
  final order = List<int>.generate(decorations.length, (i) => i)
    ..sort((x, y) {
      final byStart = decorations[x].start.compareTo(decorations[y].start);
      if (byStart != 0) return byStart;
      return x.compareTo(y);
    });
  final sorted = [for (final i in order) decorations[i]];
  decorations.setAll(0, sorted);
}

/// Sorts [ranges] by `start` then `end`, preserving the given order among
/// ties.
void _stableSortStyled(List<StyledRange> ranges) {
  final order = List<int>.generate(ranges.length, (i) => i)
    ..sort((x, y) {
      final byStart = ranges[x].start.compareTo(ranges[y].start);
      if (byStart != 0) return byStart;
      final byEnd = ranges[x].end.compareTo(ranges[y].end);
      if (byEnd != 0) return byEnd;
      return x.compareTo(y);
    });
  final sorted = [for (final i in order) ranges[i]];
  ranges.setAll(0, sorted);
}
