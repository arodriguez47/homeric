/// Attributed inline text runs.
///
/// A block's inline content is an ordered list of [InlineRun]s — the shape of
/// ProseMirror's text nodes with marks (a run of characters sharing one
/// attribute set). A block may hold any number of runs, including zero, empty
/// runs, and adjacent runs with identical attributes; the model never assumes
/// one run per block and never merges runs on its own (normalization is an
/// edit-layer concern).
library;

import 'attributes.dart';

/// An immutable run of text carrying one attribute set.
final class InlineRun {
  /// Creates a run over [text] with a deep-frozen copy of [attributes].
  InlineRun(String text, {Attributes attributes = emptyAttributes})
      : this._(text, freezeAttributes(attributes));

  const InlineRun._(this.text, this.attributes);

  /// The run's text. May be empty.
  final String text;

  /// The run's attribute set (deep-frozen, JSON-compatible).
  final Attributes attributes;

  /// Number of characters in this run (each costs one token position).
  int get length => text.length;

  /// Whether this run contains no text.
  bool get isEmpty => text.isEmpty;

  /// Whether [other] carries a deep-equal attribute set.
  bool hasSameAttributesAs(InlineRun other) =>
      attributesEqual(attributes, other.attributes);

  /// Returns a run with the given fields replaced.
  ///
  /// Untouched fields are shared by reference; in particular, when
  /// [attributes] is omitted the already-frozen bag of this run is reused
  /// without copying.
  InlineRun copyWith({String? text, Attributes? attributes}) {
    return InlineRun._(
      text ?? this.text,
      attributes == null ? this.attributes : freezeAttributes(attributes),
    );
  }

  @override
  String toString() => 'InlineRun(${Error.safeToString(text)}, $attributes)';
}
