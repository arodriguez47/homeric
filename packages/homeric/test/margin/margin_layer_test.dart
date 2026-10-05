import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' hide Decoration;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/margin.dart';

const _viewportHeight = 300.0;
const _editorWidth = 400.0;
const _layerWidth = 700.0;
const _marginLeft = 420.0;
const _noteWidth = 200.0;
const _line = 20.0;

void main() {
  group('tracking (AE1)', () {
    testWidgets('a note sits beside its range after the first layout',
        (tester) async {
      final harness =
          _Harness(_document(['alpha beta gamma', 'delta epsilon']));
      harness.host.notes = [
        _note('n1', 'block-1', const BlockTextRange(6, 13)),
      ];
      await harness.pump(tester);

      final rect = harness.noteRect(tester, 'n1');
      expect(
          rect.top, harness.rangeTop('block-1', const BlockTextRange(6, 13)));
      expect(rect.left, _marginLeft);
      expect(rect.width, _noteWidth);
      expect(find.text('full n1'), findsOneWidget);
      expect(find.text('compact n1'), findsNothing);
    });

    testWidgets('a note tracks its line in the frame of a scroll',
        (tester) async {
      final harness = _Harness(
        _document([for (var index = 0; index < 12; index++) 'row $index']),
      );
      harness.host.notes = [
        _note('n5', 'block-5', const BlockTextRange(0, 3)),
      ];
      await harness.pump(tester);
      final before = harness.noteRect(tester, 'n5');

      harness.scrollController.jumpTo(37);
      await tester.pump();

      final after = harness.noteRect(tester, 'n5');
      expect(after.top, before.top - 37);
      expect(
          after.top, harness.rangeTop('block-5', const BlockTextRange(0, 3)));
    });

    testWidgets('a note follows a body font-size change one frame later',
        (tester) async {
      final harness = _Harness(_document([
        'alpha beta gamma delta epsilon zeta eta theta',
        'iota kappa lambda mu nu xi omicron pi rho sigma',
      ]));
      const range = BlockTextRange(30, 35);
      harness.host.notes = [_note('n1', 'block-1', range)];
      await harness.pump(tester);
      final before = harness.noteRect(tester, 'n1').top;

      harness.fontSize.value = 20;
      await tester.pump();
      await tester.pump();

      final after = harness.noteRect(tester, 'n1').top;
      expect(after, harness.rangeTop('block-1', range));
      expect(after, isNot(before), reason: 'the line moved');
    });

    testWidgets('an inserted block above moves the note in the edit frame',
        (tester) async {
      final harness = _Harness(_document(['first', 'second', 'third']));
      const range = BlockTextRange(0, 5);
      harness.host.notes = [_note('n', 'block-2', range)];
      await harness.pump(tester);
      final before = harness.noteRect(tester, 'n').top;

      harness.controller.setSelection(HomericSelection.collapsed(
        harness.controller.document.positionAt(0, 5),
      ));
      expect(harness.controller.insertParagraphBreak(), isTrue);
      await tester.pump();

      final after = harness.noteRect(tester, 'n').top;
      expect(after, greaterThan(before));
      expect(after, harness.rangeTop('block-2', range));
    });

    testWidgets(
        'a host rebuild in the edit frame keeps notes on their lines while '
        'geometry is pending', (tester) async {
      final harness = _Harness(_document(['first', 'second', 'third']));
      const range = BlockTextRange(0, 5);
      harness.host.notes = [
        _note('a', 'block-1', const BlockTextRange(0, 6)),
        _note('b', 'block-2', range),
      ];
      await harness.pump(tester);

      harness.controller.setSelection(HomericSelection.collapsed(
        harness.controller.document.positionAt(0, 5),
      ));
      expect(harness.controller.insertParagraphBreak(), isTrue);
      harness.host.notes = [...harness.host.notes];
      await tester.pump();

      expect(harness.noteRect(tester, 'a').top,
          harness.rangeTop('block-1', const BlockTextRange(0, 6)));
      expect(harness.noteRect(tester, 'b').top,
          harness.rangeTop('block-2', range));
      await tester.pump();
      expect(harness.noteRect(tester, 'b').top,
          harness.rangeTop('block-2', range));
    });

    testWidgets('a hidden range anchors to its start caret', (tester) async {
      final harness = _Harness(_document(['abcdefgh']));
      harness.host.notes = [_note('n', 'block-0', const BlockTextRange(2, 5))];
      await harness.pump(
        tester,
        deriveDecorations: (block) => <Decoration>[
          Decoration.replace(block.id, 2, 5, replacementLength: 0),
        ],
      );

      final block = harness.state.documentGeometry.block('block-0')!;
      expect(block.rectsForRange(const BlockTextRange(2, 5)), isEmpty);
      expect(harness.noteRect(tester, 'n').top,
          block.globalOrigin!.dy + block.caretRect(2)!.top);
    });

    testWidgets(
        'a GlobalKey layer re-parented under a transform inside a layout '
        'callback keeps its notes on their lines', (tester) async {
      final harness = _Harness(_document(['alpha beta gamma', 'delta']));
      const range = BlockTextRange(6, 10);
      harness.host.notes = [_note('n', 'block-0', range)];
      await harness.pump(tester);
      final before = harness.noteRect(tester, 'n');

      harness.transformed.value = true;
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(harness.noteRect(tester, 'n'), before);
      await tester.pump();
      expect(harness.noteRect(tester, 'n'), before);
      expect(harness.noteRect(tester, 'n').top,
          harness.rangeTop('block-0', range));

      harness.transformed.value = false;
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pump();
      expect(harness.noteRect(tester, 'n'), before);
    });

    testWidgets(
        'notes stay beside their lines when a transform scales the editor '
        'and the layer together', (tester) async {
      final harness = _Harness(_document(['alpha beta gamma', 'delta']))
        ..transformScale = 0.5;
      const range = BlockTextRange(6, 10);
      harness.host.notes = [_note('n', 'block-0', range)];
      await harness.pump(tester);

      harness.transformed.value = true;
      await tester.pump();
      expect(tester.takeException(), isNull);

      void expectBesideLine() {
        final block = harness.state.documentGeometry.block('block-0')!;
        final layer = tester.getRect(find.byType(HomericMarginLayer));
        final note = harness.noteRect(tester, 'n');
        expect(note.left, layer.left + _marginLeft * 0.5);
        expect(note.width, _noteWidth * 0.5);
        expect(note.top,
            block.globalOrigin!.dy + block.rectsForRange(range)!.first.top / 2);
      }

      expectBesideLine();
      await tester.pump();
      expectBesideLine();
    });

    testWidgets('a layer added after the editor settled still places notes',
        (tester) async {
      final harness = _Harness(_document(['alpha', 'beta']));
      harness.host.notes = [_note('n', 'block-1', const BlockTextRange(0, 4))];
      await harness.pump(tester, withLayer: false);
      harness.showLayer.value = true;
      await tester.pump();
      await tester.pump();

      expect(harness.noteRect(tester, 'n').top,
          harness.rangeTop('block-1', const BlockTextRange(0, 4)));
    });
  });

  group('mounting', () {
    testWidgets('a note for an unmounted block is built once it scrolls in',
        (tester) async {
      final harness = _Harness(
        _document([for (var index = 0; index < 60; index++) 'row $index']),
      );
      harness.host.notes = [
        _note('far', 'block-40', const BlockTextRange(0, 3)),
      ];
      await harness.pump(tester, cacheExtent: 0);
      expect(harness.state.documentGeometry.mountedBlockIds,
          isNot(contains('block-40')));
      expect(_noteFinder('far'), findsNothing);
      expect(find.text('full far', skipOffstage: false), findsNothing,
          reason: 'unmounted notes are not even measured');

      // Estimated row heights make the target offset unknowable up front;
      // scroll down until the row mounts.
      for (var step = 0;
          step < 40 &&
              !harness.state.documentGeometry.mountedBlockIds!
                  .contains('block-40');
          step++) {
        harness.scrollController
            .jumpTo(harness.scrollController.offset + _viewportHeight / 2);
        await tester.pump();
        await tester.pump();
      }
      expect(
          harness.state.documentGeometry.mountedBlockIds, contains('block-40'));
      await tester.pump();
      expect(_noteFinder('far'), findsOneWidget);
      expect(harness.noteRect(tester, 'far').top,
          harness.rangeTop('block-40', const BlockTextRange(0, 3)));
    });

    testWidgets(
        'a neighbour mounting below does not change an on-screen note, '
        'though a fresh solve would compact it', (tester) async {
      final harness = _Harness(
        _document([for (var index = 0; index < 60; index++) 'row $index']),
      );
      await harness.pump(tester, cacheExtent: 0);
      final mounted = harness.state.documentGeometry.mountedBlockIds!;
      // The lowest mounted row straddles the viewport bottom; the next one
      // is not mounted.
      final aId = mounted.last;
      final aIndex = int.parse(aId.split('-').last);
      final bId = 'block-${aIndex + 1}';
      const range = BlockTextRange(0, 3);
      harness.host.notes = [
        _note('a', aId, range, fullHeight: 100),
        _note('b', bId, range),
      ];
      await tester.pump();
      await tester.pump();
      expect(find.text('full a'), findsOneWidget);
      final aBlockTop = harness.blockTop(aId);
      final aBefore = harness.noteRect(tester, 'a');
      expect(aBefore.top, lessThan(_viewportHeight), reason: 'on screen');
      final rowPitch = aBlockTop - harness.blockTop('block-${aIndex - 1}');

      harness.scrollController
          .jumpTo(aBlockTop + rowPitch - _viewportHeight + 2);
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(harness.state.documentGeometry.mountedBlockIds, contains(bId));
      final shift = aBlockTop - harness.blockTop(aId);
      expect(find.text('full a'), findsOneWidget);
      expect(harness.noteRect(tester, 'a'), aBefore.shift(Offset(0, -shift)));
      final b = harness.noteRect(tester, 'b');
      expect(b.top, greaterThanOrEqualTo(aBefore.bottom - shift + 8));
      expect(_connectorFinder('b'), findsOneWidget);

      // The rule matters: solved from scratch, A would turn compact because
      // its full note ends below B's anchor.
      final fresh = solveMarginLayout([
        MarginBlockInput(blockId: aId, top: 0, notes: [
          MarginNoteInput(
            id: 'a',
            anchorTop: aBefore.top,
            rangeStart: 0,
            fullHeight: 100,
            compactHeight: _line,
          ),
        ]),
        MarginBlockInput(blockId: bId, top: 0, notes: [
          MarginNoteInput(
            id: 'b',
            anchorTop: harness.rangeTop(bId, range) + shift,
            rangeStart: 0,
            fullHeight: _line,
            compactHeight: _line,
          ),
        ]),
      ], lineHeight: _line);
      expect(fresh.first.form, MarginNoteForm.compact);

      // Scrolling back unmounts B; A still does not move relative to its
      // block.
      harness.scrollController.jumpTo(0);
      await tester.pump();
      await tester.pump();
      expect(
          harness.state.documentGeometry.mountedBlockIds, isNot(contains(bId)));
      expect(harness.noteRect(tester, 'a'), aBefore);
    });

    testWidgets(
        'a cascading neighbour unmounting above does not move the notes it '
        'pushed', (tester) async {
      final harness = _Harness(
        _document([for (var index = 0; index < 60; index++) 'row $index']),
      );
      const range = BlockTextRange(0, 3);
      harness.host.notes = [
        for (var index = 0; index < 4; index++)
          _note('c$index', 'block-0', BlockTextRange(index, index + 1),
              fullHeight: 100),
        _note('d', 'block-1', range),
      ];
      await harness.pump(tester, cacheExtent: 0);
      expect(find.text('compact c0'), findsOneWidget, reason: 'crowded');
      expect(find.text('compact d'), findsOneWidget,
          reason: 'pushed more than two lines');
      final dBefore = harness.noteRect(tester, 'd');
      final dOffset = dBefore.top - harness.blockTop('block-1');
      expect(dBefore.top,
          greaterThan(harness.rangeTop('block-1', range) + 2 * _line),
          reason: 'pushed down by the compact stack above');

      final pitch = harness.blockTop('block-1') - harness.blockTop('block-0');
      harness.scrollController.jumpTo(pitch + 1);
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(harness.state.documentGeometry.mountedBlockIds,
          isNot(contains('block-0')));
      expect(find.text('compact d'), findsOneWidget);
      expect(harness.noteRect(tester, 'd').top - harness.blockTop('block-1'),
          dOffset);

      harness.scrollController.jumpTo(0);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(harness.noteRect(tester, 'd'), dBefore);
      expect(find.text('compact c0'), findsOneWidget);
    });

    testWidgets('notes on a block deleted by an edit disappear',
        (tester) async {
      final harness = _Harness(_document(['first', 'second']));
      harness.host.notes = [_note('n', 'block-1', const BlockTextRange(0, 3))];
      await harness.pump(tester);
      expect(_noteFinder('n'), findsOneWidget);

      harness.controller.setSelection(HomericSelection.collapsed(
        harness.controller.document.positionAt(1, 0),
      ));
      expect(harness.controller.deleteBackward(), isTrue);
      await tester.pump();
      await tester.pump();

      expect(harness.controller.document.indexOfBlockId('block-1'), isNull);
      expect(_noteFinder('n'), findsNothing);
    });
  });

  group('crowding (AE2, AE3, AE4)', () {
    testWidgets('a displaced note paints a connector to its anchor line',
        (tester) async {
      final harness = _Harness(_document(['alpha beta gamma']));
      harness.host.notes = [
        _note('n1', 'block-0', const BlockTextRange(0, 5), fullHeight: 30),
        _note('n2', 'block-0', const BlockTextRange(6, 10)),
      ];
      await harness.pump(tester);

      final n1 = harness.noteRect(tester, 'n1');
      final n2 = harness.noteRect(tester, 'n2');
      expect(find.text('full n2'), findsOneWidget);
      expect(n2.top, n1.bottom + 8);
      expect(_connectorFinder('n1'), findsNothing);
      expect(_connectorFinder('n2'), findsOneWidget);

      final block = harness.state.documentGeometry.block('block-0')!;
      final anchor = block.rectsForRange(const BlockTextRange(6, 10))!.first;
      final origin = block.globalOrigin!;
      // Painted in the margin's space: x from the margin's left edge, y from
      // the block's top.
      expect(
        _connectorFinder('n2'),
        paints
          ..line(
            p1: Offset(-2, n2.top - origin.dy + _line / 2),
            p2: Offset(
              origin.dx + block.blockRect!.right - _marginLeft,
              anchor.center.dy,
            ),
          ),
      );
      final end = origin.dy + anchor.center.dy;
      expect(end,
          inInclusiveRange(origin.dy + anchor.top, origin.dy + anchor.bottom));
    });

    testWidgets('a crowded paragraph compacts; expanding one note moves none',
        (tester) async {
      final harness = _Harness(_document(['alpha beta gamma', 'delta', 'eta']));
      harness.host.notes = [
        _note('a', 'block-0', const BlockTextRange(0, 5), fullHeight: 60),
        _note('b', 'block-0', const BlockTextRange(6, 10), fullHeight: 60),
        _note('c', 'block-2', const BlockTextRange(0, 3)),
      ];
      await harness.pump(tester);
      expect(find.text('compact a'), findsOneWidget);
      expect(find.text('compact b'), findsOneWidget);
      expect(find.text('full c'), findsOneWidget);
      final a = harness.noteRect(tester, 'a');
      final c = harness.noteRect(tester, 'c');
      expect(a.height, _line);

      harness.host.expanded = 'b';
      await tester.pump();
      expect(find.text('compact b'), findsNothing);
      expect(find.text('full b'), findsOneWidget);
      final card = tester.getRect(_expandedFinder('b'));
      expect(card.height, 60 + 16);
      expect(harness.noteRect(tester, 'a'), a);
      expect(harness.noteRect(tester, 'c'), c);
      await tester.pump();
      expect(harness.noteRect(tester, 'a'), a);
      expect(harness.noteRect(tester, 'c'), c);
      expect(tester.getRect(_expandedFinder('b')), card);

      harness.host.expanded = null;
      await tester.pump();
      await tester.pump();
      expect(find.text('compact b'), findsOneWidget);
      expect(harness.noteRect(tester, 'a'), a);
      expect(harness.noteRect(tester, 'c'), c);
    });

    testWidgets('a three-line note beside a one-line block stays full',
        (tester) async {
      final harness = _Harness(_document(['short']));
      harness.host.notes = [
        _note('n', 'block-0', const BlockTextRange(0, 5), fullHeight: 60),
      ];
      await harness.pump(tester);
      expect(find.text('full n'), findsOneWidget);
      expect(harness.noteRect(tester, 'n').height, 60);
    });

    testWidgets('an oversized note compacts and expands to its full height',
        (tester) async {
      final harness = _Harness(_document(['short']));
      harness.host.notes = [
        _note('n', 'block-0', const BlockTextRange(0, 5), fullHeight: 200),
      ];
      await harness.pump(tester);
      expect(find.text('compact n'), findsOneWidget);

      harness.host.expanded = 'n';
      await tester.pump();
      expect(tester.getRect(_expandedFinder('n')).height, 200 + 16);
    });
  });

  group('expansion and the viewport', () {
    testWidgets('an expanded note near the bottom is clamped inside',
        (tester) async {
      final harness = _Harness(
        _document([for (var index = 0; index < 30; index++) 'row $index']),
      );
      await harness.pump(tester);
      final mounted = harness.state.documentGeometry.mountedBlockIds!;
      final near = mounted.lastWhere(
        (id) => harness.blockTop(id) < _viewportHeight - 30,
      );
      harness.host.notes = [
        _note('n', near, const BlockTextRange(0, 3), fullHeight: 200),
      ];
      await tester.pump();
      await tester.pump();
      final resting = harness.noteRect(tester, 'n');
      expect(resting.top, greaterThan(_viewportHeight - 60));

      harness.host.expanded = 'n';
      await tester.pump();

      final card = tester.getRect(_expandedFinder('n'));
      expect(card.height, 216);
      expect(card.bottom, _viewportHeight - 8);
      expect(card.top, greaterThanOrEqualTo(8));
      expect(card.left, _marginLeft - 8);
    });

    testWidgets('an expanded note taller than the viewport scrolls inside',
        (tester) async {
      final harness = _Harness(_document(['alpha', 'beta']));
      harness.host.notes = [
        HomericMarginNote(
          id: 'long',
          blockId: 'block-0',
          range: const BlockTextRange(0, 5),
          fullBuilder: (context) => Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (var line = 0; line < 30; line++)
                SizedBox(height: _line, child: Text('line $line')),
            ],
          ),
          compactBuilder: (context) => const Text('long'),
        ),
      ];
      await harness.pump(tester);
      harness.host.expanded = 'long';
      await tester.pump();

      final card = tester.getRect(_expandedFinder('long'));
      expect(card.top, greaterThanOrEqualTo(8));
      expect(card.bottom, lessThanOrEqualTo(_viewportHeight - 8));
      expect(card.height, _viewportHeight - 16);
      expect(find.text('line 29'), findsOneWidget);
      expect(tester.getRect(find.text('line 29')).top, greaterThan(card.bottom),
          reason: 'initially clipped');

      await tester.drag(_expandedFinder('long'), const Offset(0, -800));
      await tester.pumpAndSettle();

      final last = tester.getRect(find.text('line 29'));
      expect(last.bottom, lessThanOrEqualTo(card.bottom));
      expect(last.top, greaterThanOrEqualTo(card.top));
      expect(tester.getRect(_expandedFinder('long')), card);
    });

    testWidgets('the keyboard inset shrinks and lifts an expanded note',
        (tester) async {
      final harness = _Harness(_document(['alpha', 'beta']));
      harness.host.notes = [
        _note('n', 'block-0', const BlockTextRange(0, 5), fullHeight: 200),
      ];
      harness.viewInsets = const EdgeInsets.only(bottom: 400);
      await harness.pump(tester);
      harness.host.expanded = 'n';
      await tester.pump();

      // The 600 px screen leaves 200 px above the keyboard; the layer spans
      // 0..300, so the bottom 100 px are covered.
      final card = tester.getRect(_expandedFinder('n'));
      expect(card.bottom, lessThanOrEqualTo(200 - 8));
      expect(card.height, lessThanOrEqualTo(_viewportHeight - 16 - 400 + 300));
    });
  });

  group('interaction (R14)', () {
    testWidgets('Escape and an outside tap both dismiss; focus returns',
        (tester) async {
      final harness = _Harness(_document(['alpha beta gamma', 'delta']),
          selection: const HomericSelection.collapsed(2));
      harness.host.notes = [
        _note('a', 'block-0', const BlockTextRange(0, 5), fullHeight: 60),
        _note('b', 'block-0', const BlockTextRange(6, 10), fullHeight: 60),
      ];
      await harness.pump(tester);
      harness.blockFocus['block-0']!.requestFocus();
      await tester.pump();
      final editorFocus = harness.blockFocus['block-0']!;
      expect(editorFocus.hasPrimaryFocus, isTrue);

      await tester.tap(_targetFinder('b'));
      expect(harness.host.activated, ['b']);
      harness.host.expanded = 'b';
      await tester.pump();
      await tester.pump();
      expect(harness.layer.focusedNoteId, 'b');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(harness.host.dismissed, 1);

      // Empty margin space is outside the expanded note.
      await tester.tapAt(const Offset(_layerWidth - 10, _viewportHeight - 10));
      expect(harness.host.dismissed, 2);

      harness.host.expanded = null;
      await tester.pump();
      await tester.pump();
      expect(find.text('compact b'), findsOneWidget);
      expect(editorFocus.hasPrimaryFocus, isTrue);
      expect(harness.controller.selection, const HomericSelection.collapsed(2));
    });

    testWidgets('keyboard expansion returns focus to the note', (tester) async {
      final harness = _Harness(_document(['alpha beta gamma']));
      harness.host.notes = [
        _note('a', 'block-0', const BlockTextRange(0, 5), fullHeight: 200),
      ];
      await harness.pump(tester);
      expect(harness.layer.focusNote('a'), isTrue);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(harness.host.activated, ['a']);
      harness.host.expanded = 'a';
      await tester.pump();
      await tester.pump();
      expect(harness.layer.focusedNoteId, 'a');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(harness.host.dismissed, 1);
      harness.host.expanded = null;
      await tester.pump();
      await tester.pump();
      expect(harness.layer.focusedNoteId, 'a');
    });

    testWidgets('Escape does nothing while nothing is open', (tester) async {
      final harness = _Harness(_document(['alpha']));
      harness.host.notes = [_note('a', 'block-0', const BlockTextRange(0, 5))];
      await harness.pump(tester);
      harness.layer.focusNote('a');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.tapAt(const Offset(_layerWidth - 10, _viewportHeight - 10));
      expect(harness.host.dismissed, 0);
    });

    testWidgets('Tab follows document order; Enter, Space and touch activate',
        (tester) async {
      final harness = _Harness(_document(['one', 'two', 'three', 'four']));
      harness.host.notes = [
        // Supplied out of order on purpose.
        _note('n3', 'block-3', const BlockTextRange(0, 4)),
        _note('n0', 'block-0', const BlockTextRange(0, 3)),
        _note('n2', 'block-2', const BlockTextRange(0, 5)),
      ];
      await harness.pump(tester);
      expect(harness.layer.focusNote('n0'), isTrue);
      await tester.pump();
      expect(harness.layer.focusedNoteId, 'n0');

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(harness.layer.focusedNoteId, 'n2');
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(harness.layer.focusedNoteId, 'n3');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(harness.host.activated, ['n3', 'n3']);

      final gesture = await tester.startGesture(
        tester.getCenter(_noteFinder('n0')),
        kind: PointerDeviceKind.touch,
      );
      await gesture.up();
      expect(harness.host.activated, ['n3', 'n3', 'n0']);
    });

    testWidgets('notes carry button semantics and their labels',
        (tester) async {
      final semantics = tester.ensureSemantics();
      final harness = _Harness(_document(['alpha']));
      harness.host.notes = [
        _note('a', 'block-0', const BlockTextRange(0, 5), label: 'Note: hi'),
      ];
      await harness.pump(tester);

      expect(
        tester.getSemantics(find.byKey(_shellLabelKey('a'))),
        matchesSemantics(
          label: 'Note: hi',
          isButton: true,
          isFocusable: true,
          hasTapAction: true,
          hasExpandedState: true,
        ),
      );
      semantics.dispose();
    });

    testWidgets('programmatic focus keeps the editor selection',
        (tester) async {
      final harness = _Harness(_document(['alpha beta', 'gamma']),
          selection: const HomericSelection(anchor: 1, head: 4));
      harness.host.notes = [_note('a', 'block-1', const BlockTextRange(0, 5))];
      await harness.pump(tester);
      harness.blockFocus['block-0']!.requestFocus();
      await tester.pump();
      final selection = harness.controller.selection;

      expect(harness.layer.focusNote('a'), isTrue);
      await tester.pump();

      expect(harness.layer.focusedNoteId, 'a');
      expect(FocusManager.instance.primaryFocus,
          isNot(harness.blockFocus['block-0']));
      expect(harness.controller.selection, selection);
      expect(harness.layer.focusNote('missing'), isFalse);
    });

    testWidgets('a composer takes focus and returns it to the editor',
        (tester) async {
      final harness = _Harness(_document(['alpha beta', 'gamma']),
          selection: const HomericSelection(anchor: 6, head: 10));
      final field = FocusNode(debugLabel: 'composer field');
      addTearDown(field.dispose);
      await harness.pump(tester);
      final editorFocus = harness.blockFocus['block-0']!..requestFocus();
      await tester.pump();
      final selection = harness.controller.selection;

      harness.host.composer = HomericMarginComposer(
        blockId: 'block-1',
        range: const BlockTextRange(0, 5),
        semanticsLabel: 'New note',
        builder: (context) => Focus(
          focusNode: field,
          autofocus: true,
          child: const SizedBox(height: 40, child: Text('composing')),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(field.hasPrimaryFocus, isTrue);
      expect(harness.controller.selection, selection);
      final composer = tester.getRect(
          find.byKey(const ValueKey<String>('homeric-margin-composer')));
      expect(composer.top + 8,
          harness.rangeTop('block-1', const BlockTextRange(0, 5)),
          reason: 'the content sits where a resting note would');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(harness.host.dismissed, 1);
      harness.host.composer = null;
      await tester.pump();
      await tester.pump();

      expect(editorFocus.hasPrimaryFocus, isTrue);
      expect(harness.controller.selection, selection);
    });

    testWidgets('a composer without its own focus target focuses its scope',
        (tester) async {
      final harness = _Harness(_document(['alpha beta']));
      await harness.pump(tester);
      harness.host.composer = HomericMarginComposer(
        blockId: 'block-0',
        range: const BlockTextRange(0, 5),
        builder: (context) => const Text('composing'),
      );
      await tester.pump();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, isA<FocusScopeNode>());
      expect(
        FocusManager.instance.primaryFocus!.context!
            .findAncestorWidgetOfExactType<HomericMarginLayer>(),
        isNotNull,
      );
    });

    testWidgets(
        'a swapped-in composer takes focus; removal returns it to the editor',
        (tester) async {
      final harness = _Harness(_document(['alpha beta', 'gamma']),
          selection: const HomericSelection(anchor: 1, head: 4));
      final fieldA = FocusNode(debugLabel: 'composer field a');
      final fieldB = FocusNode(debugLabel: 'composer field b');
      addTearDown(fieldA.dispose);
      addTearDown(fieldB.dispose);
      final disposed = <String>[];
      HomericMarginComposer composer(
        String name,
        BlockTextRange range,
        FocusNode field,
      ) =>
          HomericMarginComposer(
            blockId: 'block-0',
            range: range,
            builder: (context) => _DisposeProbe(
              onDispose: () => disposed.add(name),
              child: Focus(
                focusNode: field,
                autofocus: true,
                child: SizedBox(height: 40, child: Text('composing $name')),
              ),
            ),
          );
      await harness.pump(tester);
      final editorFocus = harness.blockFocus['block-0']!..requestFocus();
      await tester.pump();
      final selection = harness.controller.selection;

      harness.host.composer = composer('a', const BlockTextRange(0, 5), fieldA);
      await tester.pump();
      await tester.pump();
      expect(fieldA.hasPrimaryFocus, isTrue);

      // The same composer supplied again keeps its state.
      harness.host.composer = composer('a', const BlockTextRange(0, 5), fieldA);
      await tester.pump();
      await tester.pump();
      expect(disposed, isEmpty);
      expect(fieldA.hasPrimaryFocus, isTrue);

      harness.host.composer =
          composer('b', const BlockTextRange(6, 10), fieldB);
      await tester.pump();
      await tester.pump();
      expect(disposed, ['a'], reason: 'the previous composer is built fresh');
      expect(find.text('composing a'), findsNothing);
      expect(fieldB.hasPrimaryFocus, isTrue);

      harness.host.composer = null;
      await tester.pump();
      await tester.pump();
      expect(disposed, ['a', 'b']);
      expect(editorFocus.hasPrimaryFocus, isTrue,
          reason: 'focus returns to where it was before the first composer');
      expect(harness.controller.selection, selection);
    });

    testWidgets('a composer with a new id is swapped even on the same range',
        (tester) async {
      final harness = _Harness(_document(['alpha beta']));
      final field = FocusNode(debugLabel: 'composer field');
      addTearDown(field.dispose);
      final disposed = <String>[];
      HomericMarginComposer composer(String id) => HomericMarginComposer(
            id: id,
            blockId: 'block-0',
            range: const BlockTextRange(0, 5),
            builder: (context) => _DisposeProbe(
              onDispose: () => disposed.add(id),
              child: Focus(
                focusNode: field,
                autofocus: true,
                child: Text('composing $id'),
              ),
            ),
          );
      await harness.pump(tester);
      harness.host.composer = composer('new');
      await tester.pump();
      await tester.pump();
      expect(field.hasPrimaryFocus, isTrue);

      harness.host.composer = composer('edit');
      await tester.pump();
      await tester.pump();
      expect(disposed, ['new']);
      expect(field.hasPrimaryFocus, isTrue);
    });

    testWidgets('tap targets reach 44 px and split between neighbours',
        (tester) async {
      final harness = _Harness(_document([
        'alpha beta gamma',
        for (var index = 0; index < 3; index++) 'filler $index',
        'lonely',
      ]));
      harness.host.notes = [
        _note('a', 'block-0', const BlockTextRange(0, 5), fullHeight: 60),
        _note('b', 'block-0', const BlockTextRange(6, 10), fullHeight: 60),
        _note('solo', 'block-4', const BlockTextRange(0, 6), fullHeight: 200),
      ];
      await harness.pump(tester);
      expect(find.text('compact solo'), findsOneWidget);

      final solo = harness.noteRect(tester, 'solo');
      final soloTarget = tester.getRect(_targetFinder('solo'));
      expect(soloTarget.height, greaterThanOrEqualTo(44));
      expect(soloTarget.top, lessThan(solo.top));
      expect(soloTarget.bottom, greaterThan(solo.bottom));
      expect(solo.top, harness.rangeTop('block-4', const BlockTextRange(0, 6)),
          reason: 'padding does not move the note');

      final a = harness.noteRect(tester, 'a');
      final b = harness.noteRect(tester, 'b');
      final aTarget = tester.getRect(_targetFinder('a'));
      final bTarget = tester.getRect(_targetFinder('b'));
      expect(aTarget.bottom, lessThanOrEqualTo(bTarget.top));
      expect(aTarget.bottom, (a.bottom + b.top) / 2);
      expect(aTarget.contains(a.center), isTrue);
      expect(bTarget.contains(b.center), isTrue);

      // A tap just above the visible preview still activates it.
      await tester.tapAt(Offset(solo.center.dx, solo.top - 8));
      expect(harness.host.activated, ['solo']);
    });

    testWidgets('empty margin space is transparent to pointers',
        (tester) async {
      final harness = _Harness(_document(['alpha beta']));
      harness.host.notes = [_note('a', 'block-0', const BlockTextRange(0, 5))];
      await harness.pump(tester);
      final result = HitTestResult();
      WidgetsBinding.instance.hitTestInView(
        result,
        const Offset(_marginLeft + 10, _viewportHeight - 20),
        tester.view.viewId,
      );
      expect(
        result.path.map((entry) => entry.target),
        isNot(contains(isA<RenderPointerListener>())),
        reason: 'no gesture target under empty margin space',
      );
    });
  });

  group('host queries', () {
    testWidgets('activation reports the resting form, which formOf shows',
        (tester) async {
      final harness = _Harness(_document(['alpha beta gamma', 'delta', 'eta']));
      harness.host.notes = [
        _note('a', 'block-0', const BlockTextRange(0, 5), fullHeight: 60),
        _note('b', 'block-0', const BlockTextRange(6, 10), fullHeight: 60),
        _note('c', 'block-2', const BlockTextRange(0, 3)),
      ];
      await harness.pump(tester);

      for (final id in ['a', 'b', 'c']) {
        final form = harness.layer.formOf(id);
        expect(find.text('${form!.name} $id'), findsOneWidget,
            reason: 'formOf($id) is what is painted');
      }
      expect(harness.layer.formOf('a'), MarginNoteForm.compact);
      expect(harness.layer.formOf('c'), MarginNoteForm.full);

      await tester.tap(_noteFinder('b'));
      await tester.tap(_noteFinder('c'));
      expect(harness.host.activated, ['b', 'c']);
      expect(harness.host.activatedForms,
          [MarginNoteForm.compact, MarginNoteForm.full]);
    });

    testWidgets('an expanded compact note still reports its resting form',
        (tester) async {
      final harness = _Harness(_document(['alpha beta gamma', 'delta']));
      harness.host.notes = [
        _note('a', 'block-0', const BlockTextRange(0, 5), fullHeight: 60),
        _note('b', 'block-0', const BlockTextRange(6, 10), fullHeight: 60),
      ];
      await harness.pump(tester);
      expect(harness.layer.formOf('b'), MarginNoteForm.compact);

      harness.host.expanded = 'b';
      await tester.pump();
      await tester.pump();
      expect(find.text('full b'), findsOneWidget);
      expect(harness.layer.formOf('b'), MarginNoteForm.compact);
      expect(harness.layer.focusedNoteId, 'b');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(harness.host.activated, ['b']);
      expect(harness.host.activatedForms, [MarginNoteForm.compact]);
    });

    testWidgets('a click on an expanded note activates it in its resting form',
        (tester) async {
      final harness = _Harness(_document(['alpha beta gamma', 'delta']));
      harness.host.notes = [
        _note('a', 'block-0', const BlockTextRange(0, 5), fullHeight: 60),
        _note('b', 'block-0', const BlockTextRange(6, 10), fullHeight: 60),
      ];
      await harness.pump(tester);
      harness.host.expanded = 'b';
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('full b'), kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(harness.host.activated, ['b']);
      expect(harness.host.activatedForms, [MarginNoteForm.compact]);
      expect(harness.host.dismissed, 0, reason: 'a tap inside is not outside');
    });

    testWidgets('a touch tap on an expanded note activates it', (tester) async {
      final harness = _Harness(_document(['alpha beta gamma', 'delta']));
      harness.host.notes = [
        _note('a', 'block-0', const BlockTextRange(0, 5), fullHeight: 60),
        _note('b', 'block-0', const BlockTextRange(6, 10), fullHeight: 60),
      ];
      await harness.pump(tester);
      harness.host.expanded = 'b';
      await tester.pump();
      await tester.pump();

      // No hover precedes a touch.
      final gesture = await tester.startGesture(
        tester.getCenter(_expandedFinder('b')),
        kind: PointerDeviceKind.touch,
      );
      await gesture.up();
      await tester.pump();
      expect(harness.host.activated, ['b']);
      expect(harness.host.activatedForms, [MarginNoteForm.compact]);
      expect(harness.host.dismissed, 0);
    });

    testWidgets('dragging inside a tall expanded note scrolls, not activates',
        (tester) async {
      final harness = _Harness(_document(['alpha', 'beta']));
      harness.host.notes = [
        HomericMarginNote(
          id: 'long',
          blockId: 'block-0',
          range: const BlockTextRange(0, 5),
          fullBuilder: (context) => Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (var line = 0; line < 30; line++)
                SizedBox(height: _line, child: Text('line $line')),
            ],
          ),
          compactBuilder: (context) => const Text('long'),
        ),
      ];
      await harness.pump(tester);
      harness.host.expanded = 'long';
      await tester.pump();
      await tester.pump();
      final card = tester.getRect(_expandedFinder('long'));
      final before = tester.getRect(find.text('line 29')).top;

      final gesture =
          await tester.startGesture(card.center, kind: PointerDeviceKind.touch);
      // A real drag arrives as many moves; the first only crosses the slop.
      for (var step = 0; step < 10; step++) {
        await gesture.moveBy(const Offset(0, -20));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();

      expect(tester.getRect(find.text('line 29')).top, lessThan(before));
      expect(harness.host.activated, isEmpty);
      expect(harness.host.dismissed, 0);
    });

    testWidgets('a button inside an expanded note receives its own tap',
        (tester) async {
      final harness = _Harness(_document(['alpha beta gamma']));
      var pressed = 0;
      harness.host.notes = [
        HomericMarginNote(
          id: 'n',
          blockId: 'block-0',
          range: const BlockTextRange(0, 5),
          fullBuilder: (context) => Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(height: 40, child: Text('body')),
              GestureDetector(
                key: const ValueKey<String>('inner-button'),
                onTap: () => pressed++,
                child: const SizedBox(height: 20, child: Text('Edit')),
              ),
            ],
          ),
          compactBuilder: (context) => const Text('n'),
        ),
      ];
      await harness.pump(tester);
      harness.host.expanded = 'n';
      await tester.pump();
      await tester.pump();

      final button = find.descendant(
        of: _expandedFinder('n'),
        matching: find.byKey(const ValueKey<String>('inner-button')),
      );
      await tester.tap(button);
      await tester.pump();
      expect(pressed, 1);
      expect(harness.host.activated, isEmpty);
      expect(harness.host.dismissed, 0);
    });

    testWidgets('focusNote and formOf answer only for placed notes',
        (tester) async {
      final harness = _Harness(
        _document([for (var index = 0; index < 60; index++) 'row $index']),
      );
      harness.host.notes = [
        _note('near', 'block-0', const BlockTextRange(0, 3)),
        _note('far', 'block-40', const BlockTextRange(0, 3)),
        _note('bad', 'block-1', const BlockTextRange(1, 40)),
      ];
      await harness.pump(tester, cacheExtent: 0);
      expect(harness.layer.formOf('near'), MarginNoteForm.full);
      for (final id in ['far', 'bad', 'missing']) {
        expect(harness.layer.formOf(id), isNull, reason: id);
        expect(harness.layer.focusNote(id), isFalse, reason: id);
      }

      // Added in this frame: not placed until the layer lays out.
      harness.host.notes = [
        ...harness.host.notes,
        _note('new', 'block-2', const BlockTextRange(0, 3)),
      ];
      expect(harness.layer.focusNote('new'), isFalse);
      await tester.pump();
      expect(harness.layer.formOf('new'), MarginNoteForm.full);
      expect(harness.layer.focusNote('new'), isTrue);
      await tester.pump();
      expect(harness.layer.focusedNoteId, 'new');

      // A note that was placed and focused, whose block then unmounts.
      harness.scrollController.jumpTo(1000);
      await tester.pump();
      await tester.pump();
      expect(harness.state.documentGeometry.mountedBlockIds,
          isNot(contains('block-0')));
      expect(harness.layer.formOf('near'), isNull);
      expect(harness.layer.focusNote('near'), isFalse);
      expect(tester.takeException(), isNull);
    });
  });

  group('source indicators', () {
    testWidgets(
        'flagged ranges are underlined, the active one tinted, and prose '
        'taps pass through', (tester) async {
      final harness = _Harness(_document(['alpha beta gamma', 'delta']));
      const range = BlockTextRange(6, 10);
      harness.host.notes = [
        _note('a', 'block-0', range, indicator: true),
        _note('b', 'block-1', const BlockTextRange(0, 5)),
      ];
      await harness.pump(tester);
      final rect = harness.state.documentGeometry
          .block('block-0')!
          .rectsForRange(range)!
          .single;
      const underline = Color(0x804A6FA5);
      const tint = Color(0x264A6FA5);

      expect(
        _sourceFinder('block-0'),
        paints
          ..rect(
            rect: Rect.fromLTRB(
                rect.left, rect.bottom - 1, rect.right, rect.bottom),
            color: underline,
          ),
      );
      expect(_sourceFinder('block-1'), findsNothing,
          reason: 'unflagged and inactive');

      harness.layer.focusNote('a');
      await tester.pump();
      await tester.pump();
      expect(
        _sourceFinder('block-0'),
        paints
          ..rect(rect: rect, color: tint)
          ..rect(color: underline),
      );
      harness.layer.focusNote('b');
      await tester.pump();
      await tester.pump();
      expect(_sourceFinder('block-1'), paints..rect(color: tint));

      final global = harness.rangeFirstLine('block-0', range);
      await tester.tapAt(global.center);
      await tester.pump();
      expect(harness.host.activated, isEmpty);
      expect(harness.controller.selection!.isCollapsed, isTrue);
      expect(harness.blockFocus['block-0']!.hasFocus, isTrue,
          reason: 'the editor received the tap');
    });
  });

  group('layout neutrality', () {
    testWidgets('twenty notes leave the paragraph width and lines unchanged',
        (tester) async {
      const text = 'one two three four five six seven eight nine ten eleven '
          'twelve thirteen fourteen fifteen sixteen';
      final harness = _Harness(_document([text, 'tail']));
      await harness.pump(tester);
      final paragraph = find.byKey(const ValueKey<String>(
        'homeric-editable-block-0',
      ));
      final width = tester.getSize(paragraph).width;
      final lines = harness.state.documentGeometry
          .block('block-0')!
          .rectsForRange(const BlockTextRange(0, text.length))!
          .length;
      expect(lines, greaterThan(1));

      harness.host.notes = [
        for (var index = 0; index < 20; index++)
          _note(
              'n$index', 'block-${index % 2}', BlockTextRange(index, index + 2),
              fullHeight: 40),
      ];
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const ValueKey<String>('homeric-margin-note-n0')),
          findsOneWidget);
      expect(tester.getSize(paragraph).width, width);
      expect(
        harness.state.documentGeometry
            .block('block-0')!
            .rectsForRange(const BlockTextRange(0, text.length))!
            .length,
        lines,
      );
    });

    testWidgets('a note whose range is outside its block is not built',
        (tester) async {
      final harness = _Harness(_document(['abc']));
      harness.host.notes = [
        _note('bad', 'block-0', const BlockTextRange(1, 40)),
        _note('gone', 'missing', const BlockTextRange(0, 1)),
        _note('ok', 'block-0', const BlockTextRange(0, 1)),
      ];
      await harness.pump(tester);
      expect(_noteFinder('bad'), findsNothing);
      expect(_noteFinder('gone'), findsNothing);
      expect(_noteFinder('ok'), findsOneWidget);
    });

    testWidgets('a note whose content grows is re-measured', (tester) async {
      final height = ValueNotifier<double>(_line);
      addTearDown(height.dispose);
      final harness = _Harness(_document(['alpha']));
      harness.host.notes = [
        HomericMarginNote(
          id: 'g',
          blockId: 'block-0',
          range: const BlockTextRange(0, 5),
          fullBuilder: (context) => ValueListenableBuilder<double>(
            valueListenable: height,
            builder: (context, value, _) => SizedBox(height: value),
          ),
          compactBuilder: (context) => const Text('g'),
        ),
      ];
      await harness.pump(tester);
      expect(harness.noteRect(tester, 'g').height, _line);

      height.value = 3 * _line;
      await tester.pump();
      expect(harness.noteRect(tester, 'g').height, 3 * _line);
    });
  });
}

