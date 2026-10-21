/// `[[links]]` between notes: `[[Note title]]`, `[[note-id]]` and
/// `[[target|label]]`.
///
/// Homeric reads the syntax, normalises targets and tracks the `[[` being
/// typed; what a target points at, what its card looks like and what a
/// click does belong to the host, which passes a resolver where one is
/// needed.
library;

import 'package:flutter/foundation.dart' show immutable;

/// One `[[target]]` or `[[target|label]]` span inside a block or body.
@immutable
final class HomericWikiLinkMatch {
  /// Creates a match over `[start, end)`.
  const HomericWikiLinkMatch({
    required this.start,
    required this.end,
    required this.labelStart,
    required this.labelEnd,
    required this.target,
  });

  /// Inclusive start of `[[`.
  final int start;

  /// Exclusive end after `]]`.
  final int end;

  /// Start of the visible label (the target itself when there is no
  /// `|label`).
  final int labelStart;

  /// End of the visible label.
  final int labelEnd;

  /// Raw target text between `[[` and `|` / `]]`.
  final String target;

  /// Whether the link has its own `|label`.
  bool get hasLabel => labelStart != start + 2;

  /// This link's source with [words] as its label: `[[target|words]]`.
  ///
  /// Renaming a link changes only the words a reader sees; the target
  /// stays as written. Blank [words], or words that only repeat the
  /// target, give the plain `[[target]]` back, so the link reads as what
  /// it points at again.
  String withWords(String? words) {
    final clean = words?.replaceAll(RegExp(r'[\[\]|\s]+'), ' ').trim();
    if (clean == null ||
        clean.isEmpty ||
        HomericWikiLinks.key(clean) == HomericWikiLinks.key(target)) {
      return '[[$target]]';
    }
    return '[[$target|$clean]]';
  }
}

/// Reading and writing `[[links]]`.
abstract final class HomericWikiLinks {
  static final RegExp _pattern = RegExp(
    r'\[\[([^\[\]\n|]+)(?:\|([^\[\]\n]+))?\]\]',
  );

  static final RegExp _space = RegExp(r'\s+');

  /// Every link in [text], in order. A blank target is not a link.
  static Iterable<HomericWikiLinkMatch> allMatches(String text) sync* {
    for (final m in _pattern.allMatches(text)) {
      final target = m.group(1)!;
      if (target.trim().isEmpty) continue;
      final label = m.group(2);
      final labelStart =
          label == null ? m.start + 2 : m.start + 2 + target.length + 1;
      yield HomericWikiLinkMatch(
        start: m.start,
        end: m.end,
        labelStart: labelStart,
        labelEnd: m.end - 2,
        target: target,
      );
    }
  }

  /// Normalised lookup key for a link target or a title: trimmed,
  /// lower-case, runs of whitespace collapsed.
  static String key(String raw) =>
      raw.trim().toLowerCase().replaceAll(_space, ' ');

  /// Source text that links to [target], as `[[target|alias]]`. A stable
  /// id makes a good target; the [alias] keeps the raw text readable.
  static String linkTo(String target, {String? alias}) {
    final clean = alias?.replaceAll(RegExp(r'[\[\]|\s]+'), ' ').trim();
    return clean == null || clean.isEmpty
        ? '[[$target]]'
        : '[[$target|$clean]]';
  }

  /// [text] with each link swapped for words a reader can follow: its
  /// `|label`, else [titleFor] the target, else the raw target. A title
  /// that itself holds a link reads as "a note". Titles are whole unless
  /// [maxTitle] is given, past which they are cut with an ellipsis.
  static String readable(
    String text,
    String? Function(String target) titleFor, {
    int? maxTitle,
  }) {
    if (!text.contains('[[')) return text;
    final out = StringBuffer();
    var cursor = 0;
    for (final m in allMatches(text)) {
      out.write(text.substring(cursor, m.start));
      if (m.hasLabel) {
        out.write(text.substring(m.labelStart, m.labelEnd));
      } else {
        final title = titleFor(m.target);
        if (title == null || title.contains('[[')) {
          out.write(title == null ? m.target : 'a note');
        } else {
          out.write(
            maxTitle == null || title.length <= maxTitle
                ? title
                : '${title.substring(0, maxTitle).trimRight()}…',
          );
        }
      }
      cursor = m.end;
    }
    out.write(text.substring(cursor));
    return out.toString();
  }
}

/// An open `[[` the writer is still typing: `[[target` or `[[target|alias`,
/// with the caret at its end.
@immutable
final class HomericLinkQuery {
  /// Creates a query from [start] (the `[[`) to [end] (the caret).
  const HomericLinkQuery({
    required this.blockId,
    required this.start,
    required this.end,
    required this.target,
    this.alias,
  });

  /// The block being typed in.
  final String blockId;

  /// Offset of the `[[`.
  final int start;

  /// The caret, where the typed query ends.
  final int end;

  /// What is typed after `[[` (before any `|`): what to search for.
  final String target;

  /// What is typed after `|`, when the writer is giving the link their own
  /// words.
  final String? alias;

  /// Longest query read as a link being typed.
  static const maxLength = 80;

  /// The `[[` being typed in [text] with the caret at [caret], or null.
  ///
  /// The query runs from the `[[` to the caret on one line, holds no other
  /// bracket, and is not already closed by `]]` after the caret (that is a
  /// finished link being edited).
  static HomericLinkQuery? at(String blockId, String text, int caret) {
    if (caret < 2 || caret > text.length) return null;
    final open = text.lastIndexOf('[[', caret - 2);
    if (open < 0 || caret - open - 2 > maxLength) return null;
    if (open > 0 && text[open - 1] == '[') return null;
    final typed = text.substring(open + 2, caret);
    if (typed.contains(RegExp(r'[\[\]\n]'))) return null;
    // Inside a finished link (`[[Atl|cap|tion]]`): that is editing it, not
    // starting one.
    final lineEnd = text.indexOf('\n', caret);
    final rest = text.substring(caret, lineEnd < 0 ? text.length : lineEnd);
    final close = rest.indexOf(']]');
    final reopen = rest.indexOf('[[');
    if (close >= 0 && (reopen < 0 || close < reopen)) return null;
    if (text.startsWith(']', caret)) return null;
    final bar = typed.indexOf('|');
    return HomericLinkQuery(
      blockId: blockId,
      start: open,
      end: caret,
      target: (bar < 0 ? typed : typed.substring(0, bar)).trim(),
      alias: bar < 0 ? null : typed.substring(bar + 1).trim(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HomericLinkQuery &&
      other.blockId == blockId &&
      other.start == start &&
      other.end == end &&
      other.target == target &&
      other.alias == alias;

  @override
  int get hashCode => Object.hash(blockId, start, end, target, alias);
}
