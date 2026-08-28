/// Journal-facing markdown list indent: nest/outdent via leading whitespace
/// before a bullet (`- `/`* `) or ordered (`1. `) marker.
///
/// Homeric stores literal source. Nesting is a block-prefix rewrite (two
/// spaces per level), not a structural outliner and not a literal tab insert.
final class HomericMarkdownListIndent {
  HomericMarkdownListIndent._();

  /// One nest level: two ASCII spaces (CommonMark-friendly).
  static const unit = '  ';

  static final RegExp _listItem = RegExp(r'^([ \t]*)([-*] |\d+\. )');

  /// Whether [text] is a single-line markdown list item (optional indent).
  static bool isListItem(String text) => _listItem.hasMatch(text);

  /// Prefix edit that nests [text] one level, or `null` if not a list item.
  static HomericMarkdownListIndentEdit? nest(String text) {
    if (!_listItem.hasMatch(text)) return null;
    return const HomericMarkdownListIndentEdit(
      start: 0,
      end: 0,
      replacement: unit,
      caretDelta: unit.length,
    );
  }

  /// Prefix edit that outdents [text] one level, or `null` if not indented.
  static HomericMarkdownListIndentEdit? outdent(String text) {
    final match = _listItem.firstMatch(text);
    if (match == null) return null;
    final indent = match.group(1)!;
    if (indent.isEmpty) return null;
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
