import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/src/model/inline_run.dart';

void main() {
  group('InlineRun', () {
    test('exposes text, length, and attributes', () {
      final run = InlineRun('hello', attributes: {'bold': true});
      expect(run.text, 'hello');
      expect(run.length, 5);
      expect(run.isEmpty, isFalse);
      expect(run.attributes, {'bold': true});
    });

    test('supports empty text', () {
      final run = InlineRun('');
      expect(run.length, 0);
      expect(run.isEmpty, isTrue);
    });

    test('freezes its attribute set', () {
      final run = InlineRun('x', attributes: {'style': 'em'});
      expect(() => run.attributes['style'] = 'strong', throwsUnsupportedError);
    });

    test('hasSameAttributesAs uses deep equality, not identity', () {
      final a = InlineRun('a', attributes: {
        'link': {'href': 'https://example.com'},
      });
      final b = InlineRun('b', attributes: {
        'link': {'href': 'https://example.com'},
      });
      final c = InlineRun('c', attributes: {
        'link': {'href': 'https://other.example'},
      });
      expect(identical(a.attributes, b.attributes), isFalse);
      expect(a.hasSameAttributesAs(b), isTrue);
      expect(a.hasSameAttributesAs(c), isFalse);
    });

    test('copyWith shares the frozen attribute bag when untouched', () {
      final run = InlineRun('abc', attributes: {'bold': true});
      final longer = run.copyWith(text: 'abcd');
      expect(longer.text, 'abcd');
      expect(identical(longer.attributes, run.attributes), isTrue);
    });

    test('copyWith with new attributes keeps the original intact', () {
      final run = InlineRun('abc', attributes: {'bold': true});
      final restyled = run.copyWith(attributes: {'italic': true});
      expect(restyled.attributes, {'italic': true});
      expect(run.attributes, {'bold': true});
      expect(identical(restyled.text, run.text), isTrue);
    });
  });
}
