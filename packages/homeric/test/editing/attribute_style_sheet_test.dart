import 'package:flutter/painting.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

void main() {
  group('HomericAttributeStyleSheet', () {
    const sheet = HomericAttributeStyleSheet.standard;
    const base = TextStyle(fontSize: 16, height: 1.5);

    test('derives inline decorations for bold/italic/code runs', () {
      final block = Block(
        id: 'b',
        type: 'paragraph',
        runs: [
          InlineRun('plain '),
          InlineRun('bold', attributes: const <String, Object?>{'bold': true}),
          InlineRun(' '),
          InlineRun('ital',
              attributes: const <String, Object?>{'italic': true}),
          InlineRun(' '),
          InlineRun('code', attributes: const <String, Object?>{'code': true}),
          InlineRun(
            'both',
            attributes: const <String, Object?>{'bold': true, 'italic': true},
          ),
        ],
      );

      final decorations = sheet.decorationsFor(block);
      // bold, italic, code, plus bold+italic on the last run → 5 decorations.
      expect(decorations, hasLength(5));
      expect(
        decorations.every((d) => d.kind == DecorationKind.inline),
        isTrue,
      );
      expect(decorations.every((d) => d.blockId == 'b'), isTrue);

      final bold = decorations
          .where((d) => identical(d.spec, HomericStockAttributeSpec.bold))
          .toList();
      expect(bold, hasLength(2));
      expect(bold.first.start, 6);
      expect(bold.first.end, 10);
      expect(bold.last.start, 20);
      expect(bold.last.end, 24);
    });

    test('styleResolver paints stock specs without PlaygroundSpec', () {
      final block = Block(
        id: 'b',
        type: 'paragraph',
        runs: [
          InlineRun('bold', attributes: const <String, Object?>{'bold': true}),
          InlineRun('code', attributes: const <String, Object?>{'code': true}),
        ],
      );
      final source = ParagraphSource<TextStyle>.build(
        block: block,
        decorations: sheet.decorationsFor(block),
        resolveStyle: sheet.styleResolver(base),
      );

      final styles = source.segments
          .whereType<TextSegment<TextStyle>>()
          .map((segment) => segment.style)
          .toList();
      expect(styles, isNotEmpty);
      expect(
        styles.any((style) => style.fontWeight == FontWeight.bold),
        isTrue,
      );
      expect(
        styles.any((style) => style.fontFamily == 'monospace'),
        isTrue,
      );
    });

    test('applyStockAttribute covers bold italic and code', () {
      expect(
        sheet
            .applyStockAttribute(base, HomericStockAttributeKind.italic)
            .fontStyle,
        FontStyle.italic,
      );
      expect(
        sheet
            .applyStockAttribute(base, HomericStockAttributeKind.code)
            .backgroundColor,
        isNotNull,
      );
    });

    test('ignores foreign decoration specs when resolving', () {
      final block = Block(
        id: 'b',
        type: 'paragraph',
        runs: [InlineRun('x')],
      );
      final source = ParagraphSource<TextStyle>.build(
        block: block,
        decorations: [
          Decoration.inline('b', 0, 1, spec: 'foreign'),
        ],
        resolveStyle: sheet.styleResolver(base),
      );
      final style =
          source.segments.whereType<TextSegment<TextStyle>>().single.style;
      expect(style.fontWeight, base.fontWeight);
      expect(style.fontStyle, base.fontStyle);
      expect(style.fontFamily, base.fontFamily);
    });
  });
}
