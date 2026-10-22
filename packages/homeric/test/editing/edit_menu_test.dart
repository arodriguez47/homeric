import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kDoubleTapTimeout, kLongPressTimeout;
import 'package:flutter/material.dart'
    show AdaptiveTextSelectionToolbar, MaterialApp, Scaffold;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

const _style = TextStyle(fontSize: 14);

void main() {
  late List<MethodCall> platformCalls;

  setUp(() {
    platformCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      platformCalls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<
      ({
        HomericEditorController controller,
        HomericTextInputSession session,
      })> pumpParagraph(
    WidgetTester tester, {
    required String text,
    required int caret,
    bool systemMenu = false,
    List<ContextMenuButtonItem> Function()? hostItems,
  }) async {
    final document = Document(<Block>[
      Block(id: 'b', type: 'paragraph', runs: <InlineRun>[InlineRun(text)]),
    ]);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(0, caret)),
    );
    final session = HomericTextInputSession(controller: controller);
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    Widget paragraph = HomericEditableParagraph(
      controller: controller,
      inputSession: session,
      blockId: 'b',
      focusNode: focusNode,
      resolveStyle: (_) => _style,
    );
    if (hostItems != null) {
      paragraph = HomericEditableDocument(
        controller: controller,
        inputSession: session,
        selectionMenuItemsBuilder: (_, __, ___) => hostItems(),
        child: paragraph,
      );
    }
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            supportsShowingSystemContextMenu: systemMenu,
          ),
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(48),
              child: SizedBox(width: 300, child: paragraph),
            ),
          ),
        ),
      ),
    ));
    focusNode.requestFocus();
    await tester.pump();
    expect(session.isAttached, isTrue);
    return (controller: controller, session: session);
  }

  Offset caretPoint(WidgetTester tester, String text, int offset) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: _style),
      textDirection: TextDirection.ltr,
    )..layout();
    final caret = painter.getOffsetForCaret(
      TextPosition(offset: offset),
      Rect.zero,
    );
    painter.dispose();
    return tester.getTopLeft(find.byType(HomericParagraph)) +
        caret +
        const Offset(0, 7);
  }

  Future<void> touchTap(WidgetTester tester, Offset at) async {
    final gesture = await tester.startGesture(
      at,
      kind: PointerDeviceKind.touch,
    );
    await gesture.up();
    await tester.pump();
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 1));
  }

  List<Map<Object?, Object?>> shownItems() {
    final call = platformCalls.lastWhere(
      (call) => call.method == 'ContextMenu.showSystemContextMenu',
    );
    return <Map<Object?, Object?>>[
      for (final item in (call.arguments as Map)['items'] as List)
        item as Map<Object?, Object?>,
    ];
  }

  Future<void> performCustomAction(
    WidgetTester tester,
    String callbackId,
  ) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.platform.name,
      SystemChannels.platform.codec.encodeMethodCall(
        MethodCall('ContextMenu.onPerformCustomAction', <Object?>[
          0,
          callbackId,
        ]),
      ),
      (_) {},
    );
    await tester.pump();
  }

  testWidgets('iOS tap on the caret toggles the edit menu', (tester) async {
    const text = 'alpha beta';
    final editor = await pumpParagraph(tester, text: text, caret: 2);
    final initial = editor.controller.selection;

    await touchTap(tester, caretPoint(tester, text, 2));
    expect(editor.controller.selection, initial,
        reason: 'a tap on the caret leaves it where it is');
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);

    await touchTap(tester, caretPoint(tester, text, 2));
    expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing,
        reason: 'a second tap on the caret closes the menu');

    await touchTap(tester, caretPoint(tester, text, 8));
    expect(editor.controller.selection, isNot(initial),
        reason: 'a tap elsewhere still moves the caret');
    expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('a touch double tap selects the word and opens the menu',
      (tester) async {
    const text = 'alpha beta';
    final editor = await pumpParagraph(tester, text: text, caret: 0);
    final at = caretPoint(tester, text, 8);

    final first = await tester.startGesture(at, kind: PointerDeviceKind.touch);
    await first.up();
    await tester.pump(const Duration(milliseconds: 50));
    final second = await tester.startGesture(at, kind: PointerDeviceKind.touch);
    await tester.pump();
    await second.up();
    await tester.pump();

    final selection = editor.controller.selection!;
    expect(selection.isCollapsed, isFalse);
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('iOS 16+ shows the system edit menu with routed actions',
      (tester) async {
    const text = 'alpha beta';
    var bolded = 0;
    final editor = await pumpParagraph(
      tester,
      text: text,
      caret: 2,
      systemMenu: true,
      hostItems: () => <ContextMenuButtonItem>[
        ContextMenuButtonItem(label: 'Bold', onPressed: () => bolded++),
      ],
    );

    final longPress = await tester.startGesture(
      caretPoint(tester, text, 8),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
    await longPress.up();
    await tester.pump();

    expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing,
        reason: 'UIKit draws this menu, not Flutter');
    var items = shownItems();
    expect(
      items.map((item) => item['title']),
      <String>['Select', 'Paste', 'Select All', 'Bold'],
      reason: 'a caret gets Select, Paste and Select All, then host items',
    );
    expect(items.every((item) => item['type'] == 'custom'), isTrue,
        reason: 'editing goes through Homeric, never the hidden platform text');

    await performCustomAction(tester, items.first['id']! as String);
    await tester.pump();
    final selected = editor.controller.selection!;
    expect(selected.isCollapsed, isFalse, reason: 'Select takes the word');
    items = shownItems();
    expect(
      items.map((item) => item['title']),
      <String>[
        'Cut',
        'Copy',
        'Paste',
        'Select All',
        'Look Up',
        'Search Web',
        'Share',
        'Bold',
      ],
      reason: 'the menu comes back for the selected word',
    );
    expect(items[4]['type'], 'lookUp');

    final bold = items.lastWhere((item) => item['title'] == 'Bold');
    await performCustomAction(tester, bold['id']! as String);
    expect(bolded, 1);
    expect(
      platformCalls.last.method,
      'ContextMenu.hideSystemContextMenu',
      reason: 'an action closes the menu',
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('typing closes a stale system edit menu', (tester) async {
    const text = 'alpha beta';
    final editor = await pumpParagraph(
      tester,
      text: text,
      caret: 2,
      systemMenu: true,
    );
    await touchTap(tester, caretPoint(tester, text, 2));
    expect(
      platformCalls.map((call) => call.method),
      contains('ContextMenu.showSystemContextMenu'),
    );
    platformCalls.clear();

    editor.controller.applyBlockEditBatch(
      blockId: 'b',
      edits: const <CanonicalTextEdit>[CanonicalTextEdit(2, 2, 'x')],
      selection: const BlockTextSelection.collapsed(3),
    );
    await tester.pump();
    expect(
      platformCalls.map((call) => call.method),
      contains('ContextMenu.hideSystemContextMenu'),
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('the platform spell checker reports through its channel',
      (tester) async {
    final requests = <Object?>[];
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.spellCheck, (call) async {
      requests.add(call.arguments);
      return <Object?>[
        <String, Object?>{
          'startIndex': 0,
          'endIndex': 4,
          'suggestions': <String>['teh', 'the'],
        },
      ];
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.spellCheck, null));
    final provider = HomericPlatformSpellCheckProvider(
      locale: () => const Locale('en', 'US'),
    );

    final spans = await provider.check(const HomericSpellCheckRequest(
      blockId: 'b',
      text: 'tehh cat',
      contentRevision: 1,
    ));

    expect(requests.single, <Object?>['en-US', 'tehh cat']);
    expect(spans.single.range, const TextRange(start: 0, end: 4));
    expect(spans.single.suggestions, <String>['teh', 'the']);
    expect(
      await provider.check(const HomericSpellCheckRequest(
        blockId: 'b',
        text: '  ',
        contentRevision: 2,
      )),
      isEmpty,
      reason: 'blank text never reaches the platform',
    );
  });
}
