import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

void main() {
  group('HomericSelection', () {
    test('preserves collapsed, forward, and reverse direction', () {
      const collapsed = HomericSelection.collapsed(4);
      const forward = HomericSelection(anchor: 2, head: 7);
      const reverse = HomericSelection(
        anchor: 7,
        head: 2,
        affinity: HomericCaretAffinity.upstream,
      );

      expect(collapsed.isCollapsed, isTrue);
      expect(collapsed.start, 4);
      expect(collapsed.end, 4);
      expect(forward.isForward, isTrue);
      expect(forward.start, 2);
      expect(forward.end, 7);
      expect(reverse.isForward, isFalse);
      expect(reverse.start, 2);
      expect(reverse.end, 7);
      expect(reverse.affinity, HomericCaretAffinity.upstream);
    });

    test('rejects negative endpoints', () {
      expect(
        () => HomericSelection(anchor: -1, head: 0),
        throwsAssertionError,
      );
      expect(
        () => HomericSelection(anchor: 0, head: -1),
        throwsAssertionError,
      );
    });

    test('maps endpoints without losing reverse direction or affinity', () {
      final tx = Transaction(_document('abcd'))..insertText(3, 'XY');
      const selection = HomericSelection(
        anchor: 5,
        head: 2,
        affinity: HomericCaretAffinity.upstream,
      );

      final mapped = selection.map(tx.mapping);

      expect(mapped.anchor, 7);
      expect(mapped.head, 2);
      expect(mapped.isForward, isFalse);
      expect(mapped.affinity, HomericCaretAffinity.upstream);
    });

    test('collapsed mapping follows inserted content', () {
      final tx = Transaction(_document('abcd'))..insertText(3, 'XY');

      expect(
        const HomericSelection.collapsed(3).map(tx.mapping),
        const HomericSelection.collapsed(5),
      );
    });

    test('collapsed text range stays collapsed when mapped over insertion', () {
      final tx = Transaction(_document('abcd'))..insertText(3, 'XY');

      expect(HomericTextRange(3, 3).map(tx.mapping), HomericTextRange(5, 5));
    });
  });
}

Document _document(String text) => Document([
      Block(id: 'p', type: 'paragraph', runs: [InlineRun(text)]),
    ]);
