// An iPad's Scribble turns Apple Pencil handwriting into text. iPadOS asks
// the app which text fields lie under the pen, focuses one, and then places
// the written words by the character rects the focused field reports.
// Homeric draws its own paragraphs, so it has to answer those questions
// itself; without this, handwriting over a note did nothing.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Decoration;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

Block _block(String id, String text) =>
    Block(id: id, type: 'paragraph', runs: <InlineRun>[InlineRun(text)]);

Future<Object?> _sendScribble(
  WidgetTester tester,
  String method,
  List<Object?> args,
) async {
  Object? result;
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.textInput.name,
    SystemChannels.textInput.codec.encodeMethodCall(MethodCall(method, args)),
    (reply) {
      if (reply != null) {
        result = SystemChannels.textInput.codec.decodeEnvelope(reply);
      }
    },
  );
  return result;
}

Future<List<String>> _elementsIn(WidgetTester tester, Rect rect) async {
  final result = await _sendScribble(
    tester,
    'TextInputClient.requestElementsInRect',
    <Object?>[rect.left, rect.top, rect.width, rect.height],
  );
  return <String>[
    for (final element in result! as List<Object?>)
      (element! as List<Object?>).first! as String,
  ];
}

String? _elementAt(Offset point) {
  for (final entry in TextInput.scribbleClients.entries) {
    if (entry.value.bounds.contains(point)) return entry.key;
  }
  return null;
}

