/// Journal-facing markdown list lines: tokenize optional leading indent, then
/// nest/outdent via a two-space prefix rewrite.
///
/// Homeric stores literal source. Nesting is not a structural outliner and not
/// a literal tab insert. Hosts match with [HomericMarkdownListPrefix.match]
/// (column-0 *or* indented) before emitting hide / visible-mark decorations.
library;

/// Bullet vs ordered journal list marker.
enum HomericMarkdownListKind {
  /// `- ` or `* ` marker.
  bullet,

  /// `N. ` marker.
  ordered,
}

/// One tokenized journal list line, including nested leading whitespace.
final class HomericMarkdownListMatch {
  /// Creates a match over the leading indent plus marker prefix.
  const HomericMarkdownListMatch({
    required this.indentLength,
    required this.prefixEnd,
    required this.kind,
    this.orderedDigits = '',
  });

  /// Length of leading spaces/tabs before the marker.
  final int indentLength;

  /// Exclusive end of indent + marker (from document offset `0`).
  final int prefixEnd;

  /// Document start of the `- `/`* `/`N. ` marker (after indent).
  int get markerStart => indentLength;

  /// Bullet or ordered.
  final HomericMarkdownListKind kind;

  /// Digits for an ordered marker; empty for bullets.
  final String orderedDigits;

  /// Viewport mark for the HOM-43 [ReplacementContent] host path.
  String get visibleMark =>
      kind == HomericMarkdownListKind.bullet ? '•' : '$orderedDigits.';
}

/// Tokenizes a single-line markdown list item (optional leading indent).
final class HomericMarkdownListPrefix {
  HomericMarkdownListPrefix._();

  static final RegExp _pattern = RegExp(r'^([ \t]*)(?:([-*] )|(\d+)\. )');

  /// Match [text] as a list line, or `null` if it is not one.
  static HomericMarkdownListMatch? match(String text) {
    final matched = _pattern.firstMatch(text);
    if (matched == null) return null;
    final indent = matched.group(1)!;
    final bullet = matched.group(2);
    if (bullet != null) {
      return HomericMarkdownListMatch(
        indentLength: indent.length,
        prefixEnd: matched.end,
        kind: HomericMarkdownListKind.bullet,
      );
    }
    return HomericMarkdownListMatch(
      indentLength: indent.length,
      prefixEnd: matched.end,
      kind: HomericMarkdownListKind.ordered,
      orderedDigits: matched.group(3)!,
    );
  }
}

/// Journal-facing markdown list indent: nest/outdent via leading whitespace
/// before a bullet (`- `/`* `) or ordered (`1. `) marker.
final class HomericMarkdownListIndent {
  HomericMarkdownListIndent._();

  /// One nest level: two ASCII spaces (CommonMark-friendly).
  static const unit = '  ';

  /// Whether [text] is a single-line markdown list item (optional indent).
  static bool isListItem(String text) =>
      HomericMarkdownListPrefix.match(text) != null;

  /// Prefix edit that nests [text] one level, or `null` if not a list item.
  static HomericMarkdownListIndentEdit? nest(String text) {
    if (HomericMarkdownListPrefix.match(text) == null) return null;
    return const HomericMarkdownListIndentEdit(
      start: 0,
      end: 0,
      replacement: unit,
      caretDelta: unit.length,
    );
  }

  /// Prefix edit that outdents [text] one level, or `null` if not indented.
  static HomericMarkdownListIndentEdit? outdent(String text) {
    final match = HomericMarkdownListPrefix.match(text);
    if (match == null || match.indentLength == 0) return null;
    final indent = text.substring(0, match.indentLength);
    final remove = indent.startsWith(unit)
        ? unit.length
        : indent.startsWith('\t')
            ? 1
            : 1;
    return HomericMarkdownListIndentEdit(
      start: 0,
      end: remove,
      replacement: '',
      caretDelta: -remove,
    );
  }
}

/// A block-local prefix rewrite produced by [HomericMarkdownListIndent].
final class HomericMarkdownListIndentEdit {
  /// Creates a UTF-16 range replacement and the caret shift it implies.
  const HomericMarkdownListIndentEdit({
    required this.start,
    required this.end,
    required this.replacement,
    required this.caretDelta,
  });

  /// Inclusive start of the replaced prefix (always `0` today).
  final int start;

  /// Exclusive end of the replaced prefix.
  final int end;

  /// Text inserted at [start].
  final String replacement;

  /// Signed caret adjustment for a caret that sat at or after [end].
  final int caretDelta;
}
