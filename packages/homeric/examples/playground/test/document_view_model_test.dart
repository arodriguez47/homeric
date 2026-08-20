// Playground integration: Phase 1 debug commands, public canonical editing,
// shared undo/decorations, and the lazy HomericEditableDocument viewport.

import 'package:flutter/material.dart'
    show ColoredBox, Colors, OutlinedButton, Size, Slider, SnackBar, Switch;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric_playground/decoration_spec.dart';
import 'package:homeric_playground/fixtures.dart';
import 'package:homeric_playground/main.dart';
import 'package:homeric_playground/view_models/document_view_model.dart';

/// Deep, value-level document equality. [Document]/[Block]/[InlineRun] use
/// identity equality by design (structural sharing relies on it), so undo
/// correctness has to be checked content-wise instead.
bool documentsEqual(Document a, Document b) {
  if (a.blockCount != b.blockCount) return false;
  for (var i = 0; i < a.blockCount; i++) {
    if (!_blocksEqual(a.blocks[i], b.blocks[i])) return false;
  }
  return true;
}

bool _blocksEqual(Block a, Block b) {
  if (a.id != b.id || a.type != b.type) return false;
  if (!attributesEqual(a.attributes, b.attributes)) return false;
  if (a.runs.length != b.runs.length) return false;
  for (var i = 0; i < a.runs.length; i++) {
    if (a.runs[i].text != b.runs[i].text) return false;
    if (!attributesEqual(a.runs[i].attributes, b.runs[i].attributes)) {
      return false;
    }
  }
  return true;
}

void _placeCaret(DocumentViewModel vm, int position) {
  expect(
    vm.editorController.relocateSelection(HomericSelection.collapsed(position)),
    isTrue,
  );
}

