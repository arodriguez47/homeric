/// Sentences in a block's text, for sentence focus.
library;

import '../editing/editor_controller.dart' show BlockTextRange;

/// Hand-rolled sentence-boundary segmenter for a single block's plain text.
///
/// No production-ready Dart/pub.dev package implements Unicode UAX #29
/// sentence segmentation today, so this is a heuristic, not a full Unicode
/// implementation. It is deliberately scoped to the common prose cases the
/// editor's focus mode needs (R6): Latin terminal punctuation (`.`, `!`, `?`,
/// or an ellipsis) followed by whitespace and the start of a new sentence, or
/// common CJK terminal punctuation (`。`, `！`, `？`) with or without whitespace,
/// while avoiding false breaks on abbreviations and decimals.
///
/// This function never spans a block boundary — it only ever looks at the
/// single block's text passed to it. Callers are responsible for invoking
/// it per-block.
///
/// Returned ranges are contiguous and non-overlapping, covering the input
/// text from `0` to `text.length` (any trailing/leading whitespace is
/// folded into the adjacent sentence range, never dropped).
List<BlockTextRange> homericSentences(String text) {
  if (text.isEmpty) return const [];

  final breakOffsets = _findSentenceBreakOffsets(text);

  final ranges = <BlockTextRange>[];
  var start = 0;
  for (final breakOffset in breakOffsets) {
    if (breakOffset <= start) continue;
    ranges.add(BlockTextRange(start, breakOffset));
    start = breakOffset;
  }

  if (start < text.length) {
    ranges.add(BlockTextRange(start, text.length));
  }

  return ranges;
}

/// Known abbreviations whose trailing `.` must never be treated as a
/// sentence-terminal period. Deliberately a small, representative set (per
/// the plan's own scoping) rather than an exhaustive dictionary — matched
/// case-sensitively against the word immediately preceding the terminal
/// punctuation.
const _abbreviations = <String>{
  'dr',
  'mr',
  'mrs',
  'ms',
  'prof',
  'jr',
  'sr',
  'vs',
  'etc',
  'e.g',
  'i.e',
  'st',
  'inc',
  'ltd',
  'co',
  'ave',
  'approx',
};

const _terminalChars = {'.', '!', '?', '…', '。', '！', '？'};
const _cjkTerminalChars = {'。', '！', '？'};

bool _isUpperCaseLetter(String char) {
  if (char.isEmpty) return false;
  final lower = char.toLowerCase();
  final upper = char.toUpperCase();
  return lower != upper && char == upper;
}

bool _isLowerCaseLetter(String char) {
  if (char.isEmpty) return false;
  final lower = char.toLowerCase();
  final upper = char.toUpperCase();
  return lower != upper && char == lower;
}

bool _isQuoteOrOpenBracket(String char) {
  const openers = {
    '"',
    "'",
    '“',
    '‘',
    '(',
    '[',
    '„',
    '「',
    '『',
    '（',
    '［',
    '【',
    '《',
    '〈',
    '〔',
    '〖',
    '〘',
    '〚',
  };
  return openers.contains(char);
}

bool _isClosingQuoteOrParen(String char) {
  const closers = {
    '"',
    "'",
    '”',
    '’',
    ')',
    ']',
    '‟',
    '」',
    '』',
    '）',
    '］',
    '】',
    '》',
    '〉',
    '〕',
    '〗',
    '〙',
    '〛',
  };
  return closers.contains(char);
}

bool _isCjkSentenceStart(String char) {
  if (char.isEmpty) return false;
  final code = char.codeUnitAt(0);
  return (code >= 0x3400 && code <= 0x4DBF) || // CJK Extension A
      (code >= 0x4E00 && code <= 0x9FFF) || // CJK Unified Ideographs
      (code >= 0x3040 && code <= 0x309F) || // Hiragana
      (code >= 0x30A0 && code <= 0x30FF) || // Katakana
      (code >= 0x1100 && code <= 0x11FF) || // Hangul Jamo
      (code >= 0x3130 && code <= 0x318F) || // Hangul Compatibility Jamo
      (code >= 0xAC00 && code <= 0xD7AF); // Hangul Syllables
}

bool _markerContainsCjkTerminal(String text, int start, int end) {
  for (var index = start; index < end; index++) {
    if (_cjkTerminalChars.contains(text[index])) return true;
  }
  return false;
}

bool _isDigit(String char) {
  if (char.isEmpty) return false;
  return char.codeUnitAt(0) >= 0x30 && char.codeUnitAt(0) <= 0x39;
}

