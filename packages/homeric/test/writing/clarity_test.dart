import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/writing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Block block(String id, String text) =>
      Block(id: id, type: 'paragraph', runs: [InlineRun(text)]);

  // Capitalized, as a new sentence starts.
  String words(int n) => ['Word', ...List.filled(n - 1, 'word')].join(' ');

  const clarity = HomericClarity();

  group('long sentences', () {
    test('marks sentences past the marks, and only those', () {
      final text = 'Short one here. ${words(21)}. ${words(31)}. Done.';
      final found = clarity.longSentencesInText('a', text);
      expect(found, hasLength(2));
      expect(found[0].words, 21);
      expect(found[0].length, HomericSentenceLength.long);
      expect(found[1].words, 31);
      expect(found[1].length, HomericSentenceLength.veryLong);
    });

    test('a mark covers the sentence without the spaces around it', () {
      final text = 'Hi. ${words(25)}.  Bye.';
      final s = clarity.longSentencesInText('a', text).single;
      expect(text.substring(s.start, s.end), '${words(25)}.');
    });

    test('twenty words is not long', () {
      expect(clarity.longSentencesInText('a', '${words(20)}.'), isEmpty);
    });

    test('footnotes, comment lines and annotation notes do not count', () {
      final note = words(15);
      final text = '${words(15)}^[$note] {{passage|$note}}.\n%% $note $note';
      expect(clarity.longSentencesInText('a', text), isEmpty);
    });

    test('a footnote written in a code span is read, not left out', () {
      final note = words(15);
      final text = '${words(10)} `^[$note]`.';
      expect(clarity.longSentencesInText('a', text), hasLength(1));
    });

    test('a footnote reference is not a word', () {
      expect(
        clarity.longSentencesInText('a', '${words(20)}[^source].'),
        isEmpty,
      );
    });

    test('decorations carry the spec for each length', () {
      final b = block('b', '${words(22)}. ${words(35)}.');
      final decorations =
          clarity.decorationsFor(b, longSpec: #long, veryLongSpec: #very);
      expect([for (final d in decorations) d.spec], [#long, #very]);
    });

    test('thresholds can move', () {
      const tight = HomericClarity(long: 5, veryLong: 8);
      final found = tight.longSentencesInText('a', '${words(6)}. ${words(9)}.');
      expect([for (final s in found) s.length], [
        HomericSentenceLength.long,
        HomericSentenceLength.veryLong,
      ]);
    });
  });

  group('grade', () {
    test('too little text has no grade', () {
      expect(HomericClarity.grade('One two three.'), isNull);
    });

    test('short plain sentences read lower than long dense ones', () {
      const plain = 'I tried it on Friday. It worked. We kept it. '
          'The team was glad. Then we moved on.';
      const dense = 'Notwithstanding considerable organizational '
          'apprehension regarding implementation, the comprehensive '
          'restructuring initiative ultimately demonstrated substantial '
          'operational improvements across interdepartmental workflows.';
      final low = HomericClarity.grade(plain)!;
      final high = HomericClarity.grade(dense)!;
      expect(low, lessThan(5));
      expect(high, greaterThan(15));
    });

    test('a soft break inside a sentence does not lower the grade', () {
      const one = 'Notwithstanding considerable apprehension the team kept '
          'restructuring the comprehensive initiative.';
      const broken = 'Notwithstanding considerable apprehension the team kept\n'
          'restructuring the comprehensive initiative.';
      expect(HomericClarity.grade(broken), HomericClarity.grade(one));
    });

    test('a soft break before a quoted lower-case word continues', () {
      const one = 'Notwithstanding considerable apprehension the team kept '
          '“restructuring” the comprehensive initiative.';
      const broken = 'Notwithstanding considerable apprehension the team kept\n'
          '“restructuring” the comprehensive initiative.';
      expect(HomericClarity.grade(broken), HomericClarity.grade(one));
    });

    test('task and list lines each count as their own sentence', () {
      const tasks = '[x] buy considerable groceries tomorrow\n'
          '[x] call the comprehensive insurance office';
      const apart = '[x] buy considerable groceries tomorrow.\n'
          '[x] call the comprehensive insurance office.';
      expect(HomericClarity.grade(tasks), HomericClarity.grade(apart));
      const bullets = '- buy considerable groceries tomorrow\n'
          '- call the comprehensive insurance office';
      const bulletsApart = '- buy considerable groceries tomorrow.\n'
          '- call the comprehensive insurance office.';
      expect(HomericClarity.grade(bullets), HomericClarity.grade(bulletsApart));
    });

    test('works for Spanish', () {
      const text = 'Lo probé el viernes. Funcionó bien. '
          'Nos quedamos con el cambio y seguimos.';
      expect(HomericClarity.grade(text), isNotNull);
    });
  });
}