void main() {
  late HomericEditorController controller;
  late HomericTextInputSession session;

  Widget editor({bool stylusHandwritingEnabled = true}) => MaterialApp(
        home: Material(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (final id in <String>['a', 'b'])
                SizedBox(
                  width: 400,
                  child: HomericEditableParagraph(
                    key: ValueKey<String>(id),
                    controller: controller,
                    inputSession: session,
                    blockId: id,
                    stylusHandwritingEnabled: stylusHandwritingEnabled,
                    resolveStyle: (_) => const TextStyle(fontSize: 20),
                  ),
                ),
            ],
          ),
        ),
      );

  void setUpEditor({bool readOnly = false}) {
    controller = HomericEditorController(
      document: Document(<Block>[
        _block('a', 'First paragraph'),
        _block('b', 'Second paragraph'),
      ]),
      readOnly: readOnly,
    );
    session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
  }

  testWidgets('writing over a paragraph that is not focused focuses it there',
      (tester) async {
    setUpEditor();
    await tester.pumpWidget(editor());
    // The paragraph lays out, then its overlay catches up a frame later.
    await tester.pump();
    final second = tester.getRect(find.byKey(const ValueKey<String>('b')));

    final offered = await _elementsIn(
      tester,
      Rect.fromCenter(center: second.center, width: 20, height: 10),
    );
    expect(offered, <String>[_elementAt(second.center)!]);

    // The test font draws each letter 20 wide: the pen lands after "Sec".
    final atPen = Offset(second.left + 60, second.center.dy);
    await _sendScribble(
      tester,
      'TextInputClient.focusElement',
      <Object?>[offered.single, atPen.dx, atPen.dy],
    );
    await tester.pump();

    expect(controller.activeBlockId, 'b');
    expect(session.activeBlockId, 'b');
    final head = controller.blockOffsetForGlobalPosition(
      'b',
      controller.selection!.head,
    );
    expect(controller.selection!.isCollapsed, isTrue);
    expect(head, 3);
  });

  testWidgets('a read-only note takes no handwriting', (tester) async {
    setUpEditor(readOnly: true);
    await tester.pumpWidget(editor());
    // The paragraph lays out, then its overlay catches up a frame later.
    await tester.pump();
    final second = tester.getRect(find.byKey(const ValueKey<String>('b')));

    expect(await _elementsIn(tester, second), isEmpty);
  });

  testWidgets('a paragraph can opt out of handwriting', (tester) async {
    setUpEditor();
    await tester.pumpWidget(editor(stylusHandwritingEnabled: false));
    // The paragraph lays out, then its overlay catches up a frame later.
    await tester.pump();
    final second = tester.getRect(find.byKey(const ValueKey<String>('b')));

    expect(await _elementsIn(tester, second), isEmpty);
    expect(TextInput.scribbleClients, isEmpty);
  });

  testWidgets('leaving the screen withdraws the paragraph', (tester) async {
    setUpEditor();
    await tester.pumpWidget(editor());
    // The paragraph lays out, then its overlay catches up a frame later.
    await tester.pump();
    expect(TextInput.scribbleClients, hasLength(2));

    await tester.pumpWidget(const SizedBox());
    expect(TextInput.scribbleClients, isEmpty);
  });

  testWidgets(
      'the focused paragraph tells iPadOS where each character is, '
      'counting the boundary sentinel', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      setUpEditor();
      await tester.pumpWidget(editor());
      // The paragraph lays out, then its overlay catches up a frame later.
      await tester.pump();
      final first = tester.getRect(find.byKey(const ValueKey<String>('a')));
      tester.testTextInput.log.clear();

      await _sendScribble(
        tester,
        'TextInputClient.focusElement',
        <Object?>[_elementAt(first.center), first.left + 1, first.center.dy],
      );
      await tester.pump();
      await tester.pump();

      final call = tester.testTextInput.log.lastWhere(
        (call) => call.method == 'TextInput.setSelectionRects',
      );
      final rects = <List<num>>[
        for (final rect in call.arguments as List<Object?>)
          (rect! as List<Object?>).cast<num>(),
      ];
      // "First paragraph": 15 characters, after the iOS "\n" sentinel.
      expect(rects, hasLength(15));
      expect(
          rects.map((rect) => rect[4]), List<int>.generate(15, (i) => i + 1));
      // Left to right along one line, each with a real size.
      for (var i = 1; i < rects.length; i++) {
        expect(rects[i][0], greaterThan(rects[i - 1][0]));
        expect(rects[i][2], greaterThan(0));
        expect(rects[i][3], greaterThan(0));
      }

      // Typing that changes nothing about layout sends nothing new.
      tester.testTextInput.log.clear();
      await tester.pump();
      expect(
        tester.testTextInput.log
            .where((call) => call.method == 'TextInput.setSelectionRects'),
        isEmpty,
      );

      // New words, new rects.
      expect(controller.replaceSelection('A '), isTrue);
      await tester.pump();
      await tester.pump();
      final updated = tester.testTextInput.log.lastWhere(
        (call) => call.method == 'TextInput.setSelectionRects',
      );
      expect(updated.arguments as List<Object?>, hasLength(17));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the input view follows a focused paragraph as it scrolls',
      (tester) async {
    setUpEditor();
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Material(
        child: SingleChildScrollView(
          controller: scroll,
          child: Column(
            children: <Widget>[
              const SizedBox(height: 300),
              SizedBox(
                width: 400,
                child: HomericEditableParagraph(
                  key: const ValueKey<String>('a'),
                  controller: controller,
                  inputSession: session,
                  blockId: 'a',
                  resolveStyle: (_) => const TextStyle(fontSize: 20),
                ),
              ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.tapAt(
      tester.getRect(find.byKey(const ValueKey<String>('a'))).center,
    );
    await tester.pump();
    await tester.pump();
    expect(session.activeBlockId, 'a');

    double publishedTop() {
      final call = tester.testTextInput.log.lastWhere(
        (call) => call.method == 'TextInput.setEditableSizeAndTransform',
      );
      final transform = (call.arguments as Map<Object?, Object?>)['transform']
          as List<Object?>;
      return (transform[13]! as num).toDouble();
    }

    expect(publishedTop(), 300);
    scroll.jumpTo(120);
    await tester.pump();
    expect(publishedTop(), 180);
  });

  testWidgets('no character rects off iOS', (tester) async {
    setUpEditor();
    await tester.pumpWidget(editor());
    // The paragraph lays out, then its overlay catches up a frame later.
    await tester.pump();
    final first = tester.getRect(find.byKey(const ValueKey<String>('a')));
    tester.testTextInput.log.clear();
    await tester.tapAt(first.center);
    await tester.pump();
    await tester.pump();

    expect(session.activeBlockId, 'a');
    expect(
      tester.testTextInput.log
          .where((call) => call.method == 'TextInput.setSelectionRects'),
      isEmpty,
    );
  });
}
