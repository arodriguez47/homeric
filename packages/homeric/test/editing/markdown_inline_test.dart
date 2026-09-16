import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

import '../transform/transform_test_utils.dart';

void main() {
  group('HomericMarkdownImage', () {
    test('tokenizes ![alt](url) with bang, alt, and close ranges', () {
      const text = 'see ![cat](https://x.test/c.png) here';
      final matches = HomericMarkdownImage.allMatches(text).toList();
      expect(matches, hasLength(1));
      final m = matches.single;
      expect(m.start, 4);
      expect(m.openBracketStart, 5);
      expect(m.altStart, 6);
      expect(m.altEnd, 9);
      expect(m.closeStart, 9);
      expect(m.end, 32);
      expect(m.alt, 'cat');
      expect(m.url, 'https://x.test/c.png');
      expect(text.substring(m.start, m.end), '![cat](https://x.test/c.png)');
      expect(text.substring(m.start, m.openBracketEnd), '![');
      expect(text.substring(m.closeStart, m.end), '](https://x.test/c.png)');
    });

    test('allows empty alt', () {
      final matches =
          HomericMarkdownImage.allMatches('![](https://x.test/a.png)').toList();
      expect(matches, hasLength(1));
      expect(matches.single.alt, isEmpty);
      expect(matches.single.altStart, matches.single.altEnd);
      expect(matches.single.url, 'https://x.test/a.png');
    });

    test('finds multiple images', () {
      const text = '![a](u1) mid ![b](u2)';
      final matches = HomericMarkdownImage.allMatches(text).toList();
      expect(matches.map((m) => m.alt), ['a', 'b']);
      expect(matches.map((m) => m.url), ['u1', 'u2']);
    });

    test('leavePictureDecorations hide bang/brackets and carry url', () {
      const text = '![cat](https://x.test/c.png)';
      final match = HomericMarkdownImage.allMatches(text).single;
      final decorations =
          HomericMarkdownImage.leavePictureDecorations('b', match);
      final derived = deriveViewText(para('b', text), decorations);
      expect(derived.viewText, objectReplacementCharacter);
      expect(
        derived.slots.single.decoration.spec,
        const HomericMarkdownImageSpec(
          url: 'https://x.test/c.png',
          alt: 'cat',
        ),
      );
    });
  });

  group('HomericMarkdownLink', () {
    test('tokenizes [label](url)', () {
      const text = 'see [docs](https://x.test) here';
      final matches = HomericMarkdownLink.allMatches(text).toList();
      expect(matches, hasLength(1));
      final m = matches.single;
      expect(m.start, 4);
      expect(m.labelStart, 5);
      expect(m.labelEnd, 9);
      expect(m.closeStart, 9);
      expect(m.end, 26);
      expect(m.label, 'docs');
      expect(m.url, 'https://x.test');
    });

    test('skips images so ![alt](url) is not a link', () {
      const text = '![alt](https://x.test/i.png)';
      expect(HomericMarkdownLink.allMatches(text), isEmpty);
      expect(HomericMarkdownImage.allMatches(text), hasLength(1));
    });

    test('naive link regex matches the image body — adversary for hosts', () {
      const text = '![alt](https://x.test/i.png)';
      final naive =
          RegExp(r'\[([^\]]+)\]\(([^)]+)\)').allMatches(text).toList();
      expect(naive, hasLength(1),
          reason: 'host-only link regex still sees [alt](url) inside an image');
      expect(naive.single.start, 1);
      expect(text.substring(0, naive.single.start), '!',
          reason: 'leaving ! outside the link match is the broken !alt paint');
      expect(HomericMarkdownLink.allMatches(text), isEmpty,
          reason: 'Homeric link tokenizer must not emit that match');
    });

    test('keeps a real link beside an image', () {
      const text = '![a](img) and [b](https://x.test)';
      expect(HomericMarkdownImage.allMatches(text).map((m) => m.alt), ['a']);
      expect(HomericMarkdownLink.allMatches(text).map((m) => m.label), ['b']);
    });
  });
}