Finder _noteFinder(String id) =>
    find.byKey(ValueKey<String>('homeric-margin-note-$id'));

Finder _targetFinder(String id) =>
    find.byKey(ValueKey<String>('homeric-margin-target-$id'));

Finder _connectorFinder(String id) =>
    find.byKey(ValueKey<String>('homeric-margin-connector-$id'));

Finder _expandedFinder(String id) =>
    find.byKey(ValueKey<String>('homeric-margin-expanded-$id'));

Finder _sourceFinder(String blockId) =>
    find.byKey(ValueKey<String>('homeric-margin-source-$blockId'));

ValueKey<String> _shellLabelKey(String id) =>
    ValueKey<String>('homeric-margin-target-$id');

/// Reports when the composer subtree it sits in is disposed.
class _DisposeProbe extends StatefulWidget {
  const _DisposeProbe({required this.onDispose, required this.child});

  final VoidCallback onDispose;
  final Widget child;

  @override
  State<_DisposeProbe> createState() => _DisposeProbeState();
}

class _DisposeProbeState extends State<_DisposeProbe> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

// ---------------------------------------------------------------------------
// Harness.

final class _Host extends ChangeNotifier {
  List<HomericMarginNote> _notes = const [];
  List<HomericMarginNote> get notes => _notes;
  set notes(List<HomericMarginNote> value) {
    _notes = value;
    notifyListeners();
  }

