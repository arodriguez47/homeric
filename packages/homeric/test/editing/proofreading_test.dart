import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart' show MaterialApp, Scaffold;
import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/writing.dart';

const _style = TextStyle(fontSize: 14);
const _grammar = Color(0xFF0000FF);
const _wash = Color(0x33FFCC00);

/// Flags "the the" as a grammar finding, and counts what it was asked.
final class _FakeHarper implements HomericProofingSource {
  final asked = <String>[];

  @override
  Future<List<HomericProofingIssue>> check(String text) async {
    asked.add(text);
    return [
      for (final match in RegExp(r'\bthe the\b').allMatches(text))
        HomericProofingIssue(
          range: TextRange(start: match.start, end: match.end),
          group: HomericProofingGroup.repetitionAndPunctuation,
          ruleId: 'RepeatedWords',
          message: 'The word "the" is repeated.',
          replacements: const ['the'],
        ),
    ];
  }
}

void main() {
  group('phrase rules', () {
    test('match whole words, any case, and keep a capital', () {
      final rules = HomericPhraseRules(const [
        HomericPhraseRule(find: 'in order to', replace: 'to'),
        HomericPhraseRule(find: 'use', replace: 'employ'),
        HomericPhraseRule(find: 'basically'),
      ]);
      final found = rules.find(
        'In order  to go, basically. Because we use it.',
      );
      expect(
        found.map((issue) => (issue.range.start, issue.range.end)),
        [(0, 12), (39, 42), (17, 26)],
      );
      expect(found[0].replacements, ['To']);
      expect(found[0].group, HomericProofingGroup.yourRules);
      expect(found[0].mark, HomericProofingMark.style);
      expect(found[2].replacements, isEmpty);
      expect(found[2].message, 'Your rule flags "basically".');
    });

    test('round-trip through JSON and drop empty rules', () {
      const rule = HomericPhraseRule(find: 'utilize', replace: 'use');
      expect(HomericPhraseRule.fromJson(rule.toJson()), rule);
      expect(HomericPhraseRule.fromJson({'find': '  '}), isNull);
      expect(HomericPhraseRules(const [HomericPhraseRule(find: ' ')]).rules,
          isEmpty);
    });
  });

  group('the proofing suite', () {
    const request = HomericSpellCheckRequest(
      blockId: 'b',
      text: 'We saw the the tide in order to look.',
      contentRevision: 1,
    );

    test('merges sources in order and applies the writer\'s choices', () async {
      final suite = HomericProofingSuite(sources: [
        _FakeHarper(),
        HomericPhraseRules(const [
          HomericPhraseRule(find: 'in order to', replace: 'to'),
        ]),
      ]);
      var heard = 0;
      suite.proofingChanges.addListener(() => heard++);
      expect((await suite.proofread(request)).map((i) => i.ruleId),
          ['RepeatedWords', 'phrase:in order to']);

      suite.groups = {HomericProofingGroup.yourRules};
      expect((await suite.proofread(request)).map((i) => i.ruleId),
          ['phrase:in order to']);

      suite.groups = HomericProofingGroup.values.toSet();
      suite.rulesOff = {'phrase:in order to'};
      expect((await suite.proofread(request)).map((i) => i.ruleId),
          ['RepeatedWords']);

      suite.enabled = false;
      expect(await suite.proofread(request), isEmpty);
      expect(heard, 4);
    });

    test('ignores one occurrence, not every one with the same words', () async {
      final suite = HomericProofingSuite(sources: [_FakeHarper()]);
      const twice = HomericSpellCheckRequest(
        blockId: 'b',
        text: 'We saw the the tide and the the sea.',
        contentRevision: 0,
      );
      final second = (await suite.proofread(twice)).last;
      suite.ignore('b', second, 'the the', occurrence: 1);
      expect((await suite.proofread(twice)).map((i) => i.range.start), [7]);
    });

    test('ignores a finding in one paragraph only', () async {
      final suite = HomericProofingSuite(sources: [_FakeHarper()]);
      final issue = (await suite.proofread(request)).single;
      suite.ignore('b', issue, 'the the');
      expect(await suite.proofread(request), isEmpty);
      expect(
        await suite.proofread(const HomericSpellCheckRequest(
          blockId: 'other',
          text: 'We saw the the tide.',
          contentRevision: 1,
        )),
        hasLength(1),
      );
    });

    test('offers Turn off for Harper rules and Edit for the writer\'s own',
        () async {
      HomericProofingIssue? turnedOff;
      HomericProofingIssue? edited;
      final suite = HomericProofingSuite(
        sources: [
          _FakeHarper(),
          HomericPhraseRules(const [
            HomericPhraseRule(find: 'in order to', replace: 'to'),
          ]),
        ],
        onTurnOffRule: (issue) => turnedOff = issue,
        onEditRule: (issue) => edited = issue,
      );
      final issues = await suite.proofread(request);
      final turnOff = suite.ruleActionFor(issues[0])!;
      expect(turnOff.label, 'Turn off this rule');
      turnOff.onPressed();
      expect(turnedOff?.ruleId, 'RepeatedWords');
      expect(suite.rulesOff, {'RepeatedWords'});
      final edit = suite.ruleActionFor(issues[1])!;
      expect(edit.label, 'Edit rule');
      edit.onPressed();
      expect(edited?.ruleId, 'phrase:in order to');
    });
  });

  group('marks in a paragraph', () {
    late _FakeHarper harper;
    late HomericProofingSuite suite;

    setUp(() {
      harper = _FakeHarper();
      suite = HomericProofingSuite(sources: [
        harper,
        HomericPhraseRules(const [
          HomericPhraseRule(find: 'in order to', replace: 'to'),
        ]),
      ]);
    });

    tearDown(() => suite.dispose());

    Future<
        ({
          HomericEditorController controller,
          FocusNode focusNode,
          List<HomericProofingTap> taps,
        })> pump(
      WidgetTester tester,
      String text, {
      bool focus = false,
      TargetPlatform platform = TargetPlatform.macOS,
      List<(int, int)> hidden = const [],
    }) async {
      debugDefaultTargetPlatformOverride = platform;
      final document = Document(<Block>[
        Block(id: 'b', type: 'paragraph', runs: <InlineRun>[InlineRun(text)]),
      ]);
      final controller = HomericEditorController(
        document: document,
        selection: focus
            ? HomericSelection.collapsed(document.positionAt(0, text.length))
            : null,
      );
      final session = HomericTextInputSession(controller: controller);
      final focusNode = FocusNode();
      final taps = <HomericProofingTap>[];
      addTearDown(focusNode.dispose);
      addTearDown(session.dispose);
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: SizedBox(
              width: 420,
              child: HomericEditableParagraph(
                controller: controller,
                inputSession: session,
                focusNode: focusNode,
                blockId: 'b',
                resolveStyle: (_) => _style,
                deriveDecorations: (block) => [
                  for (final (start, end) in hidden)
                    markdownMarkHideReplacement(block.id, start, end),
                ],
                markdownMarkVisibility: MarkdownMarkVisibility.livePreview,
                proofreader: suite,
                grammarColor: _grammar,
                styleWashColor: _wash,
                onProofingIssueTap: taps.add,
              ),
            ),
          ),
        ),
      ));
      if (focus) focusNode.requestFocus();
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      return (controller: controller, focusNode: focusNode, taps: taps);
    }

    List<PaintLayer> layers(WidgetTester tester) => tester
        .renderObject<RenderHomericParagraph>(find.byType(HomericParagraph))
        .paintLayers;

    int dots(WidgetTester tester) => layers(tester)
        .where((layer) =>
            layer.band == PaintBand.overlay &&
            layer.spec is UnderlineSpec &&
            (layer.spec! as UnderlineSpec).color == _grammar)
        .length;

    int washes(WidgetTester tester) => layers(tester)
        .where((layer) =>
            layer.band == PaintBand.underlay &&
            layer.spec is SolidWashSpec &&
            (layer.spec! as SolidWashSpec).color == _wash)
        .length;

    Offset centerOf(WidgetTester tester, int start, int end) {
      final geometry = ParagraphGeometry(tester
          .renderObject<RenderHomericParagraph>(find.byType(HomericParagraph)));
      return tester.getTopLeft(find.byType(HomericParagraph)) +
          geometry
              .rectsForRange(DocRange(DocOffset(start), DocOffset(end)))
              .value
              .first
              .toRect()
              .center;
    }

    Finder row(String label) => find.descendant(
          of: find.byKey(const ValueKey<String>('homeric-context-menu')),
          matching: find.text(label),
        );

    testWidgets('a paragraph the caret is not in gets dots and a wash',
        (tester) async {
      await pump(tester, 'We saw the the tide in order to look.');
      expect(harper.asked, ['We saw the the tide in order to look.']);
      expect(dots(tester), 1);
      expect(washes(tester), 1);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('the paragraph being written is not checked while typing',
        (tester) async {
      final pumped = await pump(tester, 'We saw the the tide', focus: true);
      harper.asked.clear();
      for (final char in ' again'.split('')) {
        pumped.controller.replaceSelection(char);
        await tester.pump();
      }
      await tester.pump();
      expect(harper.asked, isEmpty);
      expect(dots(tester), 0);

      // The caret leaves: now it is checked.
      pumped.focusNode.unfocus();
      pumped.controller.setSelection(null);
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(harper.asked, ['We saw the the tide again']);
      expect(dots(tester), 1);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a click on a mark opens the menu on the Mac', (tester) async {
      await pump(tester, 'We saw the the tide.');
      await tester.tapAt(centerOf(tester, 7, 14));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(row('The word "the" is repeated.'), findsOneWidget);
      expect(row('Ignore here'), findsOneWidget);
      ContextMenuController.removeAny();
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('typing in a marked paragraph clears its marks',
        (tester) async {
      final pumped = await pump(tester, 'We saw the the tide.');
      expect(dots(tester), 1);
      pumped.controller.setSelection(HomericSelection.collapsed(
        pumped.controller.document.positionAt(0, 20),
      ));
      pumped.focusNode.requestFocus();
      await tester.pump();
      // Clicking in keeps the marks; typing clears them.
      expect(dots(tester), 1);
      pumped.controller.replaceSelection('x');
      await tester.pump();
      await tester.pump();
      expect(dots(tester), 0);
      expect(harper.asked, hasLength(1));
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('right-click offers the fix, the reason and the rule actions',
        (tester) async {
      final suite2 = suite;
      final pumped =
          await pump(tester, 'We saw the the tide in order to look.');
      await tester.tapAt(
        centerOf(tester, 7, 14),
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
      expect(row('the'), findsOneWidget);
      expect(row('The word "the" is repeated.'), findsOneWidget);
      expect(row('Ignore here'), findsOneWidget);
      expect(
          suite2.ruleActionFor(const HomericProofingIssue(
            range: TextRange(start: 0, end: 1),
            group: HomericProofingGroup.grammar,
            ruleId: 'x',
            message: '',
          )),
          isNull);

      await tester.tap(row('the'));
      await tester.pump();
      expect(
        pumped.controller.document.blocks.single.text,
        'We saw the tide in order to look.',
      );
      // The other mark stays where its words moved to, without a new check.
      expect(washes(tester), 1);
      expect(dots(tester), 0);
      expect(harper.asked, hasLength(1));
      ContextMenuController.removeAny();
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Ignore here takes the mark away', (tester) async {
      await pump(tester, 'We saw the the tide.');
      await tester.tapAt(
        centerOf(tester, 7, 14),
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
      await tester.tap(row('Ignore here'));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(dots(tester), 0);
      ContextMenuController.removeAny();
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Ignore here leaves the same words elsewhere marked',
        (tester) async {
      await pump(tester, 'We saw the the tide and the the sea.');
      expect(dots(tester), 2);
      await tester.tapAt(
        centerOf(tester, 24, 31),
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
      await tester.tap(row('Ignore here'));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(dots(tester), 1);
      ContextMenuController.removeAny();
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a touch tap on a mark hands the host the finding',
        (tester) async {
      final pumped = await pump(
        tester,
        'We saw the the tide.',
        platform: TargetPlatform.iOS,
      );
      await tester.tapAt(centerOf(tester, 7, 14));
      await tester.pump(const Duration(milliseconds: 400));
      expect(pumped.taps, hasLength(1));
      final tap = pumped.taps.single;
      expect(tap.words, 'the the');
      expect(tap.issue.ruleId, 'RepeatedWords');
      tap.apply('the');
      await tester.pump();
      expect(pumped.controller.document.blocks.single.text, 'We saw the tide.');
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a host sheet that took focus can still apply the fix',
        (tester) async {
      final pumped = await pump(
        tester,
        'We saw the the tide.',
        platform: TargetPlatform.iOS,
      );
      await tester.tapAt(centerOf(tester, 7, 14));
      await tester.pump(const Duration(milliseconds: 400));
      final tap = pumped.taps.single;
      // The sheet takes focus from the paragraph.
      pumped.focusNode.unfocus();
      await tester.pump();
      tap.apply('the');
      await tester.pump();
      expect(pumped.controller.document.blocks.single.text, 'We saw the tide.');
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a tap from a replaced controller changes nothing',
        (tester) async {
      final first = await pump(
        tester,
        'We saw the the tide.',
        platform: TargetPlatform.iOS,
      );
      await tester.tapAt(centerOf(tester, 7, 14));
      await tester.pump(const Duration(milliseconds: 400));
      final tap = first.taps.single;
      // Same block id and words, a new controller.
      final second = await pump(
        tester,
        'We saw the the tide.',
        platform: TargetPlatform.iOS,
      );
      tap.apply('the');
      await tester.pump();
      expect(second.controller.document.blocks.single.text,
          'We saw the the tide.');
      expect(
          first.controller.document.blocks.single.text, 'We saw the the tide.');
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a finding over hidden ** marks offers no fix', (tester) async {
      const text = 'We saw the **the tide**.';
      final pumped = await pump(
        tester,
        text,
        platform: TargetPlatform.iOS,
        hidden: const [(11, 13), (21, 23)],
      );
      expect(harper.asked, ['We saw the the tide.']);
      expect(dots(tester), 1);
      await tester.tapAt(centerOf(tester, 7, 16));
      await tester.pump(const Duration(milliseconds: 400));
      final tap = pumped.taps.single;
      expect(tap.issue.replacements, isEmpty);
      tap.apply('the');
      await tester.pump();
      expect(pumped.controller.document.blocks.single.text, text);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Edit rule leaves the marks until the rule changes',
        (tester) async {
      var edited = 0;
      suite.dispose();
      suite = HomericProofingSuite(
        sources: [
          HomericPhraseRules(const [
            HomericPhraseRule(find: 'utilize', replace: 'use'),
          ]),
        ],
        onEditRule: (_) => edited++,
      );
      final pumped = await pump(
        tester,
        'We utilize the van.',
        platform: TargetPlatform.iOS,
      );
      expect(washes(tester), 1);
      await tester.tapAt(centerOf(tester, 3, 10));
      await tester.pump(const Duration(milliseconds: 400));
      final action = pumped.taps.single.ruleAction!;
      expect(action.label, 'Edit rule');
      action.onPressed();
      await tester.pump();
      expect(edited, 1);
      expect(washes(tester), 1);
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
