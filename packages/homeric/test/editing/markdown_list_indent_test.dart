import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

void main() {
  group('HomericMarkdownListIndent', () {
    test('detects bullet, star, and ordered markers with optional indent', () {
      expect(HomericMarkdownListIndent.isListItem('- item'), isTrue);
      expect(HomericMarkdownListIndent.isListItem('* item'), isTrue);
      expect(HomericMarkdownListIndent.isListItem('1. item'), isTrue);
      expect(HomericMarkdownListIndent.isListItem('12. item'), isTrue);
      expect(HomericMarkdownListIndent.isListItem('  - nested'), isTrue);
      expect(HomericMarkdownListIndent.isListItem('\t- nested'), isTrue);
      expect(HomericMarkdownListIndent.isListItem('plain'), isFalse);
      expect(HomericMarkdownListIndent.isListItem('-item'), isFalse);
      expect(HomericMarkdownListIndent.isListItem('1.item'), isFalse);
    });

    test('nest prepends one two-space unit without rewriting the marker', () {
      final edit = HomericMarkdownListIndent.nest('- item ');
      expect(edit, isNotNull);
      expect(edit!.start, 0);
      expect(edit.end, 0);
      expect(edit.replacement, HomericMarkdownListIndent.unit);
      expect(edit.caretDelta, 2);

      final ordered = HomericMarkdownListIndent.nest('1. item');
      expect(ordered, isNotNull);
      expect(ordered!.replacement, '  ');

      expect(HomericMarkdownListIndent.nest('not a list'), isNull);
    });

    test('outdent removes one indent unit and refuses unindented items', () {
      final edit = HomericMarkdownListIndent.outdent('  - item ');
      expect(edit, isNotNull);
      expect(edit!.start, 0);
      expect(edit.end, 2);
      expect(edit.replacement, isEmpty);
      expect(edit.caretDelta, -2);

      final tabbed = HomericMarkdownListIndent.outdent('\t1. item');
      expect(tabbed, isNotNull);
      expect(tabbed!.end, 1);
      expect(tabbed.caretDelta, -1);

      expect(HomericMarkdownListIndent.outdent('- item'), isNull);
      expect(HomericMarkdownListIndent.outdent('plain'), isNull);
    });
  });
}