  String? _expanded;
  String? get expanded => _expanded;
  set expanded(String? value) {
    _expanded = value;
    notifyListeners();
  }

  HomericMarginComposer? _composer;
  HomericMarginComposer? get composer => _composer;
  set composer(HomericMarginComposer? value) {
    _composer = value;
    notifyListeners();
  }

  final List<String> activated = [];
  final List<MarginNoteForm> activatedForms = [];
  int dismissed = 0;
}

final class _Harness {
  _Harness(Document document, {HomericSelection? selection})
      : controller =
            HomericEditorController(document: document, selection: selection) {
    session = HomericTextInputSession(controller: controller);
  }

  final HomericEditorController controller;
  late final HomericTextInputSession session;
  final ScrollController scrollController = ScrollController();
  final GlobalKey<HomericEditableDocumentState> documentKey =
      GlobalKey<HomericEditableDocumentState>();
  final GlobalKey<HomericMarginLayerState> layerKey =
      GlobalKey<HomericMarginLayerState>();
  final _Host host = _Host();
  final ValueNotifier<double> fontSize = ValueNotifier<double>(14);
  final Map<String, FocusNode> blockFocus = {};
  final ValueNotifier<bool> showLayer = ValueNotifier<bool>(true);

  /// Wraps the editor and the layer in a [Transform], as a host's page
  /// transition does, re-parenting both inside a layout callback.
  final ValueNotifier<bool> transformed = ValueNotifier<bool>(false);
  double transformScale = 1;
  EdgeInsets viewInsets = EdgeInsets.zero;

