import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

import '../transform/transform_test_utils.dart';

void main() {
  group('MarkdownMarkHideSpec', () {
    test('markdownMarkHideReplacement tags hide decorations', () {
      final hide = markdownMarkHideReplacement('b', 0, 2);
      expect(isMarkdownMarkHideDecoration(hide), isTrue);
      expect(
        isMarkdownMarkHideDecoration(
          Decoration.replace('b', 0, 2, replacementLength: 0, spec: 'hide'),
        ),
        isFalse,
        reason: 'untyped hide specs are not markdown mark hides',
      );
    });

    test('non-zero replace decorations are not markdown mark hides', () {
      expect(
        isMarkdownMarkHideDecoration(
          Decoration.replace(
            'b',
            0,
            3,
            replacementLength: 2,
            spec: MarkdownMarkHideSpec.instance,
          ),
        ),
        isFalse,
      );
    });
  });

  group('RevealState.forMarkdownMarkVisibility', () {
    final block = para('b', '**bold**');
    final lead = markdownMarkHideReplacement('b', 0, 2);
    final trail = markdownMarkHideReplacement('b', 6, 8);
    final decorations = [lead, trail];

    test('livePreview passes selection reveal through', () {
      final selectionReveal = RevealState.of([lead]);
      final reveal = RevealState.forMarkdownMarkVisibility(
        visibility: MarkdownMarkVisibility.livePreview,
        decorations: decorations,
        selectionReveal: selectionReveal,
      );
      expect(reveal.isRevealed(lead), isTrue);
      expect(reveal.isRevealed(trail), isFalse);
    });

    test('sourceVisible permanently reveals every markdown hide', () {
      final reveal = RevealState.forMarkdownMarkVisibility(
        visibility: MarkdownMarkVisibility.sourceVisible,
        decorations: decorations,
      );
      expect(reveal.isRevealed(lead), isTrue);
      expect(reveal.isRevealed(trail), isTrue);
    });

    test('sourceVisible keeps literal marks in view text', () {
      final decorations = [
        markdownMarkHideReplacement('b', 0, 2),
        markdownMarkHideReplacement('b', 6, 8),
        Decoration.inline('b', 2, 6, spec: 'bold'),
      ];
      final live = deriveViewText(block, decorations);
      expect(live.viewText, 'bold');

      final revealed = RevealState.forMarkdownMarkVisibility(
        visibility: MarkdownMarkVisibility.sourceVisible,
        decorations: decorations,
      );
      final visible = [
        for (final decoration in decorations)
          if (decoration.kind != DecorationKind.replace ||
              !revealed.isRevealed(decoration))
            decoration,
      ];
      expect(deriveViewText(block, visible).viewText, '**bold**');
    });
  });
}
