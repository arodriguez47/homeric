import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart' show MaterialApp, Scaffold;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

const _style = TextStyle(fontSize: 14);
const _channel = MethodChannel('homeric/spelling');

/// A Mac side that knows a few misspellings and remembers learned words.
final class _FakeMac {
  _FakeMac() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, _handle);
  }

  final calls = <MethodCall>[];
  final learned = <String>{};
  final guesses = <String, List<String>>{
    'wrod': <String>['word', 'rod'],
    'zxqv': <String>[],
  };
  Map<String, Object?> settings = <String, Object?>{
    'autocorrect': true,
    'replacement': true,
    'replacements': <String, String>{'omw': 'On my way!'},
  };

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call);
    final args = call.arguments as Map<Object?, Object?>?;
    switch (call.method) {
      case 'settings':
        return settings;
      case 'learn':
      case 'ignore':
        learned.add(args!['word']! as String);
        return null;
      case 'check':
        final text = args!['text']! as String;
        return <Map<String, Object?>>[
          for (final match in RegExp(r'\p{L}+', unicode: true).allMatches(text))
            if (guesses[match[0]] case final found?
                when !learned.contains(match[0]))
              <String, Object?>{
                'start': match.start,
                'end': match.end,
                'guesses': found,
              },
        ];
      case 'correct':
        final text = args!['text']! as String;
        final word = text.substring(args['start']! as int, args['end']! as int);
        return guesses[word]?.firstOrNull;
    }
    return null;
  }

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}