  HomericEditableDocumentState get state => documentKey.currentState!;
  HomericMarginLayerState get layer => layerKey.currentState!;

  Future<void> pump(
    WidgetTester tester, {
    double cacheExtent = 250,
    double lineHeight = _line,
    bool withLayer = true,
    List<Decoration> Function(Block block)? deriveDecorations,
  }) async {
    showLayer.value = withLayer;
    addTearDown(() {
      showLayer.dispose();
      transformed.dispose();
      host.dispose();
      fontSize.dispose();
      scrollController.dispose();
      session.dispose();
      controller.dispose();
    });
    final editor = Positioned(
      left: 0,
      top: 0,
      width: _editorWidth,
      height: _viewportHeight,
      child: ValueListenableBuilder<double>(
        valueListenable: fontSize,
        builder: (context, size, _) => HomericEditableDocument.builder(
          key: documentKey,
          controller: controller,
          inputSession: session,
          scrollController: scrollController,
          cacheExtent: cacheExtent,
          estimatedBlockHeight: 44,
          blockBuilder: (context, block, focusNode) {
            blockFocus[block.id] = focusNode;
            return HomericEditableParagraph(
              controller: controller,
              inputSession: session,
              blockId: block.id,
              focusNode: focusNode,
              resolveStyle: (_) => TextStyle(fontSize: size),
              deriveDecorations: deriveDecorations,
            );
          },
        ),
      ),
    );
    final layer = Positioned(
      left: 0,
      top: 0,
      width: _layerWidth,
      height: _viewportHeight,
      child: ValueListenableBuilder<bool>(
        valueListenable: showLayer,
        builder: (context, show, _) => !show
            ? const SizedBox.shrink()
            : ListenableBuilder(
                listenable: host,
                builder: (context, _) => HomericMarginLayer(
                  key: layerKey,
                  documentKey: documentKey,
                  notes: host.notes,
                  marginLeft: _marginLeft,
                  noteWidth: _noteWidth,
                  lineHeight: lineHeight,
                  expandedNoteId: host.expanded,
                  composer: host.composer,
                  onNoteActivated: (id, form) {
                    host.activated.add(id);
                    host.activatedForms.add(form);
                  },
                  onDismissed: () => host.dismissed++,
                ),
              ),
      ),
    );
    await tester.pumpWidget(_app(
      ValueListenableBuilder<bool>(
        valueListenable: transformed,
        builder: (context, transform, _) => LayoutBuilder(
          builder: (context, constraints) {
            final stack = Stack(children: <Widget>[
              // Stands in for the host's page background, which receives
              // taps on empty margin space.
              const Positioned.fill(
                child: ColoredBox(color: Color(0xFFFFFFFF)),
              ),
              editor,
              layer,
            ]);
            return transform
                ? Transform.scale(scale: transformScale, child: stack)
                : stack;
          },
        ),
      ),
      viewInsets: viewInsets,
    ));
    // First layout publishes geometry post-frame; the layer solves next.
    await tester.pump();
    await tester.pump();
  }