/// Finds every offset in [text] at which a new sentence should begin (i.e.
/// the split point immediately after any trailing quote/paren attached to
/// the terminal punctuation, and after the whitespace run that follows).
List<int> _findSentenceBreakOffsets(String text) {
  final breaks = <int>[];
  var i = 0;

  while (i < text.length) {
    final char = text[i];
    if (!_terminalChars.contains(char)) {
      i++;
      continue;
    }

    // Consume a run of terminal punctuation as a single marker (handles
    // "..." as well as mixed runs like "?!").
    var markerEnd = i + 1;
    while (
        markerEnd < text.length && _terminalChars.contains(text[markerEnd])) {
      markerEnd++;
    }

    // Special-case a lone "." preceded and followed by a digit: a decimal
    // number, never a sentence break. Only applies when the marker is a
    // single period (a run like "1.2.3" would already be excluded from
    // being a decimal by this same digit-adjacency check per '.').
    if (markerEnd == i + 1 &&
        char == '.' &&
        i > 0 &&
        _isDigit(text[i - 1]) &&
        i + 1 < text.length &&
        _isDigit(text[i + 1])) {
      i = markerEnd;
      continue;
    }

    // Special-case a lone "." immediately preceded by a known abbreviation
    // word.
    if (markerEnd == i + 1 && char == '.' && _endsWithAbbreviation(text, i)) {
      i = markerEnd;
      continue;
    }

    // Absorb a trailing closing quote/paren into the same sentence.
    var cursor = markerEnd;
    while (cursor < text.length && _isClosingQuoteOrParen(text[cursor])) {
      cursor++;
    }

    // End-of-string: this terminal punctuation closes the final sentence,
    // nothing further to scan.
    if (cursor >= text.length) {
      i = cursor;
      continue;
    }

    // Latin terminal punctuation still requires whitespace before the next
    // sentence, preserving the existing no-break behavior for compact strings
    // like "Hi!There". CJK terminal punctuation commonly separates sentences
    // without spaces, so it may break directly when the next character is a
    // plausible sentence start.
    final markerContainsCjkTerminal =
        _markerContainsCjkTerminal(text, i, markerEnd);
    final hasWhitespace = cursor < text.length && _isWhitespace(text[cursor]);
    if (!hasWhitespace && !markerContainsCjkTerminal) {
      i = cursor;
      continue;
    }

    var afterWhitespace = cursor;
    while (
        afterWhitespace < text.length && _isWhitespace(text[afterWhitespace])) {
      afterWhitespace++;
    }

    if (afterWhitespace >= text.length) {
      // Trailing whitespace with nothing after it — not a new sentence;
      // let the remaining text fold into the current sentence range.
      i = cursor;
      continue;
    }

    // An ellipsis marker ("..." or the single Unicode "…" char) is treated
    // as terminal even when followed by a lowercase letter — trailing-off
    // ellipses conventionally continue into a new, often informally-cased,
    // sentence (e.g. "Wait... really?").
    final isEllipsisMarker = char == '…' || (char == '.' && markerEnd - i >= 3);

    final nextChar = text[afterWhitespace];
    final isSentenceStart = markerContainsCjkTerminal ||
        _isUpperCaseLetter(nextChar) ||
        _isQuoteOrOpenBracket(nextChar) ||
        _isCjkSentenceStart(nextChar) ||
        (isEllipsisMarker && _isLowerCaseLetter(nextChar));
    if (isSentenceStart) {
      // Break immediately after the terminal punctuation (and any
      // trailing closing quote/paren) rather than after the whitespace
      // run, so the separating whitespace becomes the leading edge of the
      // next sentence's range instead of trailing the previous one.
      breaks.add(cursor);
      i = afterWhitespace;
      continue;
    }

    i = cursor;
  }

  return breaks;
}

bool _isWhitespace(String char) {
  return char == ' ' || char == '\t' || char == '\n' || char == '\r';
}

/// Checks whether the word ending immediately before the `.` at [dotIndex]
/// matches a known abbreviation (case-insensitive on the letters, since
/// abbreviations may appear mid-sentence with original casing).
bool _endsWithAbbreviation(String text, int dotIndex) {
  var wordStart = dotIndex;
  while (wordStart > 0 && _isWordChar(text[wordStart - 1])) {
    wordStart--;
  }
  if (wordStart == dotIndex) return false;

  final word = text.substring(wordStart, dotIndex).toLowerCase();
  if (_abbreviations.contains(word)) return true;

  // "e.g." / "i.e." are stored above without their internal periods
  // (matched via the ".g"/".e" second-letter dot rule below), but the
  // period *between* the two letters (e.g. the first "." in "e.g.") must
  // also not trigger a break. Check for a preceding single-letter token
  // immediately followed by a "." pattern, e.g. "...e.g. more text" -> the
  // char before this dot is "g", preceded by ".", preceded by "e".
  if (word.length == 1 &&
      dotIndex >= 3 &&
      text[dotIndex - 2] == '.' &&
      _isWordChar(text[dotIndex - 3])) {
    final twoLetterAbbr =
        '${text[dotIndex - 3]}.${text[dotIndex - 1]}'.toLowerCase();
    if (_abbreviations.contains(twoLetterAbbr)) return true;
  }

  return false;
}

bool _isWordChar(String char) {
  if (char.isEmpty) return false;
  final code = char.codeUnitAt(0);
  final isLetter =
      (code >= 0x41 && code <= 0x5A) || (code >= 0x61 && code <= 0x7A);
  return isLetter;
}
