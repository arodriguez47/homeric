import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/writing.dart';

Block _block(String text, {String id = 'b'}) =>
    Block(id: id, type: 'paragraph', runs: [InlineRun(text)]);

void main() {
  group('footnote numbering', () {
    test('numbers inline and reference footnotes in reading order', () {
      final numbers = homericNumberFootnotes([
        (id: 'a', text: 'One[^x] and two^[inline]'),
        (id: 'b', text: 'Again[^x], then[^y].'),
        (id: 'c', text: '[^x]: The x note'),
        (id: 'd', text: '[^y]: Why'),
      ]);
      expect(numbers[homericFootnoteRefKey('x')]!.number, 1);
      expect(numbers[homericFootnoteRefKey('x')]!.text, 'The x note');
      expect(numbers[homericInlineFootnoteKey('a', 15)]!.number, 2);
      expect(numbers[homericInlineFootnoteKey('a', 15)]!.text, 'inline');
      expect(numbers[homericFootnoteRefKey('y')]!.number, 3);
      expect(numbers, hasLength(3));
    });

    test('a definition is not a reference, and needs one to be numbered', () {
      final numbers =
          homericNumberFootnotes([(id: 'a', text: '[^lonely]: hi')]);
      expect(numbers, isEmpty);
    });

    test('definitions in soft lines of one block are found', () {
      final numbers = homericNumberFootnotes([
        (id: 'a', text: 'Body[^n]\n[^n]: soft-line note'),
      ]);
      expect(numbers[homericFootnoteRefKey('n')]!.text, 'soft-line note');
    });
  });

  group('homericStripMarks', () {
    test('folds the layer away for previews and titles', () {
      expect(
        homericStripMarks(
          'Quiet ++aside++ day.^[note] See {{the orchard|why}}[^1].\n'
          '%% private line\n'
          '~~old~~ new\n'
          '[^1]: the note',
        ),
        'Quiet day. See the orchard.\nold new',
      );
    });

    test('leaves ordinary text alone', () {
      for (final plain in [
        'Price is 3^2 [x] and {a} 100% sure',
        'Meeting : agenda',
        'Is it ? yes',
        'C++ vs C++ talk',
        'Use `[^0-9]` in code',
      ]) {
        expect(homericStripMarks(plain), plain);
      }
    });

    test('marks inside an annotation passage strip with it', () {
      expect(homericStripMarks('See {{a ++b++}} now'), 'See a now');
      expect(homericStripMarks('{{a^[n]}} x'), 'a x');
      expect(homericStripMarks('{{a ~~b~~ c|why}}'), 'a b c');
    });
  });

  group('decorations', () {
    List<Decoration> derive(String text) =>
        HomericSyntax.all.decorationsFor(_block(text)).toList();

    test('plain text derives no layer decorations', () {
      final ds = derive('Just a sentence with 50% and a {brace}.');
      expect(ds.where((d) => d.spec is HomericFootnoteSpec), isEmpty);
      expect(ds.where((d) => d.spec is HomericAnnotationNoteSpec), isEmpty);
      expect(ds.where(isMarkdownMarkHideDecoration), isEmpty);
    });

    test('a footnote folds its note into a marker slot', () {
      final ds = derive('Word^[the note #tag] more');
      final hide = ds.where(isMarkdownMarkHideDecoration).single;
      expect((hide.start, hide.end), (4, 20));
      final slot = ds.singleWhere((d) => d.spec is HomericFootnoteSpec);
      expect(slot.start, 4);
      // The folded #tag does not paint a pill where the note used to be.
      expect(
        ds.where(
          (d) =>
              d.spec is HomericMarkSpec &&
              (d.spec as HomericMarkSpec).kind == HomericMarkKind.tag,
        ),
        isEmpty,
      );
    });

    test('a heading stays a heading around an annotation and footnote', () {
      const text = '# The {{orchard walk|Every Sunday}} today^[a note]';
      final heading = derive(text)
          .where(
            (d) =>
                d.spec is HomericMarkSpec &&
                (d.spec as HomericMarkSpec).kind == HomericMarkKind.heading,
          )
          .map((d) => text.substring(d.start, d.end))
          .join();
      expect(heading, 'The {{orchard walk today');
    });

    test('an annotation marks its passage and carries its note', () {
      final ds = derive('See {{the orchard|why here}} now');
      final passage = ds.singleWhere(
        (d) =>
            d.spec is HomericMarkSpec &&
            (d.spec as HomericMarkSpec).kind == HomericMarkKind.annotation,
      );
      expect((passage.start, passage.end), (6, 17));
      final note = ds.singleWhere((d) => d.spec is HomericAnnotationNoteSpec);
      expect((note.spec as HomericAnnotationNoteSpec).note, 'why here');
    });

    test('a comment line hides its sigil and mutes the line', () {
      final ds = derive('%% to myself');
      expect(
        ds.where(isMarkdownMarkHideDecoration).map((d) => (d.start, d.end)),
        [(0, 3)],
      );
      expect(
        ds.any(
          (d) =>
              d.spec is HomericMarkSpec &&
              (d.spec as HomericMarkSpec).kind == HomericMarkKind.comment,
        ),
        isTrue,
      );
    });
  });

  group('drop cap', () {
    List<Decoration> derive(String text, {int? caret}) =>
        HomericSyntax.all.decorationsFor(_block(text), caret: caret).toList();
    Iterable<Decoration> caps(List<Decoration> ds) => ds.where(
          (d) =>
              d.spec is HomericMarkSpec &&
              (d.spec as HomericMarkSpec).kind == HomericMarkKind.dropCap,
        );

    test('^^ hides and sets the first letter as the initial', () {
      final ds = derive('^^Once upon a time');
      expect(
        ds.where(isMarkdownMarkHideDecoration).map((d) => (d.start, d.end)),
        [(0, 2)],
      );
      final cap = caps(ds).single;
      expect((cap.start, cap.end), (2, 3));
    });

    test('the caret at the start shows the marker', () {
      final ds = derive('^^Once', caret: 1);
      expect(ds.where(isMarkdownMarkHideDecoration), isEmpty);
      expect(caps(ds), hasLength(1));
    });

    test('only a paragraph opening counts, before a letter or digit', () {
      expect(caps(derive('Mid ^^line')), isEmpty);
      expect(caps(derive('^^ spaced')), isEmpty);
      expect(caps(derive('^^[a footnote]')), isEmpty);
      expect(caps(derive('first\n^^second')), isEmpty);
      expect(caps(derive('^^1984 was')), hasLength(1));
    });

    test('previews and titles drop the marker', () {
      expect(homericStripMarks('^^Once upon a time'), 'Once upon a time');
      expect(homericStripMarks('Mid ^^line'), 'Mid ^^line');
      expect(homericStripMarks('Title\n\n^^Once'), 'Title\n\nOnce');
    });

    test('a soft-wrapped line or a passage keeps its ^^', () {
      expect(homericStripMarks('first\n^^second'), 'first\n^^second');
      expect(homericStripMarks('See {{^^second}} now'), 'See ^^second now');
    });

    test('the initial covers a whole astral or accented letter', () {
      for (final (text, length) in [('^^𐐀bc', 2), ('^^E\u0301tude', 2)]) {
        final cap = caps(derive(text)).single;
        expect((cap.start, cap.end), (2, 2 + length));
      }
    });
  });

  group('marks that meet', () {
    const inputs = [
      'C++ notes^[about C++]',
      '{{passage|see ^[x]}}',
      '{{passage|see [^1]}}',
      '{{passage|C++ and C++}}',
      '{{passage|~~old~~ new}}',
      '^[see {{this}}]',
      '^[a ++b++]',
      '^[a ~~b~~]',
      '^[^1]',
      '++a {{b|c++}}',
      '[[foo ~~bar~~]]',
      '[[foo ++bar++]]',
      '[[foo **bar**]]',
      '[[x|^[y]]]',
      '[link](http://a.com/~~x~~)',
      'a [label](^[x]) b',
      '`a^[b]` and `{{x}}`',
      '%% note^[x] and {{y|z}}',
      '**a ==b** c==',
      'line one\n%% c ~~x~~\n[^1]: b',
    ];
    for (final input in inputs) {
      test('"$input" lays out', () {
        final block = _block(input);
        expect(
          () => deriveViewText(block, HomericSyntax.all.decorationsFor(block)),
          returnsNormally,
        );
      });
    }

    test('nothing in code, wiki links or comment lines is layer syntax', () {
      final numbers = homericNumberFootnotes([
        (id: 'a', text: '`x^[y]` [[n|^[z]]] and [^1] here'),
        (id: 'b', text: '%% aside^[w] [^2]'),
        (id: 'c', text: '{{p|note [^3]}} then ^[real]'),
      ]);
      expect(numbers.keys,
          [homericFootnoteRefKey('1'), homericInlineFootnoteKey('c', 21)]);
    });
  });
}
