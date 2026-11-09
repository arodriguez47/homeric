import 'dart:ui' show Color;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/writing.dart';

Block _p(String id, String text) =>
    Block(id: id, type: 'paragraph', runs: [InlineRun(text)]);

Block _h(String id, String text, int level) => Block(
      id: id,
      type: 'heading',
      attributes: {'level': level},
      runs: [InlineRun(text)],
    );

void main() {
  const ink = Color(0xFF2B2420);
  const paper = Color(0xFFFBF7F0);

  final doc = Document([
    _p('intro', 'Before any heading.'),
    _h('h1', 'Chapter', 1),
    _p('a', 'Under the chapter.'),
    _h('h2', 'Part', 2),
    _p('b', 'Under the part.'),
    _p('c', 'Still under the part.'),
    _h('h2b', 'Another part', 2),
    _p('d', 'Under another part.'),
    _h('h1b', 'Next chapter', 1),
    _p('e', 'Under the next chapter.'),
  ]);

  group('homericHeadingSection', () {
    test('runs from the heading above to the next of its level or above', () {
      expect(homericHeadingSection(doc, 'b'), {'h2', 'b', 'c'});
      expect(homericHeadingSection(doc, 'd'), {'h2b', 'd'});
    });

    test('a heading holds its whole section, nested ones included', () {
      expect(homericHeadingSection(doc, 'h1'), {
        'h1', 'a', 'h2', 'b', 'c', 'h2b', 'd', //
      });
      expect(homericHeadingSection(doc, 'a'), contains('h2b'));
    });

    test('above the first heading, the section is what comes before it', () {
      expect(homericHeadingSection(doc, 'intro'), {'intro'});
    });

    test('the last section runs to the end', () {
      expect(homericHeadingSection(doc, 'e'), {'h1b', 'e'});
    });

    test('ATX headings typed in the text count too', () {
      final typed = Document([
        _p('x', 'Intro'),
        _p('m', '## Mission'),
        _p('y', 'A home for clear thinking.'),
        _p('t', '## Things missing'),
        _p('z', '- [ ] An undo button.'),
        _p('q', '#hashtag is not a heading'),
      ]);
      expect(homericHeadingSection(typed, 'y'), {'m', 'y'});
      expect(homericHeadingSection(typed, 'z'), {'t', 'z', 'q'});
    });

    test('an unknown block has no section', () {
      expect(homericHeadingSection(doc, 'nope'), isEmpty);
    });
  });

  test('section comes after sentence in the cycle, then off', () {
    expect(
      HomericFocusGranularity.sentence.next,
      HomericFocusGranularity.section,
    );
    expect(HomericFocusGranularity.section.next, HomericFocusGranularity.off);
  });

  testWidgets('section focus keeps the caret\'s section bright', (
    tester,
  ) async {
    final editor = HomericEditorController(
      document: doc,
      selection: HomericSelection.collapsed(doc.positionAt(4, 3)),
    );
    addTearDown(editor.dispose);
    final controller = HomericFocusDimController(
      vsync: const TestVSync(),
      initialGranularity: HomericFocusGranularity.section,
    );
    addTearDown(controller.dispose);
    bool dimmed(String id) => controller
        .paintLayersFor(
          block: doc.blocks[doc.indexOfBlockId(id)!],
          editor: editor,
          foregroundColor: ink,
          backgroundColor: paper,
        )
        .isNotEmpty;

    for (final id in ['h2', 'b', 'c']) {
      expect(dimmed(id), isFalse, reason: id);
    }
    for (final id in ['intro', 'h1', 'a', 'h2b', 'd', 'h1b', 'e']) {
      expect(dimmed(id), isTrue, reason: id);
    }

    // The caret moves to another section: the bright part follows.
    editor.setSelection(HomericSelection.collapsed(doc.positionAt(9, 0)));
    expect(dimmed('e'), isFalse);
    expect(dimmed('h1b'), isFalse);
    expect(dimmed('b'), isTrue);
  });

  testWidgets('the host can say what a section is', (tester) async {
    final editor = HomericEditorController(
      document: doc,
      selection: HomericSelection.collapsed(doc.positionAt(4, 0)),
    );
    addTearDown(editor.dispose);
    final controller = HomericFocusDimController(
      vsync: const TestVSync(),
      initialGranularity: HomericFocusGranularity.section,
      sectionOf: (document, id) => {id, 'e'},
    );
    addTearDown(controller.dispose);
    bool dimmed(String id) => controller
        .paintLayersFor(
          block: doc.blocks[doc.indexOfBlockId(id)!],
          editor: editor,
          foregroundColor: ink,
          backgroundColor: paper,
        )
        .isNotEmpty;
    expect(dimmed('b'), isFalse);
    expect(dimmed('e'), isFalse);
    expect(dimmed('c'), isTrue);
  });

  testWidgets('a second editor gets its own section, not the first one\'s', (
    tester,
  ) async {
    final other = Document([
      _h('x1', 'Other', 1),
      _p('x', 'Under other.'),
      _h('y1', 'Elsewhere', 1),
      _p('y', 'Under elsewhere.'),
    ]);
    // Same revision (0) and the same caret offset in both.
    final first = HomericEditorController(
      document: doc,
      selection: HomericSelection.collapsed(doc.positionAt(0, 1)),
    );
    final second = HomericEditorController(
      document: other,
      selection: HomericSelection.collapsed(other.positionAt(0, 1)),
    );
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final controller = HomericFocusDimController(
      vsync: const TestVSync(),
      initialGranularity: HomericFocusGranularity.section,
    );
    addTearDown(controller.dispose);
    bool dimmed(HomericEditorController editor, String id) => controller
        .paintLayersFor(
          block: editor.document.blocks[editor.document.indexOfBlockId(id)!],
          editor: editor,
          foregroundColor: ink,
          backgroundColor: paper,
        )
        .isNotEmpty;
    expect(dimmed(first, 'intro'), isFalse);
    expect(dimmed(second, 'x1'), isFalse);
    expect(dimmed(second, 'x'), isFalse);
    expect(dimmed(second, 'y'), isTrue);
  });
}
