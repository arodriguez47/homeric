/// To-do lines: `[ ] task`, `- [x] done`, `☐ task`.
library;

/// Reading and ticking to-do lines.
abstract final class HomericChecklists {
  /// A to-do line: a box glyph (`☐ ☑ □ ■ ✓ ✔`), `[ ]`/`[x]`, or a list
  /// marker before one, then a space and the words (group 3). Groups 1
  /// and 2 hold what is inside a bracket.
  static final RegExp line = RegExp(
    r'^\s*(?:[☐☑□■✓✔]|\[([ xX✓])?\]|[-*]\s*\[([ xX✓])?\])\s+(.*)$',
  );

  /// Whether a [line] match on [text] is ticked: a filled bracket, or a
  /// done glyph (☑ ■ ✓ ✔) in place of a bracket.
  static bool isDone(String text, RegExpMatch match) {
    final mark = (match.group(1) ?? match.group(2) ?? '').trim();
    if (mark.isNotEmpty) return true;
    final trimmed = text.trimLeft();
    return trimmed.isNotEmpty &&
        const {'☑', '■', '✓', '✔'}.contains(trimmed[0]);
  }

  /// [marker] ticked or unticked: `[ ]` ↔ `[x]`, `☐` ↔ `☑`. Null when it
  /// is not a to-do marker.
  static String? toggled(String marker) {
    final box = RegExp(r'\[([ xX✓])?\]').firstMatch(marker);
    if (box != null) {
      final ticked = (box.group(1) ?? '').trim().isNotEmpty;
      return marker.replaceRange(box.start, box.end, ticked ? '[ ]' : '[x]');
    }
    const glyphs = {
      '☐': '☑',
      '□': '■',
      '☑': '☐',
      '■': '□',
      '✓': '☐',
      '✔': '☐',
    };
    final glyph = glyphs[marker.trim()];
    return glyph == null ? null : marker.replaceFirst(marker.trim(), glyph);
  }
}
