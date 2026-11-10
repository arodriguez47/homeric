// Text slots in an editable paragraph: a `replace` decoration whose spec is
// a HomericTextSlot draws hidden source as real words. These tests pin the
// words' caret stops, the spelling fence around them, and the gesture
// children `textSlotBuilder` lays over their ink.
//
// FlutterTest font: every glyph is a 14px square at fontSize 14.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

const _style = TextStyle(fontSize: 14);
const _spellingColor = Color(0xFFFF0000);

// 'see [[t|Label]] now': the wiki link's source folds and its label is
// drawn as [_words] (offsets: `[[t|` 4..8, `Label` 8..13, `]]` 13..15).
const _text = 'see [[t|Label]] now';

List<Decoration> _linkDecorations(String words) => <Decoration>[
      Decoration.replace('b', 4, 8, replacementLength: 0),
      Decoration.replace('b', 8, 13,
          replacementLength: words.length, spec: _TextSlot(words)),
      Decoration.replace('b', 13, 15, replacementLength: 0),
    ];

void main() {
  setUp(TextInputConnection.debugResetId);

  Future<HomericEditorController> pump(
    WidgetTester tester, {
    String words = 'Shown',
    double width = 300,
    bool readOnly = false,
    HomericTextSlotBuilder? textSlotBuilder,
    HomericSpellCheckProvider? spellCheckProvider,
    FocusNode? focusNode,
    int? caret,
    bool otherBlock = false,
    List<Decoration> Function()? decorations,
  }) async {
    final controller = HomericEditorController(
      document: Document([
        Block(id: 'b', type: 'paragraph', runs: [InlineRun(_text)]),
        if (otherBlock)
          Block(id: 'c', type: 'paragraph', runs: [InlineRun('other')]),
      ]),
      readOnly: readOnly,
    );
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    if (caret != null) {
      controller.setSelection(HomericSelection.collapsed(
          controller.globalPositionForBlockOffset('b', caret)));
    }
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: HomericEditableParagraph(
            controller: controller,
            inputSession: session,
            focusNode: focusNode,
            blockId: 'b',
            resolveStyle: (_) => _style,
            // A new spec each derivation, as a host whose words come from
            // live data builds them.
            deriveDecorations: (_) =>
                decorations?.call() ?? _linkDecorations(words),
            textSlotBuilder: textSlotBuilder,
            spellCheckProvider: spellCheckProvider,
            spellingColor: _spellingColor,
          ),
        ),
      ),
    ));
    await tester.pump();
    return controller;
  }

  ParagraphGeometry geometryOf(WidgetTester tester) => ParagraphGeometry(tester
      .renderObject<RenderHomericParagraph>(find.byType(HomericParagraph)));

  Offset originOf(WidgetTester tester) =>
      tester.getTopLeft(find.byType(HomericEditableParagraph));

  group('caret stops', () {
    testWidgets('step over the words in one move', (tester) async {
      await pump(tester);
      final geometry = geometryOf(tester);
      // Walk every stop from the start of the line to its end.
      final xs = <double>[];
      var stop = geometry.caretRect(const DocOffset(0)).value.left;
      xs.add(stop);
      var position = const DocOffset(0);
      var affinity = HomericCaretAffinity.downstream;
      for (var i = 0; i < 40; i++) {
        final moved = geometry
            .moveCaret(position,
                affinity: affinity, direction: CaretMovementDirection.right)
            .value;
        if (moved.position == position && moved.affinity == affinity) break;
        position = moved.position;
        affinity = moved.affinity;
        stop = moved.caretRect.left;
        xs.add(stop);
        expect(position.value <= 8 || position.value >= 13, isTrue,
            reason: 'stop at $position is inside the label');
      }
      expect(position.value, _text.length);
      // 'see ' is four glyphs and 'Shown' five more: no stop between.
      expect(xs.where((x) => x > 4 * 14.0 && x < 9 * 14.0), isEmpty);
      expect(xs, containsAll(<double>[4 * 14.0, 9 * 14.0]));
    });

    testWidgets('a tap on the words lands on an edge of the source',
        (tester) async {
      final controller = await pump(tester);
      // The middle of the second glyph of 'Shown'.
      await tester.tapAt(originOf(tester) + const Offset(5 * 14 + 7, 7));
      await tester.pump(const Duration(milliseconds: 500));
      final offset = controller.blockOffsetForGlobalPosition(
          'b', controller.selection!.head);
      expect(offset <= 8 || offset >= 13, isTrue,
          reason: 'the caret never stops inside the label ($offset)');
    });
  });

  group('spelling', () {
    Future<_FakeSpellProvider> pumpSpelling(WidgetTester tester) async {
      final provider = _FakeSpellProvider();
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      await pump(tester,
          words: 'Shwn', spellCheckProvider: provider, focusNode: focusNode);
      focusNode.requestFocus();
      await tester.pump();
      await tester.pump();
      return provider;
    }

    List<DocRange> squiggles(WidgetTester tester) => [
          for (final layer in tester
              .renderObject<RenderHomericParagraph>(
                  find.byType(HomericParagraph))
              .paintLayers)
            if (layer.spec case UnderlineSpec(color: _spellingColor))
              layer.range,
        ];

    testWidgets('never reads the words', (tester) async {
      final provider = await pumpSpelling(tester);
      expect(provider.requests.single.text, 'see ￼￼￼￼ now',
          reason: 'the words keep their length, so offsets keep mapping');
    });

    testWidgets('reports nothing inside the words', (tester) async {
      final provider = await pumpSpelling(tester);
      provider.complete(const <SuggestionSpan>[
        // A checker that reads the stand-ins anyway, or runs across them.
        SuggestionSpan(TextRange(start: 4, end: 8), <String>['Shown']),
        SuggestionSpan(TextRange(start: 2, end: 6), <String>['seen']),
        SuggestionSpan(TextRange(start: 7, end: 11), <String>['now']),
      ]);
      await tester.pump();
      await tester.pump();
      expect(squiggles(tester), isEmpty);
    });

    testWidgets('words either side still map to their own text',
        (tester) async {
      final provider = await pumpSpelling(tester);
      provider.complete(const <SuggestionSpan>[
        SuggestionSpan(TextRange(start: 0, end: 3), <String>['sea']),
        SuggestionSpan(TextRange(start: 9, end: 12), <String>['new']),
      ]);
      await tester.pump();
      await tester.pump();
      expect(squiggles(tester), [
        DocRange(const DocOffset(0), const DocOffset(3)),
        DocRange(const DocOffset(16), const DocOffset(19)),
      ]);
    });

    testWidgets('a word that runs into the words keeps off the source',
        (tester) async {
      final provider = await pumpSpelling(tester);
      // 'see' and the blanked words read as one run with no space.
      provider.complete(const <SuggestionSpan>[
        SuggestionSpan(TextRange(start: 1, end: 4), <String>['ee']),
        SuggestionSpan(TextRange(start: 8, end: 10), <String>['n']),
      ]);
      await tester.pump();
      await tester.pump();
      expect(
          squiggles(tester),
          [
            DocRange(const DocOffset(1), const DocOffset(4)),
            DocRange(const DocOffset(15), const DocOffset(17)),
          ],
          reason: 'neither fix may take in the hidden `[[t|` or `]]`');
    });
  });

  group('textSlotBuilder', () {
    Widget tapTarget(HomericTextSlotPiece piece, VoidCallback onTap) =>
        GestureDetector(
          key: ValueKey<String>('words-${piece.index}'),
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
        );

    testWidgets('a tap on the words reaches the child, not the caret',
        (tester) async {
      var taps = 0;
      final controller = await pump(
        tester,
        caret: 0,
        textSlotBuilder: (_, piece) => tapTarget(piece, () => taps++),
      );
      final before = controller.selection;

      await tester.tap(find.byKey(const ValueKey<String>('words-0')));
      await tester.pump(const Duration(milliseconds: 500));

      expect(taps, 1);
      expect(controller.selection, before);
    });

    testWidgets('a tap beside the words still moves the caret', (tester) async {
      var taps = 0;
      final controller = await pump(
        tester,
        caret: 0,
        textSlotBuilder: (_, piece) => tapTarget(piece, () => taps++),
      );

      // Just inside the 'w' of 'now', so the caret goes before it.
      await tester.tapAt(originOf(tester) + const Offset(12 * 14 + 2, 7));
      await tester.pump(const Duration(milliseconds: 500));

      expect(taps, 0);
      expect(
          controller.blockOffsetForGlobalPosition(
              'b', controller.selection!.head),
          18);
    });

    testWidgets('one piece covers the ink of words on one line',
        (tester) async {
      final pieces = <HomericTextSlotPiece>[];
      await pump(tester, textSlotBuilder: (_, piece) {
        pieces.add(piece);
        return null;
      });

      final piece = pieces.last;
      expect(pieces.every((p) => p.index == 0), isTrue);
      expect(piece.rects, hasLength(1));
      expect(piece.rect, piece.rects.single);
      expect(piece.rect.left, 4 * 14.0);
      expect(piece.rect.right, 9 * 14.0);
      expect(piece.range, const BlockTextRange(8, 13));
      expect(piece.textSlot, const _TextSlot('Shown'));
      expect(piece.decoration.kind, DecorationKind.replace);
    });

    testWidgets('words inserted where nothing was hidden get a piece too',
        (tester) async {
      final pieces = <HomericTextSlotPiece>[];
      // 'see ' then 'Hi' drawn at offset 4 with nothing folded under it.
      await pump(
        tester,
        decorations: () => <Decoration>[
          Decoration.replace('b', 4, 4,
              replacementLength: 2, spec: const _TextSlot('Hi')),
        ],
        textSlotBuilder: (_, piece) {
          pieces.add(piece);
          return null;
        },
      );

      expect(pieces, isNotEmpty);
      final piece = pieces.last;
      expect(piece.rects, hasLength(1));
      expect(piece.rect.left, 4 * 14.0);
      expect(piece.rect.right, 6 * 14.0);
      expect(piece.textSlot, const _TextSlot('Hi'));
    });

    testWidgets('wrapped words yield one piece per line', (tester) async {
      final built = <HomericTextSlotPiece>[];
      // Seven glyphs a line: 'see ' / 'Shown ' / 'words ' / 'now'.
      await pump(tester, words: 'Shown words', width: 7 * 14.0,
          textSlotBuilder: (_, piece) {
        built.add(piece);
        return KeyedSubtree(
          key: ValueKey<String>('words-${piece.index}'),
          child: const SizedBox.expand(),
        );
      });

      expect(find.byKey(const ValueKey<String>('words-0')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('words-1')), findsOneWidget);
      final last = built.sublist(built.length - 2);
      expect([for (final piece in last) piece.index], [0, 1]);
      final rects = last.first.rects;
      expect(rects, hasLength(2));
      expect(last.last.rects, rects);
      expect(rects[1].top, greaterThan(rects[0].top));
      final origin = originOf(tester);
      for (var i = 0; i < 2; i++) {
        expect(tester.getRect(find.byKey(ValueKey<String>('words-$i'))),
            rects[i].shift(origin));
      }
    });

    testWidgets('a text slot revealed by the caret offers no pieces',
        (tester) async {
      final pieces = <HomericTextSlotPiece>[];
      await pump(tester, caret: 10, textSlotBuilder: (_, piece) {
        pieces.add(piece);
        return const SizedBox.expand();
      });
      expect(pieces, isEmpty);
    });

    testWidgets('a tap survives a rebuild between down and up', (tester) async {
      var taps = 0;
      final controller = await pump(
        tester,
        caret: 0,
        textSlotBuilder: (_, piece) => tapTarget(piece, () => taps++),
      );
      final before = controller.selection;

      final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey<String>('words-0'))));
      // The host rebuilds the paragraph (a spelling answer, an autosave),
      // deriving a new, equal spec for the words.
      tester.element(find.byType(HomericEditableParagraph)).markNeedsBuild();
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 500));

      expect(taps, 1);
      expect(controller.selection, before);
    });

    testWidgets("a piece's State survives typing in another block",
        (tester) async {
      _Piece.inits = 0;
      final controller = await pump(
        tester,
        otherBlock: true,
        textSlotBuilder: (_, piece) => const _Piece(),
      );
      expect(_Piece.inits, 1);

      controller.setSelection(HomericSelection.collapsed(
          controller.globalPositionForBlockOffset('c', 5)));
      await tester.pump();
      controller.replaceSelection('x');
      await tester.pump();

      expect(controller.document.blocks.last.text, 'otherx');
      expect(_Piece.inits, 1);
    });

    testWidgets('works in a read-only paragraph', (tester) async {
      var taps = 0;
      final controller = await pump(
        tester,
        readOnly: true,
        textSlotBuilder: (_, piece) => tapTarget(piece, () => taps++),
      );

      await tester.tap(find.byKey(const ValueKey<String>('words-0')));
      await tester.pump(const Duration(milliseconds: 500));

      expect(taps, 1);
      expect(controller.selection, isNull);
    });
  });
}

final class _TextSlot implements HomericTextSlot {
  const _TextSlot(this.text);

  @override
  final String text;

  @override
  bool operator ==(Object other) => other is _TextSlot && other.text == text;

  @override
  int get hashCode => text.hashCode;
}

/// A text slot piece that counts how often its State is created.
class _Piece extends StatefulWidget {
  const _Piece();

  static int inits = 0;

  @override
  State<_Piece> createState() => _PieceState();
}

class _PieceState extends State<_Piece> {
  @override
  void initState() {
    super.initState();
    _Piece.inits++;
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

final class _FakeSpellProvider implements HomericSpellCheckProvider {
  final List<HomericSpellCheckRequest> requests = [];
  final List<Completer<List<SuggestionSpan>>> _pending = [];

  @override
  Future<List<SuggestionSpan>> check(HomericSpellCheckRequest request) {
    requests.add(request);
    final completer = Completer<List<SuggestionSpan>>();
    _pending.add(completer);
    return completer.future;
  }

  void complete(List<SuggestionSpan> suggestions) =>
      _pending.first.complete(suggestions);
}