void main() {
  group('builder commands mutate and notify exactly once per transaction', () {
    late Document document;
    late DocumentViewModel vm;

    setUp(() {
      document = buildFixtureDocument();
      vm = DocumentViewModel(document: document);
    });

    test('insertTextAtCaret', () {
      _placeCaret(vm, document.positionAt(0, 0));
      var notifications = 0;
      vm.addListener(() => notifications++);
      final before = vm.document;
      expect(vm.insertTextAtCaret('Hi '), isTrue);
      expect(notifications, 1);
      expect(vm.document, isNot(same(before)));
      expect(vm.document.blocks.first.text, startsWith('Hi Homeric'));
    });

    test('deleteRange', () {
      var notifications = 0;
      vm.addListener(() => notifications++);
      expect(
          vm.deleteRange(document.positionAt(0, 0), document.positionAt(0, 2)),
          isTrue);
      expect(notifications, 1);
      expect(vm.document.blocks.first.text, isNot(startsWith('Ho')));
    });

    test('splitAtCaret', () {
      _placeCaret(vm, document.positionAt(0, 3));
      var notifications = 0;
      vm.addListener(() => notifications++);
      final blocksBefore = vm.document.blockCount;
      expect(vm.splitAtCaret(), isTrue);
      expect(notifications, 1);
      expect(vm.document.blockCount, blocksBefore + 1);
    });

    test('joinBlockWithNext (joinBlocks)', () {
      var notifications = 0;
      vm.addListener(() => notifications++);
      final blocksBefore = vm.document.blockCount;
      expect(vm.joinBlockWithNext('heading'), isTrue);
      expect(notifications, 1);
      expect(vm.document.blockCount, blocksBefore - 1);
    });

    test('moveBlock', () {
      var notifications = 0;
      vm.addListener(() => notifications++);
      expect(vm.moveBlockDown('heading'), isTrue);
      expect(notifications, 1);
      expect(vm.document.blocks.first.id, 'intro');
    });

    test('setBlockType', () {
      var notifications = 0;
      vm.addListener(() => notifications++);
      expect(vm.setBlockType('notes', 'quote'), isTrue);
      expect(notifications, 1);
      expect(vm.document.blockById('notes')!.type, 'quote');
    });

    test('toggleMark', () {
      var notifications = 0;
      vm.addListener(() => notifications++);
      expect(
          vm.toggleMark(document.positionAt(0, 0), document.positionAt(0, 3),
              'bold', true),
          isTrue);
      expect(notifications, 1);
    });
  });

  group('controller undo restores exact shared editor state', () {
    test('undoLast restores the document by deep equality', () {
      final document = buildFixtureDocument();
      final vm = DocumentViewModel(document: document);
      final before = vm.document;
      _placeCaret(vm, document.positionAt(0, 0));
      expect(vm.insertTextAtCaret('XYZ'), isTrue);
      expect(documentsEqual(vm.document, before), isFalse);

      expect(vm.undoLast(), isTrue);
      expect(documentsEqual(vm.document, before), isTrue);
    });

    test('undo also restores the decoration set and caret snapshot', () {
      final document = buildFixtureDocument();
      final vm = DocumentViewModel(
        document: document,
        decorations: buildFixtureDecorations(document),
      );
      final decorationsBefore = vm.decorations;
      final introIndex = document.indexOfBlockId('intro')!;
      // Edit inside 'intro' — the only block carrying decorations — so
      // DecorationSet.map actually re-anchors its shard (shifting the
      // bold/italic ranges) instead of returning `this` unchanged, the
      // way it would for an edit in an undecorated block.
      final caretBefore = document.positionAt(introIndex, 0);
      _placeCaret(vm, caretBefore);
      expect(vm.insertTextAtCaret('Z'), isTrue);
      expect(vm.decorations, isNot(same(decorationsBefore)));

      expect(vm.undoLast(), isTrue);
      expect(vm.decorations, same(decorationsBefore));
      expect(vm.caret, caretBefore);
    });

    test('undoing a structural transaction (split) round-trips', () {
      final document = buildFixtureDocument();
      final vm = DocumentViewModel(document: document);
      final before = vm.document;
      _placeCaret(vm, document.positionAt(1, 5));
      expect(vm.splitAtCaret(), isTrue);
      expect(vm.document.blockCount, before.blockCount + 1);

      expect(vm.undoLast(), isTrue);
      expect(documentsEqual(vm.document, before), isTrue);
    });

    test('undoing a mirrored block move round-trips', () {
      final document = buildFixtureDocument();
      final vm = DocumentViewModel(document: document);
      final before = vm.document;

      expect(vm.moveBlock('intro', 0), isTrue);
      expect(documentsEqual(vm.document, before), isFalse);

      expect(vm.undoLast(), isTrue);
      expect(documentsEqual(vm.document, before), isTrue);
    });

    test('undo with nothing to undo no-ops', () {
      final vm = DocumentViewModel(document: buildFixtureDocument());
      expect(vm.canUndo, isFalse);
      expect(vm.undoLast(), isFalse);
    });

    test('redoLast restores the exact undone state', () {
      final document = buildFixtureDocument();
      final vm = DocumentViewModel(document: document);
      _placeCaret(vm, document.positionAt(0, 0));
      expect(vm.insertTextAtCaret('XYZ'), isTrue);
      final edited = vm.document;

      expect(vm.undoLast(), isTrue);
      expect(vm.canRedo, isTrue);
      expect(vm.redoLast(), isTrue);
      expect(vm.document, same(edited));
      expect(vm.canRedo, isFalse);
    });
  });

  group('degenerate / invalid inputs no-op as values, never throw', () {
    test('a builder validation failure is caught at the view-model boundary',
        () {
      final vm = DocumentViewModel(document: buildFixtureDocument());
      expect(
        vm.editorController
            .relocateSelection(const HomericSelection.collapsed(0)),
        isFalse,
      );
      var notifications = 0;
      vm.addListener(() => notifications++);
      expect(() => vm.insertTextAtCaret('x'), returnsNormally);
      expect(vm.insertTextAtCaret('x'), isFalse);
      expect(() => vm.splitAtCaret(), returnsNormally);
      expect(vm.splitAtCaret(), isFalse);
      expect(notifications, 0);
    });

    test('commands without a placed caret no-op', () {
      final vm = DocumentViewModel(document: buildFixtureDocument());
      expect(vm.caret, isNull);
      expect(vm.insertTextAtCaret('x'), isFalse);
      expect(vm.splitAtCaret(), isFalse);
      expect(vm.deleteBackwardFromCaret(1), isFalse);
    });

    test('deleteRange with an empty range no-ops', () {
      final vm = DocumentViewModel(document: buildFixtureDocument());
      var notifications = 0;
      vm.addListener(() => notifications++);
      expect(vm.deleteRange(2, 2), isFalse);
      expect(notifications, 0);
    });

    test('every command no-ops instead of throwing on an empty document', () {
      final vm = DocumentViewModel(document: Document());
      expect(() {
        expect(vm.insertTextAtCaret('x'), isFalse);
        expect(vm.toggleMark(0, 0, 'bold', true), isFalse);
        expect(vm.moveBlockUp('missing'), isFalse);
        expect(vm.moveBlockDown('missing'), isFalse);
        expect(vm.setBlockType('missing', 'quote'), isFalse);
        expect(vm.joinBlockWithNext('missing'), isFalse);
        expect(vm.splitAtCaret(), isFalse);
      }, returnsNormally);
    });
  });

  group('decorations', () {
    test('toggleHideDelimiters applies then removes replace decorations', () {
      final document = buildFixtureDocument();
      final vm = DocumentViewModel(document: document);
      expect(vm.isHidingDelimiters('intro'), isFalse);

      vm.toggleHideDelimiters('intro');
      expect(vm.isHidingDelimiters('intro'), isTrue);
      final applied = vm.decorations.forBlock('intro');
      expect(applied, isNotEmpty);
      expect(applied.every((d) => d.kind == DecorationKind.replace), isTrue);

      vm.toggleHideDelimiters('intro');
      expect(vm.isHidingDelimiters('intro'), isFalse);
      expect(vm.decorations.forBlock('intro'), isEmpty);
    });

    test(
        'isHidingDelimiters stays in sync with the decoration set after an '
        'undo (regression: undo used to bypass a separately-tracked flag)', () {
      final document = buildFixtureDocument();
      final vm = DocumentViewModel(document: document);

      // An unrelated document-mutating transaction, so there is something
      // on the undo stack whose pre-transaction decoration snapshot
      // predates the toggle below.
      _placeCaret(vm, document.positionAt(2, 0));
      expect(vm.insertTextAtCaret('X'), isTrue);

      vm.toggleHideDelimiters('intro');
      expect(vm.isHidingDelimiters('intro'), isTrue);

      // Decoration-only changes share the controller's undo pipeline, so the
      // first undo restores the exact decoration snapshot before the toggle.
      expect(vm.undoLast(), isTrue);
      expect(vm.decorations.forBlock('intro'), isEmpty,
          reason: 'the decoration set was restored to its pre-toggle state');
      expect(vm.isHidingDelimiters('intro'), isFalse,
          reason: 'isHidingDelimiters must reflect the restored decoration '
              'set, not a stale flag left over from the toggle');
    });

    test('insertWidgetChip is purely additive to the decoration set', () {
      final vm = DocumentViewModel(document: buildFixtureDocument());
      final before = vm.document;
      expect(vm.insertWidgetChip('notes', 0, label: 'x'), isTrue);
      expect(vm.document, same(before)); // no document mutation at all
      expect(vm.decorations.forBlock('notes'), hasLength(1));
    });

    test('insertWidgetChip on an unknown block no-ops', () {
      final vm = DocumentViewModel(document: buildFixtureDocument());
      expect(vm.insertWidgetChip('missing', 0, label: 'x'), isFalse);
    });

    test('addMentionWash / addAnnotationUnderline / removeDecoration', () {
      final vm = DocumentViewModel(document: buildFixtureDocument());
      vm.addMentionWash('intro', 0, 4);
      expect(vm.decorations.forBlock('intro'), hasLength(1));
      final mentionWash = vm.decorations.forBlock('intro').single;
      vm.removeDecoration(mentionWash);
      expect(vm.decorations.forBlock('intro'), isEmpty);

      vm.addAnnotationUnderline('intro', 1, 3);
      expect(vm.decorations.forBlock('intro'), hasLength(1));
      final annotation = vm.decorations.forBlock('intro').single;
      expect(annotation.start, 1);
      expect(annotation.end, 3);
      expect((annotation.spec! as PlaygroundSpec).kind,
          PlaygroundDecorationKind.annotation);
      vm.removeDecoration(annotation);
      expect(vm.decorations.forBlock('intro'), isEmpty);
    });
  });

  group('widget integration: public editable paragraphs', () {
    testWidgets(
        'tapping a paragraph places canonical selection through its geometry',
        (tester) async {
      final document = buildFixtureDocument();
      final vm = DocumentViewModel(
        document: document,
        decorations: buildFixtureDecorations(document),
      );
      await tester.pumpWidget(PlaygroundApp(viewModel: vm));
      await tester.pumpAndSettle();

      final editableFinder = find.byType(HomericEditableParagraph).first;
      final paragraphFinder = find.descendant(
        of: editableFinder,
        matching: find.byType(HomericParagraph),
      );
      final renderObject =
          tester.renderObject<RenderHomericParagraph>(paragraphFinder);
      final topLeft = tester.getTopLeft(paragraphFinder);
      const localTap = Offset(20, 6);

      await tester.tapAt(topLeft + localTap);
      await tester.pumpAndSettle();

      // Independently recompute the expected answer via the same public
      // geometry API the app itself used — the cross-check the plan asks
      // for, not a re-assertion of the app's own internal state.
      final expectedDocOffset =
          ParagraphGeometry(renderObject).positionForPoint(localTap).value;
      final expectedGlobalPosition =
          document.positionAt(0, expectedDocOffset.value);
      expect(vm.editorController.selection,
          HomericSelection.collapsed(expectedGlobalPosition));
      expect(vm.inputSession.activeBlockId, document.blocks.first.id);
    });
  });

  group('HOM-18 public editing integration', () {
    testWidgets(
        'every paragraph uses the shared controller and one input session',
        (tester) async {
      final document = buildFixtureDocument();
      final vm = DocumentViewModel(
        document: document,
        decorations: buildFixtureDecorations(document),
      );

      await tester.pumpWidget(PlaygroundApp(viewModel: vm));
      await tester.pumpAndSettle();

      expect(find.byType(HomericEditableParagraph),
          findsNWidgets(document.blockCount));
      final editors = tester.widgetList<HomericEditableParagraph>(
        find.byType(HomericEditableParagraph),
      );
      expect(
          editors.every((editor) => identical(
                editor.controller,
                vm.editorController,
              )),
          isTrue);
      expect(
          editors.every((editor) => identical(
                editor.inputSession,
                vm.inputSession,
              )),
          isTrue);
      expect(vm.editorController.document, same(vm.document));
      expect(vm.inputSession.controller, same(vm.editorController));
      expect(
          editors.every((editor) => editor.spellCheckProvider != null), isTrue);
      expect(editors.every((editor) => editor.onHostEvent != null), isTrue);
    });

    testWidgets('playground surfaces typed clipboard feedback safely',
        (tester) async {
      final vm = DocumentViewModel(document: buildFixtureDocument());
      await tester.pumpWidget(PlaygroundApp(viewModel: vm));
      await tester.pumpAndSettle();
      final editor = tester.widget<HomericEditableParagraph>(
        find.byType(HomericEditableParagraph).first,
      );

      editor.onHostEvent!(const HomericPasteRejected());
      await tester.pump();
      expect(
          find.text('Paste supports one paragraph at a time.'), findsOneWidget);
      expect(find.byType(SnackBar), findsOneWidget);

      editor.onHostEvent!(HomericClipboardFailure(
        HomericClipboardOperation.copy,
        StateError('private platform detail'),
      ));
      await tester.pump();
      expect(find.text('Copy failed.'), findsOneWidget);
      expect(find.textContaining('private platform detail'), findsNothing);
    });

    testWidgets('playground spelling fixture paints its deterministic range',
        (tester) async {
      final document = buildFixtureDocument();
      final vm = DocumentViewModel(document: document);
      await tester.pumpWidget(PlaygroundApp(viewModel: vm));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(HomericEditableParagraph).first);
      await tester.pump();
      await tester.pump();

      final render = tester.renderObject<RenderHomericParagraph>(
        find.byType(HomericParagraph).first,
      );
      final start = document.blocks.first.text.indexOf('Playgrond');
      expect(start, greaterThanOrEqualTo(0));
      expect(render.paintLayers, hasLength(1));
      expect(render.paintLayers.single.range.start.value, start);
      expect(render.paintLayers.single.range.end.value,
          start + 'Playgrond'.length);
      expect(render.paintLayers.single.band, PaintBand.overlay);
    });

    testWidgets('transaction panel exposes controller-owned undo and redo',
        (tester) async {
      final document = buildFixtureDocument();
      final vm = DocumentViewModel(document: document);
      _placeCaret(vm, document.positionAt(0, 0));
      expect(vm.insertTextAtCaret('X'), isTrue);
      await tester.pumpWidget(PlaygroundApp(viewModel: vm));
      await tester.pumpAndSettle();

      final undo = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Undo'),
      );
      final redo = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Redo'),
      );
      expect(undo.onPressed, isNotNull);
      expect(redo.onPressed, isNull);
      await tester.ensureVisible(find.widgetWithText(OutlinedButton, 'Undo'));
      await tester.tap(find.widgetWithText(OutlinedButton, 'Undo'));
      await tester.pump();
      expect(vm.canRedo, isTrue);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Redo'),
            )
            .onPressed,
        isNotNull,
      );
    });

    test('type, select, replace, delete, compose, and undo use public state',
        () {
      final document = Document([
        Block(id: 'a', type: 'paragraph', runs: [InlineRun('abc')]),
      ]);
      final vm = DocumentViewModel(document: document);
      final editor = vm.editorController;

      _placeCaret(vm, document.positionAt(0, 1));
      expect(editor.replaceSelection('X'), isTrue);
      expect(editor.document.blocks.single.text, 'aXbc');

      editor.relocateSelection(HomericSelection(
        anchor: editor.globalPositionForBlockOffset('a', 1),
        head: editor.globalPositionForBlockOffset('a', 3),
      ));
      expect(editor.replaceSelection('Y'), isTrue);
      expect(editor.document.blocks.single.text, 'aYc');
      expect(editor.deleteBackward(), isTrue);
      expect(editor.document.blocks.single.text, 'ac');
      expect(vm.undoLast(), isTrue);
      expect(editor.document.blocks.single.text, 'aYc');

      expect(
        editor.applyBlockEditBatch(
          blockId: 'a',
          edits: const [CanonicalTextEdit(1, 1, 'é')],
          selection: const BlockTextSelection.collapsed(2),
          composing: const BlockTextRange(1, 2),
        ),
        isTrue,
      );
      expect(editor.composing, isNotNull);
      expect(
        editor.applyBlockEditBatch(
          blockId: 'a',
          selection: const BlockTextSelection.collapsed(2),
        ),
        isTrue,
      );
      expect(editor.composing, isNull);
      expect(editor.document.blocks.single.text, 'aéYc');
      expect(vm.undoLast(), isTrue);
      expect(editor.document.blocks.single.text, 'aYc');
    });

    testWidgets(
        'theme, font geometry, window width, and hide changes keep selection',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 800);
      addTearDown(tester.view.reset);
      final document = buildFixtureDocument();
      final vm = DocumentViewModel(
        document: document,
        decorations: buildFixtureDecorations(document),
      );
      await tester.pumpWidget(PlaygroundApp(viewModel: vm));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(HomericEditableParagraph).first);
      await tester.pumpAndSettle();
      final selection = vm.editorController.selection;
      final activeBlock = vm.inputSession.activeBlockId;

      await tester.tap(find.byType(Switch));
      await tester.drag(find.byType(Slider), const Offset(80, 0));
      vm.toggleHideDelimiters('intro');
      tester.view.physicalSize = const Size(1320, 800);
      await tester.pumpAndSettle();

      expect(vm.editorController.selection, selection);
      expect(vm.inputSession.activeBlockId, activeBlock);
      expect(vm.isHidingDelimiters('intro'), isTrue);
    });

    testWidgets(
        'block switch commits composition and leaves one active caret overlay',
        (tester) async {
      final document = buildFixtureDocument();
      final vm = DocumentViewModel(document: document);
      final editor = vm.editorController;
      _placeCaret(vm, document.positionAt(0, 1));
      vm.inputSession.attach(blockId: document.blocks.first.id);
      expect(
        editor.applyBlockEditBatch(
          blockId: document.blocks.first.id,
          edits: const [CanonicalTextEdit(1, 1, 'x')],
          selection: const BlockTextSelection.collapsed(2),
          composing: const BlockTextRange(1, 2),
        ),
        isTrue,
      );

      await tester.pumpWidget(PlaygroundApp(viewModel: vm));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(HomericEditableParagraph).at(1));
      await tester.pumpAndSettle();

      expect(editor.composing, isNull);
      expect(editor.document.blocks.first.text, startsWith('Hxomeric'));
      expect(editor.activeBlockId, document.blocks[1].id);
      expect(vm.inputSession.activeBlockId, document.blocks[1].id);
      expect(
        find.byWidgetPredicate((widget) =>
            widget is ColoredBox && widget.color == Colors.blueAccent),
        findsOneWidget,
      );
    });

    test('debug controls and editor input share one undo pipeline', () {
      final document = Document([
        Block(id: 'a', type: 'paragraph', runs: [InlineRun('abc')]),
      ]);
      final vm = DocumentViewModel(document: document);
      _placeCaret(vm, document.positionAt(0, 1));

      expect(vm.insertTextAtCaret('D'), isTrue);
      expect(vm.editorController.replaceSelection('K'), isTrue);
      expect(vm.document.blocks.single.text, 'aDKbc');
      expect(vm.undoLast(), isTrue);
      expect(vm.document.blocks.single.text, 'aDbc');
      expect(vm.undoLast(), isTrue);
      expect(vm.document, same(document));
    });
  });
}
