import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

void main() {
  group('HomericMarkdownListPrefix', () {
    test('tokenizes column-0 and indented bullet/ordered markers', () {
      final plain = HomericMarkdownListPrefix.match('- item');
      expect(plain, isNotNull);
      expect(plain!.indentLength, 0);
      expect(plain.markerStart, 0);
      expect(plain.markerEnd, 1);
      expect(plain.prefixEnd, 2);
      expect(plain.kind, HomericMarkdownListKind.bullet);
      expect(plain.visibleMark, '•');

      final nested = HomericMarkdownListPrefix.match('  - item');
      expect(nested, isNotNull);
      expect(nested!.indentLength, 2);
      expect(nested.markerStart, 2);
      expect(nested.markerEnd, 3);
      expect(nested.prefixEnd, 4);
      expect(nested.visibleMark, '•');

      final ordered = HomericMarkdownListPrefix.match('  12. item');
      expect(ordered, isNotNull);
      expect(ordered!.indentLength, 2);
      expect(ordered.markerStart, 2);
      expect(ordered.markerEnd, 5);
      expect(ordered.prefixEnd, 6);
      expect(ordered.kind, HomericMarkdownListKind.ordered);
      expect(ordered.orderedDigits, '12');
      expect(ordered.visibleMark, '12.');

      expect(HomericMarkdownListPrefix.match('plain'), isNull);
      expect(HomericMarkdownListPrefix.match('-item'), isNull);
      expect(HomericMarkdownListPrefix.match('1.item'), isNull);
    });
  });

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
