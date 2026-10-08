import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

void main() {
  group('HomericBlockAttributes', () {
    test('mirror builder writes sourceId and sourceType', () {
      final attrs = HomericBlockAttributes.mirror(
        sourceId: 'note_9',
        sourceType: 'note',
        extra: const <String, Object?>{'keep': true},
      );
      expect(attrs['keep'], isTrue);
      expect(HomericBlockAttributes.isMirror(attrs), isTrue);
      expect(HomericBlockAttributes.sourceIdOf(attrs), 'note_9');
      expect(HomericBlockAttributes.sourceTypeOf(attrs), 'note');
      final bag = HomericBlockAttributes.mirrorOf(attrs)!;
      expect(bag[HomericBlockAttributes.sourceIdKey], 'note_9');
    });

    test('non-mirror bags return null helpers', () {
      expect(HomericBlockAttributes.isMirror(emptyAttributes), isFalse);
      expect(HomericBlockAttributes.sourceIdOf(emptyAttributes), isNull);
    });
  });

  group('homericMirrorSourceAffordance', () {
    test('emits a widget decoration for mirrored blocks only', () {
      final mirrored = Block(
        id: 'b',
        type: 'paragraph',
        attributes: HomericBlockAttributes.mirror(
          sourceId: 'src',
          sourceType: 'card',
        ),
        runs: [InlineRun('mirrored')],
      );
      final decoration = homericMirrorSourceAffordance(mirrored)!;
      expect(decoration.kind, DecorationKind.widget);
      expect(decoration.start, 0);
      expect(decoration.end, 0);
      expect(decoration.spec, isA<HomericMirrorSourceSpec>());

      final plain = Block(id: 'p', type: 'paragraph', runs: [InlineRun('x')]);
      expect(homericMirrorSourceAffordance(plain), isNull);
    });
  });
}
