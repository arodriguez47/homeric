/// ParagraphSource: the pure bridge from Phase 1's view-text derivation
/// to `ParagraphBuilder`-ready inputs.
///
/// [ParagraphSource.build] takes a block, its decorations, a
/// [RevealState] (which `replace` decorations are suppressed this
/// derivation, R10), a per-build style resolver (R7), and block-level
/// paragraph inputs, and produces an ordered list of segments — text runs
/// with resolved style handles and widget slot descriptors — plus the
/// [ViewMap], ready for a builder loop of `pushStyle`/`addText`/
/// `addPlaceholder` (R1).
///
/// This layer is deliberately free of `dart:ui`: style handles are opaque
/// generics (`S`) and block-level inputs are carried as data, so the
/// bridge is a pure, deterministic function unit-testable without
/// bindings. The render object (U2) maps handles to `ui.TextStyle` and
/// spec fields to `ui.ParagraphStyle`.
library;

import '../decoration/decoration.dart';
import '../model/block.dart';
import '../view/view_map.dart';
import '../view/view_text.dart';

/// Which `replace` decorations are suppressed ("revealed") for one
/// derivation — the mechanism behind reveal-on-selection (R10).
///
/// A revealed replace decoration is excluded from the derivation call, so
/// the document text it would fold away shows instead; everything else is
/// unchanged. Reveal state only ever affects [DecorationKind.replace]
/// decorations — membership of any other kind is ignored.
final class RevealState {
  const RevealState._(this._revealed);

  /// Reveals exactly [revealed]: each member (compared by [Decoration]'s
  /// own equality — anchor fields plus spec identity) is suppressed from
  /// the derivation.
  RevealState.of(Iterable<Decoration> revealed)
      : _revealed = Set<Decoration>.unmodifiable(revealed);

  /// Nothing revealed: every replace decoration folds as usual.
  static const RevealState none = RevealState._(null);

  final Set<Decoration>? _revealed;

  /// Whether this state reveals no decoration at all.
  bool get revealsNothing {
    final revealed = _revealed;
    return revealed == null || revealed.isEmpty;
  }

  /// Whether [decoration] is suppressed this derivation.
  bool isRevealed(Decoration decoration) =>
      _revealed?.contains(decoration) ?? false;

  @override
  String toString() => revealsNothing
      ? 'RevealState.none'
      : 'RevealState(${_revealed!.length} revealed)';
}

/// Paragraph direction, as pure data (mapped to `ui.TextDirection` by the
/// render object).
enum ParagraphDirection {
  /// Left to right.
  ltr,

  /// Right to left.
  rtl,
}

/// Block-level paragraph inputs, carried through as data (R7): the caller
/// resolves them per build and the render object (U2) maps them onto
/// `ui.ParagraphStyle` / strut / `TextScaler`.
///
/// [strut] and [textScaler] are opaque passthroughs — this layer never
/// inspects them, so they compare by identity (like [Decoration.spec]).
final class BlockParagraphSpec {
  /// Creates a spec; every field has a neutral default.
  const BlockParagraphSpec({
    this.direction = ParagraphDirection.ltr,
    this.lineHeight,
    this.strut,
    this.textScaler,
  });

  /// The paragraph's base direction.
  final ParagraphDirection direction;

  /// Line height multiplier hook (`ui.ParagraphStyle.height`), or `null`
  /// for the font's natural height.
  final double? lineHeight;

  /// Opaque strut configuration passthrough (`null` for no strut).
  final Object? strut;

  /// Opaque `TextScaler` passthrough (`null` for no scaling).
  final Object? textScaler;

  @override
  bool operator ==(Object other) =>
      other is BlockParagraphSpec &&
      other.direction == direction &&
      other.lineHeight == lineHeight &&
      identical(other.strut, strut) &&
      identical(other.textScaler, textScaler);

  @override
  int get hashCode => Object.hash(direction, lineHeight,
      identityHashCode(strut), identityHashCode(textScaler));

  @override
  String toString() => 'BlockParagraphSpec(${direction.name}'
      '${lineHeight == null ? '' : ', height: $lineHeight'}'
      '${strut == null ? '' : ', strut'}'
      '${textScaler == null ? '' : ', scaled'})';
}

/// One style-resolution request: a maximal span of view text over which
/// the set of active `inline` decorations is constant (and which contains
/// no widget slot).
final class RunStyleContext {
  const RunStyleContext._(this.viewStart, this.text, this.decorations);

  /// Start of the run, as a view text offset.
  final int viewStart;

  /// End of the run (exclusive), as a view text offset.
  int get viewEnd => viewStart + text.length;

  /// The run's view text (never empty).
  final String text;

  /// The `inline` decorations covering the whole run, in styled-range
  /// order (unmodifiable; empty for plain text). Their opaque specs are
  /// what the resolver interprets into a style handle.
  final List<Decoration> decorations;

  @override
  String toString() => 'RunStyleContext([$viewStart, $viewEnd) '
      '${Error.safeToString(text)}, ${decorations.length} decorations)';
}

/// Resolves one run's style handle from its active decorations.
///
/// Invoked exactly once per text run **per build** — never cached across
/// builds (R7: the consumer resolves theme/font at call time).
typedef RunStyleResolver<S> = S Function(RunStyleContext run);

/// One element of a [ParagraphSource] builder loop, in view-text order:
/// either a [TextSegment] (`pushStyle` + `addText`) or a [SlotSegment]
/// (`addPlaceholder`).
sealed class ParagraphSegment<S> {
  /// Start of the segment, as a view text offset.
  int get viewStart;

  /// End of the segment (exclusive), as a view text offset.
  int get viewEnd;
}

