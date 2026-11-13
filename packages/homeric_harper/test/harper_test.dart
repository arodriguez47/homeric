import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric_harper/homeric_harper.dart';
import 'package:homeric_harper/src/harper_source_io.dart'
    show harperGroupOf, parseHarperFindings;

void main() {
  test('maps Harper kinds onto the settings groups', () {
    expect(
      harperGroupOf('TheirToTheyre', 'WordChoice'),
      HomericProofingGroup.grammar,
    );
    expect(
      harperGroupOf('RepeatedWords', 'Repetition'),
      HomericProofingGroup.repetitionAndPunctuation,
    );
    expect(
      harperGroupOf('Wordiness', 'Redundancy'),
      HomericProofingGroup.wordiness,
    );
    expect(
      harperGroupOf('LongSentences', 'Readability'),
      HomericProofingGroup.longSentences,
    );
  });

  test('drops malformed findings', () {
    final found = parseHarperFindings(
      '[{"start":0,"end":5,"rule":"R","kind":"Grammar","message":"m",'
      '"replacements":["x"]},{"start":4,"end":99,"rule":"R","kind":"Grammar",'
      '"message":"m","replacements":[]}]',
      10,
    );
    expect(found, hasLength(1));
    expect(found.single.replacements, ['x']);
  });

  test('Harper finds wrong words and repeated words, in UTF-16', () async {
    final harper = HarperProofingSource();
    const text = '🌊 Their going to see if the the anemones opened.';
    final found = await harper.check(text);
    final words = {
      for (final issue in found)
        issue.ruleId: text.substring(issue.range.start, issue.range.end),
    };
    expect(words['RepeatedWords'], 'the the');
    expect(words.values, contains('Their'));
    expect(await harper.check('We walked out at low tide.'), isEmpty);
  });

  test('a long Sheet checks quickly', () async {
    final harper = HarperProofingSource();
    await harper.check('Warm up.');
    const paragraph =
        'We walked out at low tide to look at the tide pools, and the '
        'water was so still that every anemone showed. Their colours '
        'were brighter than the the ones we saw last spring, in order to '
        'see them we had to kneel on the rocks for a long time.';
    final watch = Stopwatch()..start();
    for (var i = 0; i < 200; i++) {
      await harper.check('$paragraph $i');
    }
    watch.stop();
    final perParagraph = watch.elapsedMicroseconds / 200 / 1000;
    // ignore: avoid_print
    print(
      'Harper: ${perParagraph.toStringAsFixed(2)} ms per paragraph '
      '(200 paragraphs, ~${paragraph.split(' ').length} words each)',
    );
    expect(perParagraph, lessThan(25));
  });
}
