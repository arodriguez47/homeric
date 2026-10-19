import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/writing.dart';

List<String> _segments(String text) {
  return homericSentences(text)
      .map((range) => text.substring(range.start, range.end).trim())
      .toList(growable: false);
}

void main() {
  group('segmentSentences', () {
    test('returns zero ranges for an empty string', () {
      final ranges = homericSentences('');
      expect(ranges, isEmpty);
    });

    test(
        'returns one range spanning the whole text with no terminal '
        'punctuation', () {
      const text = 'no terminal punctuation here';
      final ranges = homericSentences(text);

      expect(ranges, hasLength(1));
      expect(ranges.single.start, 0);
      expect(ranges.single.end, text.length);
    });

    test('segments standard multi-sentence prose at ./!/? boundaries', () {
      const text = 'The cat sat. The dog ran! Did it work?';
      final ranges = homericSentences(text);

      expect(ranges, hasLength(3));
      expect(text.substring(ranges[0].start, ranges[0].end), 'The cat sat.');
      expect(
        text.substring(ranges[1].start, ranges[1].end).trimLeft(),
        'The dog ran!',
      );
      expect(
        text.substring(ranges[2].start, ranges[2].end).trimLeft(),
        'Did it work?',
      );
      // Ranges are contiguous: the separating whitespace between sentences
      // attaches to the *following* sentence's leading edge, never dropped
      // and never overlapping.
      expect(ranges[0].end, ranges[1].start);
      expect(ranges[1].end, ranges[2].start);
      expect(ranges[0].start, 0);
      expect(ranges[2].end, text.length);
    });

    test('does not split on an abbreviation like "Dr."', () {
      const text = 'Dr. Smith arrived.';
      final ranges = homericSentences(text);

      expect(ranges, hasLength(1));
      expect(text.substring(ranges.single.start, ranges.single.end), text);
    });

    test('does not split on other known abbreviations', () {
      const abbreviations = [
        'Mr.',
        'Mrs.',
        'Ms.',
        'Prof.',
        'Jr.',
        'Sr.',
        'vs.',
        'etc.',
        'e.g.',
        'i.e.',
        'St.',
        'Inc.',
        'Ltd.',
        'Co.',
        'Ave.',
        'approx.',
      ];

      for (final abbr in abbreviations) {
        final text = 'Please see $abbr Next thing continues.';
        final ranges = homericSentences(text);
        expect(
          ranges,
          hasLength(1),
          reason: 'Abbreviation "$abbr" incorrectly caused a sentence break '
              'in "$text"',
        );
      }
    });

    test('does not split on a decimal number', () {
      const text = 'The value is 3.14 today.';
      final ranges = homericSentences(text);

      expect(ranges, hasLength(1));
      expect(text.substring(ranges.single.start, ranges.single.end), text);
    });

    test('treats a multi-digit decimal correctly without a false break', () {
      const text = 'Pi is approximately 3.14159 and useful.';
      final ranges = homericSentences(text);

      expect(ranges, hasLength(1));
    });

    test('treats ellipsis "..." as a single terminal marker', () {
      const text = 'Wait... really?';
      final ranges = homericSentences(text);

      expect(ranges, hasLength(2));
      expect(text.substring(ranges[0].start, ranges[0].end), 'Wait...');
      expect(
        text.substring(ranges[1].start, ranges[1].end).trimLeft(),
        'really?',
      );
    });

    test(
        'treats the Unicode ellipsis character "…" as a single terminal '
        'marker', () {
      const text = 'Wait… really?';
      final ranges = homericSentences(text);

      expect(ranges, hasLength(2));
      expect(text.substring(ranges[0].start, ranges[0].end), 'Wait…');
      expect(
        text.substring(ranges[1].start, ranges[1].end).trimLeft(),
        'really?',
      );
    });

    test(
        'keeps a closing quote after terminal punctuation in the same '
        'sentence', () {
      const text = 'He said "stop." Then he left.';
      final ranges = homericSentences(text);

      expect(ranges, hasLength(2));
      expect(
        text.substring(ranges[0].start, ranges[0].end),
        'He said "stop."',
      );
      expect(
        text.substring(ranges[1].start, ranges[1].end).trimLeft(),
        'Then he left.',
      );
    });

    test(
        'keeps a closing paren after terminal punctuation in the same '
        'sentence', () {
      const text = '(See the note.) Now continue.';
      final ranges = homericSentences(text);

      expect(ranges, hasLength(2));
      expect(
        text.substring(ranges[0].start, ranges[0].end),
        '(See the note.)',
      );
      expect(
        text.substring(ranges[1].start, ranges[1].end).trimLeft(),
        'Now continue.',
      );
    });

    test('handles consecutive terminal punctuation like "?!" as one marker',
        () {
      const text = 'Really?! I had no idea.';
      final ranges = homericSentences(text);

      expect(ranges, hasLength(2));
      expect(text.substring(ranges[0].start, ranges[0].end), 'Really?!');
      expect(
        text.substring(ranges[1].start, ranges[1].end).trimLeft(),
        'I had no idea.',
      );
    });

    test(
        'segments Chinese sentences at CJK terminal punctuation without '
        'spaces', () {
      const text = '第一句。第二句！第三句？';

      expect(_segments(text), [
        '第一句。',
        '第二句！',
        '第三句？',
      ]);
    });

    test('keeps Japanese closing quote with the CJK terminal sentence', () {
      const text = '彼は言った「行こう！」そして走った。';

      expect(_segments(text), [
        '彼は言った「行こう！」',
        'そして走った。',
      ]);
    });

    test('segments Korean and CJK punctuation together', () {
      const text = '첫 문장입니다。다음 문장입니다？끝입니다！';

      expect(_segments(text), [
        '첫 문장입니다。',
        '다음 문장입니다？',
        '끝입니다！',
      ]);
    });

    test('segments mixed Latin and CJK while preserving decimals', () {
      const text = 'Alpha 1.23 stays. 这是第二句。Next sentence?';

      expect(_segments(text), [
        'Alpha 1.23 stays.',
        '这是第二句。',
        'Next sentence?',
      ]);
    });

    test(
        'treats CJK terminal punctuation as a boundary before digits and '
        'lowercase Latin', () {
      const text = '版本完成。2024年继续。iOS也支持。';

      expect(_segments(text), [
        '版本完成。',
        '2024年继续。',
        'iOS也支持。',
      ]);
    });

    test(
        'closes the final sentence at end-of-string with no trailing '
        'whitespace', () {
      const text = 'This is the last sentence.';
      final ranges = homericSentences(text);

      expect(ranges, hasLength(1));
      expect(ranges.single.start, 0);
      expect(ranges.single.end, text.length);
    });

    test(
        'handles a sentence opening with a quote after terminal '
        'punctuation', () {
      const text = 'He paused. "Now what?" she asked.';
      final ranges = homericSentences(text);

      expect(ranges, hasLength(2));
      expect(text.substring(ranges[0].start, ranges[0].end), 'He paused.');
      expect(
        text.substring(ranges[1].start, ranges[1].end).trimLeft(),
        '"Now what?" she asked.',
      );
    });

    test('never produces overlapping ranges and stays within text bounds', () {
      const text = 'Dr. Who? The value is 3.14. Wait... really! Yes.';
      final ranges = homericSentences(text);

      expect(ranges, isNotEmpty);
      for (final range in ranges) {
        expect(range.start, greaterThanOrEqualTo(0));
        expect(range.end, lessThanOrEqualTo(text.length));
        expect(range.start, lessThan(range.end));
      }
      for (var i = 1; i < ranges.length; i++) {
        expect(ranges[i - 1].end <= ranges[i].start, isTrue);
      }
    });
  });
}
