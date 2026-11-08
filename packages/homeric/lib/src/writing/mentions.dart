/// `@` mentions: an `@` typed at the start of a word opens a link to a
/// hub (a person, a book, a project) by name.
///
/// Homeric finds the mention being typed; which hubs it offers, what a
/// pick writes (usually a `[[link]]` over the mention) and how it looks
/// belong to the host.
library;

import 'package:flutter/foundation.dart' show immutable;

/// An `@` the writer is still typing, `@Julien Sor` or `@Rouge #book`,
/// with the caret at its end.
@immutable
final class HomericMentionQuery {
  /// Creates a query from [start] (the `@`) to [end] (the caret).
  const HomericMentionQuery({
    required this.blockId,
    required this.start,
    required this.end,
    required this.name,
    this.kind,
  });

  /// The block being typed in.
  final String blockId;

  /// Offset of the `@`.
  final int start;

  /// The caret, where the mention typed so far ends. A pick replaces
  /// `[start, end)`.
  final int end;

  /// The name typed after the `@`, without a `#kind` after it, trimmed:
  /// what to look for. Empty right after the `@`.
  final String name;

  /// A `#kind` typed as the mention's last word (`@Rouge #book`), or right
  /// after the `@` (`@#book`), as far as it is typed and without its `#`:
  /// the Kind to narrow to. Empty while only the `#` is typed; null when
  /// there is none.
  final String? kind;

  /// Longest mention read as one being typed: a long name, with its Kind.
  static const maxLength = 60;

  /// What may come right before the `@`: a space or an opening bracket or
  /// quote. Never a letter, so an address (`ana@example.com`) or a handle
  /// in a link isn't a mention.
  static final RegExp _opens = RegExp('[\\s(\\[{"\'“‘«]');

  /// A `#kind` as the last word, typed as far as the caret.
  static final RegExp _kindAtEnd = RegExp(
    r'(?:^|\s)#([a-zA-Z0-9][\w-]{0,48})?$',
  );

  /// A sentence moving on: punctuation and then a space, or a closing
  /// bracket or quote, which no name ends in. A square bracket starts or
  /// ends a link. An apostrophe or a straight quote can be inside a name
  /// (`O’Brien`), so only one with a space after ends it.
  static final RegExp _movedOn = RegExp(r'[.,;:!?"’]\s|[\[\])}”»]');

  /// The mention being typed in [text] with the caret at [caret], or null.
  ///
  /// It runs from an `@` to the caret on one line: the `@` starts a word
  /// (the line's start, or after a space, bracket or quote) and is
  /// followed by a name, not a space. It ends where the sentence moves on
  /// (`@Julien, then`), at a closing bracket or quote (`(@Julien)`), at a
  /// square bracket, or past [maxLength].
  static HomericMentionQuery? at(String blockId, String text, int caret) {
    if (caret < 1 || caret > text.length) return null;
    final lineStart = text.lastIndexOf('\n', caret - 1) + 1;
    final at = text.lastIndexOf('@', caret - 1);
    if (at < lineStart || caret - at - 1 > maxLength) return null;
    if (at > 0 && !_opens.hasMatch(text[at - 1])) return null;
    final typed = text.substring(at + 1, caret);
    if (typed.isNotEmpty && typed.trimLeft().length != typed.length) {
      return null;
    }
    if (_movedOn.hasMatch(typed)) return null;
    final tag = _kindAtEnd.firstMatch(typed);
    return HomericMentionQuery(
      blockId: blockId,
      start: at,
      end: caret,
      name: (tag == null ? typed : typed.substring(0, tag.start)).trim(),
      kind: tag == null ? null : (tag.group(1) ?? '').toLowerCase(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HomericMentionQuery &&
      other.blockId == blockId &&
      other.start == start &&
      other.end == end &&
      other.name == name &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(blockId, start, end, name, kind);

  @override
  String toString() => 'HomericMentionQuery($blockId, $start–$end, "$name"'
      '${kind == null ? '' : ', #$kind'})';
}
