/// The playground's own opaque decoration payload.
///
/// Homeric's [Decoration.spec] is deliberately opaque — the library never
/// inspects it (see `decoration.dart`'s library doc). This is the
/// playground's consumer-side vocabulary for that payload: which kind of
/// demo behavior a decoration represents. It carries no Flutter/`dart:ui`
/// types (no [Color], no [TextStyle]) so it stays usable from the
/// Flutter-free [DocumentViewModel] — the views layer maps [kind] to
/// concrete paint values (see `views/editor_page.dart`), keeping "what a
/// decoration means" (here) separate from "how it looks" (the view).
library;

import 'package:homeric/homeric.dart';

/// What a playground decoration demonstrates.
enum PlaygroundDecorationKind {
  /// Baked-in fixture styling: `**bold**` content renders bold.
  bold,

  /// Baked-in fixture styling: `%%italic%%` content renders italic.
  italic,

  /// A mention/annotation background wash (U5 underlay paint layer demo).
  mentionWash,

  /// An annotation underline (U5 overlay paint layer demo).
  annotation,

  /// A hidden markdown-style delimiter (`**`/`%%`), toggled by the
  /// decoration panel's "hide delimiters" control (R10 demo surface).
  hideMarker,

  /// A widget-chip placeholder slot.
  chip,
}

/// The playground's [Decoration.spec] payload.
class PlaygroundSpec {
  /// Creates a spec of [kind], with an optional display [label] (used by
  /// [chip] specs for the chip's text).
  const PlaygroundSpec(this.kind, {this.label});

  /// A chip spec displaying [label].
  PlaygroundSpec.chip(String label)
      : this(PlaygroundDecorationKind.chip, label: label);

  /// What this decoration demonstrates.
  final PlaygroundDecorationKind kind;

  /// Display label, meaningful for [PlaygroundDecorationKind.chip].
  final String? label;

  @override
  String toString() =>
      'PlaygroundSpec(${kind.name}${label == null ? '' : ', $label'})';
}

/// The canonical spec shared by every hide-delimiter decoration.
///
/// A `replace` decoration with `replacementLength: 0` never has its spec
/// inspected by Homeric (its range simply folds to nothing), so every
/// hide-marker decoration in the document can safely share this one
/// instance; [DocumentViewModel.toggleHideDelimiters] finds them again by
/// [PlaygroundSpec.kind], not by this identity.
const PlaygroundSpec hideMarkerSpec =
    PlaygroundSpec(PlaygroundDecorationKind.hideMarker);

/// Scans [block]'s current text for `**bold**` and `%%hidden%%` style
/// markers and returns a pair of zero-width `replace` decorations per
/// marker (the opening and closing delimiter, each hidden independently) —
/// the "apply hide-delimiter decorations" half of the R10 demo.
///
/// Pure and re-derivable from the block's live text: callers do not need to
/// track these decorations across edits themselves (though once added to a
/// [DecorationSet] they *do* survive edits like any other decoration, via
/// [DecorationSet.map] — see [DocumentViewModel.toggleHideDelimiters]'s doc).
List<Decoration> markerDecorationsFor(Block block) {
  final text = block.text;
  final result = <Decoration>[];
  void scan(RegExp marker, int markerLength) {
    for (final match in marker.allMatches(text)) {
      result
        ..add(Decoration.replace(
          block.id,
          match.start,
          match.start + markerLength,
          replacementLength: 0,
          spec: hideMarkerSpec,
        ))
        ..add(Decoration.replace(
          block.id,
          match.end - markerLength,
          match.end,
          replacementLength: 0,
          spec: hideMarkerSpec,
        ));
    }
  }

  scan(RegExp(r'\*\*(.+?)\*\*'), 2);
  scan(RegExp(r'%%(.+?)%%'), 2);
  return result;
}