/// A styled run of view text.
final class TextSegment<S> implements ParagraphSegment<S> {
  const TextSegment._(this.viewStart, this.text, this.style);

  @override
  final int viewStart;

  @override
  int get viewEnd => viewStart + text.length;

  /// The run's view text (never empty).
  final String text;

  /// The resolved style handle for this run.
  final S style;

  @override
  bool operator ==(Object other) =>
      other is TextSegment<S> &&
      other.viewStart == viewStart &&
      other.text == text &&
      other.style == style;

  @override
  int get hashCode => Object.hash(viewStart, text, style);

  @override
  String toString() =>
      'TextSegment(@$viewStart, ${Error.safeToString(text)}, $style)';
}

/// One widget placeholder slot: exactly one [objectReplacementCharacter]
/// code unit of view text (Phase 1's slot-length contract).
final class SlotSegment<S> implements ParagraphSegment<S> {
  const SlotSegment._(this.viewOffset, this.slotIndex, this.decoration);

  /// View text offset of the slot's placeholder character.
  final int viewOffset;

  /// The slot's ordinal among the source's slots — the `addPlaceholder`
  /// call index, and the index into `getBoxesForPlaceholders`.
  final int slotIndex;

  /// The `widget` decoration occupying this slot.
  final Decoration decoration;

  /// The slot's stable identity: the widget decoration's opaque spec.
  Object? get spec => decoration.spec;

  @override
  int get viewStart => viewOffset;

  @override
  int get viewEnd => viewOffset + 1;

  @override
  bool operator ==(Object other) =>
      other is SlotSegment<S> &&
      other.viewOffset == viewOffset &&
      other.slotIndex == slotIndex &&
      other.decoration == decoration;

  @override
  int get hashCode => Object.hash(viewOffset, slotIndex, decoration);

  @override
  String toString() => 'SlotSegment(#$slotIndex @$viewOffset, $decoration)';
}

/// `ParagraphBuilder`-ready inputs for one block: ordered [segments]
/// covering the whole view text, the [slots] among them, the [ViewMap],
/// and the block-level [spec] — a pure, deterministic value derived from
/// `(block, decorations, reveal, resolver, spec)`.
final class ParagraphSource<S> {
  ParagraphSource._(
      this.viewText, this.segments, this.slots, this.viewMap, this.spec);

  /// Derives [block]'s view text (with [reveal]-suppressed replace
  /// decorations excluded, R10) and splits it into builder segments,
  /// resolving each text run's style via [resolveStyle] (exactly once per
  /// run, this call only — R7).
  ///
  /// Run boundaries fall where the set of active `inline` decorations
  /// changes and around every widget slot, so styled ranges clip around
  /// slots. Throws whatever [deriveViewText] throws on contract-violating
  /// decorations.
  factory ParagraphSource.build({
    required Block block,
    required Iterable<Decoration> decorations,
    required RunStyleResolver<S> resolveStyle,
    RevealState reveal = RevealState.none,
    BlockParagraphSpec spec = const BlockParagraphSpec(),
  }) {
    final visible = <Decoration>[
      for (final decoration in decorations)
        if (decoration.kind != DecorationKind.replace ||
            !reveal.isRevealed(decoration))
          decoration,
    ];
    final derived = deriveViewText(block, visible);
    final viewText = derived.viewText;

    final cuts = <int>{0, viewText.length};
    for (final range in derived.styledRanges) {
      cuts.add(range.start);
      cuts.add(range.end);
    }
    for (final slot in derived.slots) {
      cuts.add(slot.viewOffset);
      cuts.add(slot.viewOffset + 1);
    }
    final bounds = cuts.toList()..sort();

    final segments = <ParagraphSegment<S>>[];
    final slots = <SlotSegment<S>>[];
    var nextSlot = 0;
    for (var i = 0; i + 1 < bounds.length; i++) {
      final start = bounds[i];
      final end = bounds[i + 1];
      if (nextSlot < derived.slots.length &&
          derived.slots[nextSlot].viewOffset == start) {
        assert(end == start + 1,
            'a slot is exactly one view unit: [$start, $end)');
        final slot = SlotSegment<S>._(
            start, nextSlot, derived.slots[nextSlot].decoration);
        segments.add(slot);
        slots.add(slot);
        nextSlot++;
        continue;
      }
      final active = List<Decoration>.unmodifiable([
        for (final range in derived.styledRanges)
          if (range.start <= start && end <= range.end) range.decoration,
      ]);
      final text = viewText.substring(start, end);
      final style = resolveStyle(RunStyleContext._(start, text, active));
      segments.add(TextSegment<S>._(start, text, style));
    }
    assert(nextSlot == derived.slots.length,
        'every derived slot must become a SlotSegment');

    return ParagraphSource._(
      viewText,
      List<ParagraphSegment<S>>.unmodifiable(segments),
      List<SlotSegment<S>>.unmodifiable(slots),
      derived.viewMap,
      spec,
    );
  }

  /// The block's view text, exactly as derived.
  final String viewText;

  /// The builder loop, in view-text order (unmodifiable): segments are
  /// contiguous, gap-free, and concatenate to [viewText].
  final List<ParagraphSegment<S>> segments;

  /// The [SlotSegment]s among [segments], in slot-index order
  /// (unmodifiable; same instances).
  final List<SlotSegment<S>> slots;

  /// The bidirectional document↔view offset map for this derivation.
  final ViewMap viewMap;

  /// The block-level paragraph inputs, passed through unchanged.
  final BlockParagraphSpec spec;

  @override
  String toString() => 'ParagraphSource(${Error.safeToString(viewText)}, '
      '${segments.length} segments, ${slots.length} slots, $viewMap, $spec)';
}
