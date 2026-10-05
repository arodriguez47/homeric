import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

const _style = TextStyle(fontSize: 14);
const _viewportHeight = 300.0;
const _followerKey = ValueKey<String>('sibling-follower');

/// A sibling of the editor, outside its scroll view, that follows one block.
typedef _Followed = ({LayerLink link, Offset offset});

void main() {
  testWidgets('range rects are paragraph-local and anchor the first line',
      (tester) async {
    final harness = _Harness(
      _document([
        'alpha',
        'one two three four five six seven eight nine ten eleven twelve',
      ]),
    );
    HomericEditableBlockGeometry? overlayGeometry;
    await harness.pump(
      tester,
      width: 300,
      blockBuilder: (context, block, focusNode) => HomericEditableParagraph(
        controller: harness.controller,
        inputSession: harness.session,
        blockId: block.id,
        focusNode: focusNode,
        resolveStyle: (_) => _style,
        overlayBuilder: (context, geometry) {
          if (block.id == 'block-1') overlayGeometry = geometry;
          return const <Widget>[];
        },
      ),
    );

    final capability = harness.state.documentGeometry;
    expect(capability.mountedBlockIds, ['block-0', 'block-1']);
    final block = capability.block('block-1')!;
    expect(block.hasText, isTrue);
    final firstLineEnd = overlayGeometry!.lineBoundaryAt(0)!.end;
    final range = BlockTextRange(firstLineEnd, firstLineEnd + 3);
    final rects = block.rectsForRange(range)!;

    expect(rects, isNotEmpty);
    expect(rects, overlayGeometry!.rectsForRange(range));
    expect(rects.first.top, overlayGeometry!.caretRect(range.start)!.top);
    expect(rects.first.top, greaterThan(0),
        reason: 'the range starts on the second visual line');
    expect(block.blockRect, overlayGeometry!.blockRect);
    expect(
        block.caretRect(range.start), overlayGeometry!.caretRect(range.start));

    // The link origin is the paragraph origin: following it with the local
    // rect's offset lands on the range's global position.
    harness.follow(block.layerLink!, offset: rects.first.topLeft);
    await tester.pump();
    expect(
      tester.getTopLeft(find.byKey(_followerKey)),
      _paragraphRect(tester, 'block-1').topLeft + rects.first.topLeft,
    );
  });

  testWidgets('a fully hidden range has no rects but keeps a caret fallback',
      (tester) async {
    final harness = _Harness(_document(['abcdefgh']));
    await harness.pump(
      tester,
      blockBuilder: (context, block, focusNode) => HomericEditableParagraph(
        controller: harness.controller,
        inputSession: harness.session,
        blockId: block.id,
        focusNode: focusNode,
        resolveStyle: (_) => _style,
        deriveDecorations: (block) => <Decoration>[
          Decoration.replace(block.id, 2, 5, replacementLength: 0),
        ],
      ),
    );

    final block = harness.state.documentGeometry.block('block-0')!;
    expect(block.rectsForRange(const BlockTextRange(2, 5)), isEmpty);
    final caret = block.caretRect(2);
    expect(caret, isNotNull);
    expect(caret!.isFinite, isTrue);
  });

  testWidgets('queries outside the block or document fail closed',
      (tester) async {
    final harness = _Harness(_document(['abc', 'def']));
    await harness.pump(tester);

    final capability = harness.state.documentGeometry;
    expect(capability.block('missing'), isNull);
    final block = capability.block('block-0')!;
    expect(block.rectsForRange(const BlockTextRange(1, 4)), isNull);
    expect(block.caretRect(4), isNull);
    expect(block.caretRect(-1), isNull);
    expect(block.rectsForRange(const BlockTextRange(1, 3)), isNotEmpty);
  });

  testWidgets('a follower tracks scroll in the same frame without a signal',
      (tester) async {
    // Ten 44 px rows fit inside viewport plus cache extent, so scrolling
    // mounts and unmounts nothing.
    final harness = _Harness(
      _document([for (var index = 0; index < 10; index++) 'row $index']),
    );
    await harness.pump(tester);
    final capability = harness.state.documentGeometry;
    harness.follow(capability.block('block-5')!.layerLink!);
    await tester.pump();
    final before = tester.getTopLeft(find.byKey(_followerKey));
    expect(before, _paragraphRect(tester, 'block-5').topLeft);
    harness.signals = 0;

    harness.scrollController.jumpTo(60);
    await tester.pump();

    expect(
      tester.getTopLeft(find.byKey(_followerKey)),
      before - const Offset(0, 60),
    );
    expect(
      tester.getTopLeft(find.byKey(_followerKey)),
      _paragraphRect(tester, 'block-5').topLeft,
    );
    expect(harness.signals, 0, reason: 'scroll is not a signal source');
    expect(capability.isCurrent, isTrue,
        reason: 'scroll does not change row-local geometry');
  });

  testWidgets('a new line above a block moves its follower in the same frame',
      (tester) async {
    final harness = _Harness(_document(['first', 'second', 'third']));
    await harness.pump(tester);
    final capability = harness.state.documentGeometry;
    harness.follow(capability.block('block-2')!.layerLink!);
    await tester.pump();
    final before = tester.getTopLeft(find.byKey(_followerKey));
    harness.signals = 0;

    harness.controller.setSelection(HomericSelection.collapsed(
      harness.controller.document.positionAt(0, 5),
    ));
    expect(harness.controller.insertParagraphBreak(), isTrue);
    await tester.pump();

    final after = tester.getTopLeft(find.byKey(_followerKey));
    expect(after, _paragraphRect(tester, 'block-2').topLeft,
        reason: 'the follower lands on the block in the edit frame');
    expect(after.dy, greaterThan(before.dy));
    expect(harness.signals, greaterThan(0));
    expect(capability.isCurrent, isFalse);
    expect(capability.block('block-2'), isNull);
    expect(harness.state.documentGeometry.mountedBlockIds, hasLength(4));
  });

  testWidgets('a non-text block publishes a link and signals on resize',
      (tester) async {
    final height = ValueNotifier<double>(20);
    addTearDown(height.dispose);
    final harness = _Harness(Document(<Block>[
      _block('block-0', 'before'),
      Block(id: 'rule', type: 'rule', runs: const <InlineRun>[]),
      _block('block-2', 'after'),
    ]));
    await harness.pump(
      tester,
      blockBuilder: (context, block, focusNode) => block.type == 'rule'
          ? ValueListenableBuilder<double>(
              valueListenable: height,
              builder: (context, value, _) => SizedBox(
                key: const ValueKey<String>('rule-content'),
                height: value,
              ),
            )
          : HomericEditableParagraph(
              controller: harness.controller,
              inputSession: harness.session,
              blockId: block.id,
              focusNode: focusNode,
              resolveStyle: (_) => _style,
            ),
    );
    final capability = harness.state.documentGeometry;
    final rule = capability.block('rule')!;
    expect(rule.hasText, isFalse);
    expect(rule.blockRect!.topLeft, Offset.zero);
    expect(rule.blockRect!.height, 20);
    expect(rule.rectsForRange(const BlockTextRange(0, 0)), isEmpty);
    expect(rule.caretRect(0), isNull);
    harness.follow(rule.layerLink!);
    await tester.pump();
    expect(
      tester.getTopLeft(find.byKey(_followerKey)),
      tester.getTopLeft(find.byKey(const ValueKey<String>('rule-content'))),
    );
    harness.signals = 0;

    height.value = 80;
    await tester.pump();

    expect(harness.signals, 1);
    expect(capability.isCurrent, isFalse);
    expect(rule.blockRect, isNull);
    expect(rule.layerLink, isNull);
    expect(
      harness.state.documentGeometry.block('rule')!.blockRect!.height,
      80,
    );
  });

  testWidgets('an editor width change signals and revokes old capabilities',
      (tester) async {
    final harness = _Harness(_document(['one two three four five six']));
    await harness.pump(tester, width: 400);
    final capability = harness.state.documentGeometry;
    final block = capability.block('block-0')!;
    expect(block.blockRect, isNotNull);
    harness.signals = 0;

    harness.width.value = 200;
    await tester.pump();

    expect(harness.signals, greaterThan(0));
    expect(capability.isCurrent, isFalse);
    expect(capability.mountedBlockIds, isNull);
    expect(capability.block('block-0'), isNull);
    expect(block.isCurrent, isFalse);
    expect(block.layerLink, isNull);
    expect(block.blockRect, isNull);
    expect(block.rectsForRange(const BlockTextRange(0, 3)), isNull);
    final fresh = harness.state.documentGeometry.block('block-0')!;
    expect(fresh.blockRect!.width, 200 - 44);
  });

  testWidgets('a block outside the cache extent returns null', (tester) async {
    final harness = _Harness(
      _document([for (var index = 0; index < 60; index++) 'row $index']),
    );
    await harness.pump(tester, cacheExtent: 0);
    final capability = harness.state.documentGeometry;
    expect(capability.block('block-0'), isNotNull);
    harness.signals = 0;

    harness.scrollController.jumpTo(1500);
    await tester.pump();

    expect(harness.signals, greaterThan(0),
        reason: 'rows mounted and unmounted');
    expect(capability.block('block-0'), isNull);
    final current = harness.state.documentGeometry;
    expect(current.block('block-0'), isNull);
    expect(current.mountedBlockIds, isNot(contains('block-0')));
    expect(current.mountedBlockIds, isNotEmpty);
  });

  testWidgets('a kept-alive off-screen row never yields a non-finite rect',
      (tester) async {
    final harness = _Harness(
      _document([for (var index = 0; index < 60; index++) 'row $index']),
      selection: const HomericSelection.collapsed(1),
    );
    await harness.pump(tester, cacheExtent: 0);
    expect(harness.controller.activeBlockId, 'block-0');
    harness.signals = 0;

    harness.scrollController.jumpTo(1500);
    await tester.pump();

    expect(
      find.byKey(
        const ValueKey<String>('homeric-editable-block-0'),
        skipOffstage: false,
      ),
      findsOneWidget,
      reason: 'the active row is kept alive off-screen',
    );
    final current = harness.state.documentGeometry;
    expect(current.mountedBlockIds, isNot(contains('block-0')));
    expect(current.block('block-0'), isNull);
    for (final blockId in current.mountedBlockIds!) {
      final block = current.block(blockId);
      if (block == null) continue;
      expect(block.blockRect!.isFinite, isTrue);
      final rects = block.rectsForRange(const BlockTextRange(0, 3))!;
      expect(rects.every((rect) => rect.isFinite), isTrue);
      final caret = block.caretRect(0);
      expect(caret == null || caret.isFinite, isTrue);
    }

    harness.signals = 0;
    harness.scrollController.jumpTo(0);
    await tester.pump();
    expect(harness.signals, greaterThan(0),
        reason: 'the kept-alive row is laid out again');
    expect(harness.state.documentGeometry.block('block-0'), isNotNull);
  });

  testWidgets('paint-only changes do not signal', (tester) async {
    final selectionColor = ValueNotifier<Color>(const Color(0xFF2196F3));
    addTearDown(selectionColor.dispose);
    final harness = _Harness(
      _document(['alpha beta gamma', 'delta']),
      selection: const HomericSelection(anchor: 1, head: 4),
    );
    FocusNode? firstFocus;
    await harness.pump(
      tester,
      blockBuilder: (context, block, focusNode) {
        if (block.id == 'block-0') firstFocus = focusNode;
        return ValueListenableBuilder<Color>(
          valueListenable: selectionColor,
          builder: (context, color, _) => HomericEditableParagraph(
            controller: harness.controller,
            inputSession: harness.session,
            blockId: block.id,
            focusNode: focusNode,
            selectionColor: color,
            resolveStyle: (_) => _style,
          ),
        );
      },
    );
    firstFocus!.requestFocus();
    await tester.pump();
    await tester.pump();
    final capability = harness.state.documentGeometry;
    harness.signals = 0;

    selectionColor.value = const Color(0xFFFF5722);
    await tester.pump();
    harness.controller.setSelection(const HomericSelection(anchor: 2, head: 7));
    await tester.pump();
    harness.controller.setSelection(const HomericSelection.collapsed(3));
    await tester.pump();
    // Caret blink.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));

    expect(harness.signals, 0);
    expect(capability.isCurrent, isTrue);
  });

  testWidgets('globalOrigin puts blocks in one space that moves with scroll',
      (tester) async {
    final harness = _Harness(Document(<Block>[
      _block('block-0', 'before'),
      Block(id: 'rule', type: 'rule', runs: const <InlineRun>[]),
      for (var index = 2; index < 10; index++)
        _block('block-$index', 'row $index'),
    ]));
    await harness.pump(
      tester,
      blockBuilder: (context, block, focusNode) => block.type == 'rule'
          ? const SizedBox(
              key: ValueKey<String>('rule-content'),
              height: 20,
            )
          : HomericEditableParagraph(
              controller: harness.controller,
              inputSession: harness.session,
              blockId: block.id,
              focusNode: focusNode,
              resolveStyle: (_) => _style,
            ),
    );
    final capability = harness.state.documentGeometry;
    final text = capability.block('block-5')!;
    final rule = capability.block('rule')!;
    expect(text.globalOrigin, _paragraphRect(tester, 'block-5').topLeft);
    expect(
      rule.globalOrigin,
      tester.getTopLeft(find.byKey(const ValueKey<String>('rule-content'))),
    );
    // A follower on the link lands on the published origin.
    harness.follow(text.layerLink!);
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(_followerKey)), text.globalOrigin);
    final distance = text.globalOrigin!.dy - rule.globalOrigin!.dy;
    harness.signals = 0;

    harness.scrollController.jumpTo(30);
    await tester.pump();

    expect(harness.signals, 0);
    expect(capability.isCurrent, isTrue);
    expect(text.globalOrigin, _paragraphRect(tester, 'block-5').topLeft);
    expect(text.globalOrigin!.dy - rule.globalOrigin!.dy, distance);

    harness.width.value = 200;
    await tester.pump();
    expect(text.globalOrigin, isNull, reason: 'stale after relayout');
  });

  testWidgets('a stale capability stays revoked after the document is disposed',
      (tester) async {
    final harness = _Harness(_document(['abc']));
    await harness.pump(tester);
    final capability = harness.state.documentGeometry;
    final block = capability.block('block-0')!;

    await tester.pumpWidget(const SizedBox.shrink());

    expect(capability.isCurrent, isFalse);
    expect(capability.mountedBlockIds, isNull);
    expect(block.layerLink, isNull);
    expect(block.caretRect(0), isNull);
  });
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
  final ValueNotifier<double> width = ValueNotifier<double>(400);
  final ValueNotifier<_Followed?> followed = ValueNotifier<_Followed?>(null);
  final GlobalKey<HomericEditableDocumentState> documentKey =
      GlobalKey<HomericEditableDocumentState>();
  int signals = 0;

  HomericEditableDocumentState get state => documentKey.currentState!;

  void follow(LayerLink link, {Offset offset = Offset.zero}) {
    followed.value = (link: link, offset: offset);
  }

  Future<void> pump(
    WidgetTester tester, {
    double width = 400,
    double cacheExtent = 250,
    HomericEditableBlockBuilder? blockBuilder,
  }) async {
    addTearDown(() {
      followed.dispose();
      this.width.dispose();
      scrollController.dispose();
      session.dispose();
      controller.dispose();
    });
    this.width.value = width;
    final editor = ValueListenableBuilder<double>(
      valueListenable: this.width,
      builder: (context, width, _) => Positioned(
        left: 0,
        top: 0,
        width: width,
        height: _viewportHeight,
        child: HomericEditableDocument.builder(
          key: documentKey,
          controller: controller,
          inputSession: session,
          scrollController: scrollController,
          cacheExtent: cacheExtent,
          estimatedBlockHeight: 44,
          blockBuilder: blockBuilder ??
              (context, block, focusNode) => HomericEditableParagraph(
                    controller: controller,
                    inputSession: session,
                    blockId: block.id,
                    focusNode: focusNode,
                    resolveStyle: (_) => _style,
                  ),
        ),
      ),
    );
    final follower = Positioned(
      left: 0,
      top: 0,
      child: ValueListenableBuilder<_Followed?>(
        valueListenable: followed,
        builder: (context, followed, _) => followed == null
            ? const SizedBox.shrink()
            : CompositedTransformFollower(
                link: followed.link,
                offset: followed.offset,
                showWhenUnlinked: false,
                child: const SizedBox(key: _followerKey, width: 8, height: 8),
              ),
      ),
    );
    // Flutter requires a link's leader to paint before its followers, so a
    // sibling layer that follows editor blocks paints after the editor.
    await tester.pumpWidget(_withOverlay(Stack(
      children: <Widget>[editor, follower],
    )));
    // Let first-layout geometry notices settle before observing signals.
    await tester.pump();
    state.documentGeometryChanges.addListener(() => signals++);
  }
}

Rect _paragraphRect(WidgetTester tester, String blockId) => tester.getRect(
      find.byKey(
        ValueKey<String>('homeric-editable-$blockId'),
        skipOffstage: false,
      ),
    );

Widget _withOverlay(Widget child) => Directionality(
      textDirection: TextDirection.ltr,
      child: Localizations(
        locale: const Locale('en'),
        delegates: const <LocalizationsDelegate<dynamic>>[
          DefaultWidgetsLocalizations.delegate,
        ],
        child: Overlay(
          initialEntries: <OverlayEntry>[
            OverlayEntry(builder: (_) => child),
          ],
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