  /// Global top of [range]'s first line, from the public geometry.
  double rangeTop(String blockId, BlockTextRange range) {
    final block = state.documentGeometry.block(blockId)!;
    return block.globalOrigin!.dy + block.rectsForRange(range)!.first.top;
  }

  Rect rangeFirstLine(String blockId, BlockTextRange range) {
    final block = state.documentGeometry.block(blockId)!;
    return block.rectsForRange(range)!.first.shift(block.globalOrigin!);
  }

  /// Global top of a mounted block's link origin.
  double blockTop(String blockId) =>
      state.documentGeometry.block(blockId)!.globalOrigin!.dy;

  Rect noteRect(WidgetTester tester, String id) =>
      tester.getRect(find.byKey(ValueKey<String>('homeric-margin-note-$id')));
}

HomericMarginNote _note(
  String id,
  String blockId,
  BlockTextRange range, {
  double fullHeight = _line,
  bool indicator = false,
  String? label,
}) =>
    HomericMarginNote(
      id: id,
      blockId: blockId,
      range: range,
      semanticsLabel: label,
      paintSourceIndicator: indicator,
      fullBuilder: (context) => SizedBox(
        height: fullHeight,
        child: Text('full $id'),
      ),
      compactBuilder: (context) => Text(
        'compact $id',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );

Widget _app(Widget child, {EdgeInsets viewInsets = EdgeInsets.zero}) =>
    MediaQuery(
      data: MediaQueryData(size: const Size(800, 600), viewInsets: viewInsets),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Localizations(
          locale: const Locale('en'),
          delegates: const <LocalizationsDelegate<dynamic>>[
            DefaultWidgetsLocalizations.delegate,
          ],
          child: Shortcuts(
            shortcuts: WidgetsApp.defaultShortcuts,
            child: Actions(
              actions: WidgetsApp.defaultActions,
              child: TapRegionSurface(
                child: Overlay(
                  initialEntries: <OverlayEntry>[
                    OverlayEntry(builder: (_) => child),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

Block _block(String id, String text) => Block(
      id: id,
      type: 'paragraph',
      runs: <InlineRun>[InlineRun(text)],
    );

Document _document(List<String> texts) => Document(<Block>[
      for (var index = 0; index < texts.length; index++)
        _block('block-$index', texts[index]),
    ]);
