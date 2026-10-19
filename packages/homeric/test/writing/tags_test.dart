import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/writing.dart';

void main() {
  group('HomericTags', () {
    test('extracts unique lowercase tags', () {
      expect(
        HomericTags.parse(
            'Ship #Flutter polish with #design and #Flutter again'),
        ['flutter', 'design'],
      );
    });

    test('ignores lone hash', () {
      expect(HomericTags.parse('not a # tag'), isEmpty);
    });

    test('mergeTags combines explicit and parsed', () {
      expect(
        HomericTags.merge(['work'], 'idea about #product and #Work'),
        ['work', 'product'],
      );
    });

    test('retagText renames or unhashes every inline tag', () {
      expect(
        HomericTags.retagText('A #Idea and #idea, (#idea)', 'idea', 'plan'),
        'A #plan and #plan, (#plan)',
      );
      expect(
          HomericTags.retagText('A #idea here', 'idea', null), 'A idea here');
      expect(HomericTags.retagText('No tags', 'idea', 'x'), 'No tags');
    });

    test('a hand tag survives deleting its inline #tag', () {
      expect(
        HomericTags.retagForBody(
          ['idea', 'kept'],
          before: 'An #idea and #kept',
          after: 'An idea and',
          handTags: ['kept'],
        ),
        ['kept'],
      );
    });

    test('renameInTags keeps a tag once', () {
      expect(HomericTags.renameInTags(['a', 'b', 'c'], 'a', 'c'), ['c', 'b']);
      expect(HomericTags.renameInTags(['a', 'b'], 'a', null), ['b']);
    });
  });
}
