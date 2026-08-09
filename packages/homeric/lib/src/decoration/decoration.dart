/// Non-destructive range overlays anchored to blocks.
///
/// Decoration design provenance: the three-kind vocabulary (inline /
/// replace / widget), block-local anchoring, and mapping semantics follow
/// prosemirror-view's decoration layer (`src/decoration.ts`,
/// https://github.com/ProseMirror/prosemirror-view, MIT; repository
/// archived April 2026). Design reference only — no source code was
/// copied. Per-end inclusivity (instead of one global bias) is the
/// documented defense against the ProseMirror issue #849 bug class.
library;

/// What a [Decoration] does to the range it covers.
///
/// The kinds are the geometry contract only — every presentation decision
/// (how a restyle looks, what a replacement renders as, which widget gets
/// measured into a slot) lives in the consumer's opaque [Decoration.spec].
enum DecorationKind {
  /// Restyles the covered range without changing its length.
  inline,

  /// Substitutes the covered range with view text of a different length —
  /// possibly zero, which is how a hidden delimiter hides.
  replace,

  /// A zero-length point occupying one placeholder slot for a measured
  /// child.
  widget,
}

/// A non-destructive overlay anchored to a block-local content range.
///
/// A decoration never touches the document: it references a block by its
/// stable id and a `[start, end)` range of **local content offsets**
/// (`0..contentLength`) within that block. [spec] is an opaque consumer
/// payload — the library attaches no meaning to it and carries no
/// presentation fields (margin note vs popover is the consumer's call).
///
/// Per-end inclusivity controls how the range reacts to an insertion at an
/// exact boundary: text inserted exactly at [start] joins the range iff
/// [inclusiveStart]; text inserted exactly at [end] joins iff
/// [inclusiveEnd].
final class Decoration {
  Decoration._({
    required this.kind,
    required this.blockId,
    required this.start,
    required this.end,
    required this.inclusiveStart,
    required this.inclusiveEnd,
    required this.replacementLength,
    required this.spec,
  }) {
    if (start < 0) {
      throw ArgumentError.value(start, 'start', 'must not be negative');
    }
    if (end < start) {
      throw ArgumentError.value(end, 'end', 'must not precede start ($start)');
    }
    if (kind == DecorationKind.widget && end != start) {
      throw ArgumentError.value(
          end, 'end', 'a widget decoration is a zero-length point');
    }
    final replacement = replacementLength;
    if (replacement != null && replacement < 0) {
      throw ArgumentError.value(
          replacement, 'replacementLength', 'must not be negative');
    }
  }

  /// An [DecorationKind.inline] decoration restyling `[start, end)` of
  /// block [blockId]'s content.
  Decoration.inline(
    String blockId,
    int start,
    int end, {
    bool inclusiveStart = false,
    bool inclusiveEnd = false,
    Object? spec,
  }) : this._(
          kind: DecorationKind.inline,
          blockId: blockId,
          start: start,
          end: end,
          inclusiveStart: inclusiveStart,
          inclusiveEnd: inclusiveEnd,
          replacementLength: null,
          spec: spec,
        );

  /// A [DecorationKind.replace] decoration substituting `[start, end)` of
  /// block [blockId]'s content with view text of [replacementLength] units
  /// (zero hides the range entirely).
  Decoration.replace(
    String blockId,
    int start,
    int end, {
    required int replacementLength,
    bool inclusiveStart = false,
    bool inclusiveEnd = false,
    Object? spec,
  }) : this._(
          kind: DecorationKind.replace,
          blockId: blockId,
          start: start,
          end: end,
          inclusiveStart: inclusiveStart,
          inclusiveEnd: inclusiveEnd,
          replacementLength: replacementLength,
          spec: spec,
        );

  /// A [DecorationKind.widget] decoration: a zero-length point at content
  /// [offset] of block [blockId], occupying one placeholder slot.
  ///
  /// A zero-length slot maps by [inclusiveEnd] alone: an insertion exactly
  /// at the slot pushes the slot after the inserted content iff
  /// [inclusiveEnd] is true. There is no `inclusiveStart` knob — it could
  /// never affect a zero-length point ([Decoration.inclusiveStart] is
  /// always false for widgets).
  Decoration.widget(
    String blockId,
    int offset, {
    bool inclusiveEnd = false,
    Object? spec,
  }) : this._(
          kind: DecorationKind.widget,
          blockId: blockId,
          start: offset,
          end: offset,
          inclusiveStart: false,
          inclusiveEnd: inclusiveEnd,
          replacementLength: null,
          spec: spec,
        );

  /// What this decoration does to its range.
  final DecorationKind kind;

  /// The stable id of the block the range lives in.
  final String blockId;

  /// Start of the range, as a content offset in `[0, contentLength]`.
  final int start;

  /// End of the range, as a content offset in `[start, contentLength]`.
  /// Equal to [start] for [DecorationKind.widget].
  final int end;

  /// Whether text inserted exactly at [start] joins the range.
  final bool inclusiveStart;

  /// Whether text inserted exactly at [end] joins the range.
  final bool inclusiveEnd;

  /// For [DecorationKind.replace]: how many view-text units the covered
  /// range becomes (`0..n`); `null` for the other kinds.
  ///
  /// This is geometry-neutral information for view-text derivation only.
  /// The replacement content itself lives in [spec] under whatever
  /// contract the consumer and the view layer define; the library never
  /// reads it.
  final int? replacementLength;

  /// Opaque consumer payload. The library never inspects it; mapping
  /// carries it by reference, so it doubles as the decoration's stable
  /// identity (e.g. a widget's slot identity).
  final Object? spec;

  /// Whether the range is zero-length.
  bool get isCollapsed => start == end;

  /// The range's length in content characters.
  int get length => end - start;

  /// Returns a decoration with the anchor fields replaced — used by
  /// `DecorationSet.map` to re-anchor a mapped decoration. [kind],
  /// inclusivity, [replacementLength], and [spec] are always carried
  /// unchanged.
  Decoration copyWith({String? blockId, int? start, int? end}) => Decoration._(
        kind: kind,
        blockId: blockId ?? this.blockId,
        start: start ?? this.start,
        end: end ?? this.end,
        inclusiveStart: inclusiveStart,
        inclusiveEnd: inclusiveEnd,
        replacementLength: replacementLength,
        spec: spec,
      );

  /// Decorations are equal when every anchor field matches and they carry
  /// the **same** [spec] instance — the payload is opaque, so identity is
  /// the only comparison the library can make.
  @override
  bool operator ==(Object other) =>
      other is Decoration &&
      other.kind == kind &&
      other.blockId == blockId &&
      other.start == start &&
      other.end == end &&
      other.inclusiveStart == inclusiveStart &&
      other.inclusiveEnd == inclusiveEnd &&
      other.replacementLength == replacementLength &&
      identical(other.spec, spec);

  @override
  int get hashCode => Object.hash(kind, blockId, start, end, inclusiveStart,
      inclusiveEnd, replacementLength, identityHashCode(spec));

  @override
  String toString() => 'Decoration.${kind.name}($blockId [$start, $end)'
      '${inclusiveStart ? ', inclusiveStart' : ''}'
      '${inclusiveEnd ? ', inclusiveEnd' : ''}'
      '${replacementLength == null ? '' : ', replacementLength: '
          '$replacementLength'})';
}
