/// Long sentences and a reading grade, for a writer polishing a draft.
///
/// Clarity is plain counting, no language model: it splits each block into
/// sentences with [homericSentences], counts the words in each, and marks
/// the ones past [HomericClarity.long] and [HomericClarity.veryLong]. Words
/// inside notes the reader doesn't read inline (`^[footnotes]`, the note
/// half of `{{passage|note}}`, `%%` comments) don't count toward a
/// sentence. The host styles the marks in its run-style resolver through
/// the specs it passes to [HomericClarity.decorationsFor].
///
/// [HomericClarity.grade] is the Automated Readability Index over the
/// whole text: roughly the school year a reader needs to follow it. Both
/// work for any language written with spaces between words.
library;

import 'package:flutter/foundation.dart';

import '../decoration/decoration.dart';
import '../model/block.dart';
import 'brevity.dart';
import 'note_marks.dart';
import 'sentences.dart';

/// How long a sentence reads.
enum HomericSentenceLength {
  /// Past [HomericClarity.long] words.
  long,

  /// Past [HomericClarity.veryLong] words.
  veryLong,
}

/// One sentence past [HomericClarity.long], at block-local `[start, end)`.
@immutable
final class HomericLongSentence {
  const HomericLongSentence({
    required this.blockId,
    required this.start,
    required this.end,
    required this.words,
    required this.length,
  });

  final String blockId;
  final int start;
  final int end;

  /// Words in the sentence, notes left out.
  final int words;

  final HomericSentenceLength length;

  @override
  bool operator ==(Object other) =>
      other is HomericLongSentence &&
      other.blockId == blockId &&
      other.start == start &&
      other.end == end &&
      other.words == words &&
      other.length == length;

  @override
  int get hashCode => Object.hash(blockId, start, end, words, length);

  @override
  String toString() =>
      'HomericLongSentence($blockId $start-$end, $words words, ${length.name})';
}

/// Sentence-length marks and a reading grade.
@immutable
final class HomericClarity {
  const HomericClarity({this.long = 20, this.veryLong = 30})
      : assert(long > 0 && veryLong >= long);

  /// Words a sentence can have before it reads as long.
  final int long;

  /// Words a sentence can have before it reads as very long.
  final int veryLong;

  /// The sentences of [block] past [long], in order.
  List<HomericLongSentence> longSentencesIn(Block block) =>
      longSentencesInText(block.id, block.text);

  /// The sentences of [text] past [long], as block [blockId]'s.
  List<HomericLongSentence> longSentencesInText(String blockId, String text) {
    if (text.isEmpty) return const [];
    final read = _readable(text);
    final out = <HomericLongSentence>[];
    for (final range in homericSentences(read)) {
      final sentence = read.substring(range.start, range.end);
      final words = HomericBrevity.countWords(sentence);
      if (words <= long) continue;
      // Leading and trailing spaces stay out of the mark.
      final lead = sentence.length - sentence.trimLeft().length;
      final trail = sentence.length - sentence.trimRight().length;
      out.add(
        HomericLongSentence(
          blockId: blockId,
          start: range.start + lead,
          end: range.end - trail,
          words: words,
          length: words > veryLong
              ? HomericSentenceLength.veryLong
              : HomericSentenceLength.long,
        ),
      );
    }
    return out;
  }

  /// Inline decorations over [block]'s long sentences: [longSpec] on the
  /// long ones, [veryLongSpec] on the very long ones.
  Iterable<Decoration> decorationsFor(
    Block block, {
    Object? longSpec,
    Object? veryLongSpec,
  }) sync* {
    for (final s in longSentencesIn(block)) {
      yield Decoration.inline(
        block.id,
        s.start,
        s.end,
        spec: s.length == HomericSentenceLength.veryLong
            ? veryLongSpec
            : longSpec,
      );
    }
  }

  /// The Automated Readability Index of [text], rounded, at least 1; null
  /// when there is too little text to say (under ten words).
  static int? grade(String text) {
    final read = _readable(text);
    var words = 0;
    var letters = 0;
    for (final m in HomericBrevity.wordPattern.allMatches(read)) {
      words++;
      letters += m[0]!.replaceAll(RegExp(r"['’\-]"), '').runes.length;
    }
    if (words < 10) return null;
    var sentences = 0;
    for (final paragraph in _paragraphs(read)) {
      for (final r in homericSentences(paragraph)) {
        final s = paragraph.substring(r.start, r.end);
        if (HomericBrevity.wordPattern.hasMatch(s)) sentences++;
      }
    }
    if (sentences == 0) sentences = 1;
    final ari = 4.71 * (letters / words) + 0.5 * (words / sentences) - 21.43;
    return ari.round().clamp(1, 99);
  }
}

/// [text] with the notes a reader doesn't read inline blanked to spaces,
/// so offsets stay the same: inline footnotes, the note half of an
/// annotation, `%%` lines, footnote definitions and references. [HomericMarkScan]
/// settles which marks count, so nothing in a code span or wiki link is
/// taken for a note. A footnote reference reads as its marker, not its id.
String _readable(String text) {
  final scan = HomericMarkScan(text);
  final spans = <(int, int)>[
    ...scan.foldedSpans,
    for (final c in scan.commentLines) (c.start, c.end),
    for (final d in scan.definitions) (d.start, d.end),
    for (final r in scan.references) (r.start, r.end),
  ];
  if (spans.isEmpty) return text;
  final out = text.split('');
  for (final (start, end) in spans) {
    for (var i = start; i < end && i < out.length; i++) {
      if (out[i] != '\n') out[i] = ' ';
    }
  }
  return out.join();
}

/// [text]'s paragraphs for counting sentences. A line break inside a
/// sentence (a soft break, the next line going on in lower case) joins
/// the lines; any other break ends one, so a heading counts on its own.
Iterable<String> _paragraphs(String text) sync* {
  final buffer = StringBuffer();
  for (final line in text.split('\n')) {
    // The first letter, past any opening quote or bracket.
    final next = line.replaceFirst(RegExp('^[\\s"“‘\'(\\[«¿¡]+'), '');
    final continues = buffer.isNotEmpty &&
        next.isNotEmpty &&
        next[0] != next[0].toUpperCase() &&
        !RegExp(r'[.!?…。！？]["”’)\]]*\s*$').hasMatch(buffer.toString());
    if (!continues && buffer.isNotEmpty) {
      yield buffer.toString();
      buffer.clear();
    }
    if (buffer.isNotEmpty) buffer.write(' ');
    buffer.write(line);
  }
  if (buffer.isNotEmpty) yield buffer.toString();
}