void main() {
  late _FakeMac mac;
  late HomericMacSpelling spelling;

  setUp(() {
    mac = _FakeMac();
    spelling = HomericMacSpelling.forTesting(_channel);
  });

  tearDown(() {
    spelling.dispose();
    mac.dispose();
  });

  test('reads misspellings, guesses and settings from the Mac', () async {
    await Future<void>.delayed(Duration.zero);
    expect(spelling.isAvailable, isTrue);
    expect(spelling.correctsSpellingAutomatically, isTrue);
    expect(spelling.replacesTextAutomatically, isTrue);
    expect(spelling.textReplacements, <String, String>{'omw': 'On my way!'});

    final spans = await spelling.check(const HomericSpellCheckRequest(
      blockId: 'b',
      text: 'a wrod and zxqv',
      contentRevision: 1,
    ));
    expect(spans.map((span) => (span.range.start, span.range.end)), [
      (2, 6),
      (11, 15),
    ]);
    expect(spans.first.suggestions, <String>['word', 'rod']);
    expect(spans.last.suggestions, isEmpty);

    expect(await spelling.correction('a wrod', 2, 6), 'word');
    expect(await spelling.correction('a word', 2, 6), isNull);
  });

  test('autocorrect follows the system setting', () async {
    mac.settings = <String, Object?>{'autocorrect': false};
    spelling.dispose();
    spelling = HomericMacSpelling.forTesting(_channel);
    await Future<void>.delayed(Duration.zero);
    expect(spelling.correctsSpellingAutomatically, isFalse);
    expect(await spelling.correction('a wrod', 2, 6), isNull);
    expect(spelling.textReplacements, isEmpty);
  });

  test('a settings change on the Mac reaches the editor', () async {
    await Future<void>.delayed(Duration.zero);
    var heard = 0;
    spelling.typingCorrectionsChanged.addListener(() => heard++);
    mac.settings = <String, Object?>{'autocorrect': false, 'replacement': true};
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      _channel.name,
      _channel.codec.encodeMethodCall(const MethodCall('settingsChanged')),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
    expect(heard, 1);
    expect(spelling.correctsSpellingAutomatically, isFalse);
  });

  test('an app without the Mac side gets no spelling, and no errors', () async {
    mac.dispose();
    spelling.dispose();
    spelling = HomericMacSpelling.forTesting(_channel);
    final spans = await spelling.check(const HomericSpellCheckRequest(
      blockId: 'b',
      text: 'a wrod',
      contentRevision: 1,
    ));
    expect(spans, isEmpty);
    expect(spelling.isAvailable, isFalse);
    expect(await spelling.correction('a wrod', 2, 6), isNull);
    await spelling.learnSpelling('wrod');
  });

  test('the system checker per platform', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(homericSystemSpellChecker(locale: () => const Locale('en')),
        same(HomericMacSpelling.instance));
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(homericSystemSpellChecker(locale: () => const Locale('en')), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  group('the right-click menu on the Mac', () {
    Future<HomericEditorController> pump(
      WidgetTester tester,
      String text, {
      int? caret,
    }) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final document = Document(<Block>[
        Block(id: 'b', type: 'paragraph', runs: <InlineRun>[InlineRun(text)]),
      ]);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(
          document.positionAt(0, caret ?? 0),
        ),
      );
      final session = HomericTextInputSession(controller: controller);
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      addTearDown(session.dispose);
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: SizedBox(
              width: 360,
              child: HomericEditableParagraph(
                controller: controller,
                inputSession: session,
                focusNode: focusNode,
                blockId: 'b',
                resolveStyle: (_) => _style,
                spellCheckProvider: spelling,
              ),
            ),
          ),
        ),
      ));
      focusNode.requestFocus();
      await tester.pump();
      await tester.pump();
      await tester.pump();
      return controller;
    }

    Future<void> rightClick(WidgetTester tester, int start, int end) async {
      final geometry = ParagraphGeometry(tester
          .renderObject<RenderHomericParagraph>(find.byType(HomericParagraph)));
      final word = geometry
          .rectsForRange(DocRange(DocOffset(start), DocOffset(end)))
          .value
          .first
          .toRect()
          .center;
      await tester.tapAt(
        tester.getTopLeft(find.byType(HomericParagraph)) + word,
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
    }

    int squiggles(WidgetTester tester) => tester
        .renderObject<RenderHomericParagraph>(find.byType(HomericParagraph))
        .paintLayers
        .where((layer) => layer.band == PaintBand.overlay)
        .length;

    Finder row(String label) => find.descendant(
          of: find.byKey(const ValueKey<String>('homeric-context-menu')),
          matching: find.text(label),
        );

    testWidgets('offers guesses, Learn Spelling and Ignore Spelling',
        (tester) async {
      final controller = await pump(tester, 'a wrod here');
      expect(squiggles(tester), 1);
      await rightClick(tester, 2, 6);
      expect(row('word'), findsOneWidget);
      expect(row('rod'), findsOneWidget);
      expect(row('Learn Spelling'), findsOneWidget);
      expect(row('Ignore Spelling'), findsOneWidget);
      expect(row('No Guesses Found'), findsNothing);

      await tester.tap(row('word'));
      await tester.pump();
      expect(controller.document.blocks.single.text, 'a word here');
      ContextMenuController.removeAny();
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Learn Spelling teaches the Mac and the squiggle goes',
        (tester) async {
      final controller = await pump(tester, 'a wrod here');
      expect(squiggles(tester), 1);
      await rightClick(tester, 2, 6);
      await tester.tap(row('Learn Spelling'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(
        mac.calls.where((call) => call.method == 'learn').single.arguments,
        <String, Object?>{'word': 'wrod'},
      );
      expect(squiggles(tester), 0);
      expect(controller.document.blocks.single.text, 'a wrod here');
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a word with no guesses keeps its squiggle and says so',
        (tester) async {
      await pump(tester, 'a zxqv here');
      expect(squiggles(tester), 1);
      await rightClick(tester, 2, 6);
      expect(row('No Guesses Found'), findsOneWidget);
      expect(row('Ignore Spelling'), findsOneWidget);
      await tester.tap(row('Ignore Spelling'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(mac.calls.where((call) => call.method == 'ignore'), hasLength(1));
      expect(squiggles(tester), 0);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('the word still being typed waits for the writer to move on',
        (tester) async {
      final controller = await pump(tester, 'a wrod', caret: 6);
      expect(squiggles(tester), 0);
      controller.replaceSelection(' ');
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(squiggles(tester), 1);
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
