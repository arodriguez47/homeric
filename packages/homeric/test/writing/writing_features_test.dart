import 'package:flutter/material.dart' hide Decoration;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/writing.dart';

Block _block(String text, {String id = 'b', String type = 'paragraph'}) =>
    Block(id: id, type: type, runs: [InlineRun(text)]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  HomericEditorController controllerFor(String text, {int? caret}) {
    final document = Document([_block(text)]);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(
        document.positionAt(0, caret ?? text.length),
      ),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  String textOf(HomericEditorController controller) =>
      controller.document.blocks.single.text;

  int offsetOf(HomericEditorController controller, int position) =>
      controller.blockOffsetForGlobalPosition('b', position);

  group('wrap shortcuts', () {
    (String, int, int) wrap(String text, int anchor, int head, String marker) {
      final controller = controllerFor(text);
      final document = controller.document;
      final prepared = HomericWrapShortcuts.prepareWrap(
        document,
        HomericSelection(
          anchor: document.positionAt(0, anchor),
          head: document.positionAt(0, head),
        ),
        marker,
      );
      expect(prepared, isNotNull);
      expect(controller.applyPreparedCommand(prepared!), isTrue);
      final selection = controller.selection!;
      return (
        textOf(controller),
        offsetOf(controller, selection.anchor),
        offsetOf(controller, selection.head),
      );
    }

    test('wraps the selection and keeps it on the words', () {
      expect(wrap('a word here', 2, 6, '**'), ('a **word** here', 4, 8));
      expect(wrap('a word here', 2, 6, '`'), ('a `word` here', 3, 7));
    });

    test('a backward selection stays backward', () {
      expect(wrap('a word here', 6, 2, '*'), ('a *word* here', 7, 3));
    });

    test('pressing it again takes the marker off', () {
      expect(wrap('a **word** here', 4, 8, '**'), ('a word here', 2, 6));
      expect(wrap('a ~~word~~ here', 4, 8, '~~'), ('a word here', 2, 6));
    });

    test('italic inside bold adds italic rather than unwrapping', () {
      expect(wrap('a **word** here', 4, 8, '*'), ('a ***word*** here', 5, 9));
    });

    test('a caret or a selection across blocks is left alone', () {
      final document = Document([_block('one'), _block('two', id: 'c')]);
      expect(
        HomericWrapShortcuts.prepareWrap(
          document,
          HomericSelection.collapsed(document.positionAt(0, 1)),
          '**',
        ),
        isNull,
      );
      expect(
        HomericWrapShortcuts.prepareWrap(
          document,
          HomericSelection(
            anchor: document.positionAt(0, 1),
            head: document.positionAt(1, 1),
          ),
          '**',
        ),
        isNull,
      );
    });

    test('the kit carries ⌘ and Ctrl bindings for each wrap', () {
      final bindings = HomericWritingKit.standard().commandBindings;
      final activators = bindings
          .map((binding) => binding.shortcut)
          .whereType<SingleActivator>()
          .toList();
      for (final key in [
        LogicalKeyboardKey.keyB,
        LogicalKeyboardKey.keyI,
        LogicalKeyboardKey.keyE,
        LogicalKeyboardKey.keyS,
      ]) {
        expect(
            activators.where((a) => a.trigger == key && a.meta), hasLength(1));
        expect(
          activators.where((a) => a.trigger == key && a.control),
          hasLength(1),
        );
      }
      expect(
        HomericWritingKit.standard(without: const {'wrapShortcuts'})
            .commandBindings,
        isEmpty,
      );
    });

    testWidgets('⌘B in the editor makes the selection bold', (tester) async {
      final controller = controllerFor('a word here');
      final session = HomericTextInputSession(controller: controller);
      addTearDown(session.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Material(
          child: SizedBox(
            width: 500,
            height: 300,
            child: HomericEditableDocument.builder(
              controller: controller,
              inputSession: session,
              commandBindings: HomericWritingKit.standard().commandBindings,
              estimatedBlockHeight: 44,
              blockBuilder: (context, block, focusNode) =>
                  HomericEditableParagraph(
                controller: controller,
                inputSession: session,
                blockId: block.id,
                focusNode: focusNode,
                resolveStyle: (_) => const TextStyle(fontSize: 16),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('homeric-editable-b')));
      await tester.pump();
      final document = controller.document;
      controller.setSelection(HomericSelection(
        anchor: document.positionAt(0, 2),
        head: document.positionAt(0, 6),
      ));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(textOf(controller), 'a **word** here');
    });
  });

  group('typography', () {
    test('the standard set keeps ligatures and kerning on', () {
      final features = HomericTypography.standard.bodyFeatures;
      expect(features, contains(const FontFeature.enable('liga')));
      expect(features, contains(const FontFeature.enable('kern')));
      expect(features, contains(const FontFeature.enable('calt')));
      expect(features, isNot(contains(const FontFeature('smcp'))));
    });

    test('figures, discretionary ligatures and small caps are opt in', () {
      const typography = HomericTypography(
        figures: HomericFigureStyle.oldStyle,
        discretionaryLigatures: true,
        smallCapsHeadings: true,
      );
      expect(typography.bodyFeatures,
          containsAll(const [FontFeature('onum'), FontFeature('dlig')]));
      expect(typography.headingFeatures, contains(const FontFeature('smcp')));
      expect(
        HomericTypography.standard.headingFeatures,
        isNot(contains(const FontFeature('smcp'))),
      );
    });

    test('a style keeps features the typography does not name', () {
      const base = TextStyle(fontFeatures: [FontFeature('ss01')]);
      final styled = HomericTypography.standard.body(base);
      expect(styled.fontFeatures, contains(const FontFeature('ss01')));
      expect(styled.fontFeatures, contains(const FontFeature.enable('liga')));
    });

    test('turning ligatures off says so explicitly', () {
      final features = const HomericTypography(ligatures: false).bodyFeatures;
      expect(features, contains(const FontFeature.disable('liga')));
    });
  });

  group('footnote punctuation', () {
    test('closing punctuation goes before a marker that ends at the caret', () {
      expect(HomericFootnotePunctuation.hopTarget('word^[n]', 8, '.'), 4);
      expect(HomericFootnotePunctuation.hopTarget('word[^1]', 8, ','), 4);
      expect(HomericFootnotePunctuation.hopTarget('word^[n]', 8, 'a'), isNull);
      expect(
          HomericFootnotePunctuation.hopTarget('word^[n] x', 10, '.'), isNull);
      expect(HomericFootnotePunctuation.hopTarget('`w^[n]`', 6, '.'), isNull);
    });

    test('typing a full stop after a footnote sets it before the marker', () {
      final controller = controllerFor('word^[n]');
      const HomericFootnotePunctuation().installOn(controller);
      controller.replaceSelection('.');
      expect(textOf(controller), 'word.^[n]');
      expect(offsetOf(controller, controller.selection!.head), 9);
      controller.replaceSelection(' more');
      expect(textOf(controller), 'word.^[n] more');
    });

    test('off, typing goes ahead as typed', () {
      final controller = controllerFor('word^[n]');
      HomericFootnotePunctuation(isActive: () => false).installOn(controller);
      controller.replaceSelection('.');
      expect(textOf(controller), 'word^[n].');
    });
  });

  group('list glyphs', () {
    test('bullets and numbers change with each level', () {
      expect([for (var d = 0; d < 4; d++) HomericListGlyphs.bullet(d)],
          ['●', '◯', '□', '●']);
      expect(HomericListGlyphs.number(3, 0), '3');
      expect(HomericListGlyphs.number(3, 1), 'c');
      expect(HomericListGlyphs.number(4, 2), 'IV');
      expect(HomericListGlyphs.latin(27), 'aa');
      expect(HomericListGlyphs.roman(1994), 'MCMXCIV');
    });

    test('live preview draws the glyph for the depth', () {
      String mark(String text, {HomericSyntax syntax = HomericSyntax.all}) {
        final d = syntax
            .decorationsFor(_block(text))
            .singleWhere((d) => d.kind == DecorationKind.replace);
        return (d.spec! as ReplacementContent).text;
      }

      expect(mark('- top'), '●');
      expect(mark('  - nested'), '◯');
      expect(mark('    - deeper'), '□');
      expect(mark('  2. nested'), 'b.');
      expect(mark('  - nested', syntax: const HomericSyntax(listGlyphs: false)),
          '•');
    });
  });

  group('writing width', () {
    test('steps run narrow to full', () {
      expect(HomericWritingWidth.narrow.measure, 520);
      expect(HomericWritingWidth.standard.measure, 640);
      expect(HomericWritingWidth.wide.measure, 800);
      expect(HomericWritingWidth.full.measure, double.infinity);
      expect(HomericWritingWidth.narrow.narrower, isNull);
      expect(HomericWritingWidth.standard.wider, HomericWritingWidth.wide);
      expect(HomericWritingWidth.full.wider, isNull);
    });
  });

  group('links', () {
    test('matches targets and labels', () {
      final m =
          HomericWikiLinks.allMatches('See [[Orchard|the walk]] now').single;
      expect(m.target, 'Orchard');
      expect(m.hasLabel, isTrue);
      expect('See [[Orchard|the walk]] now'.substring(m.labelStart, m.labelEnd),
          'the walk');
      expect(HomericWikiLinks.allMatches('[[  ]] and [[x]]'), hasLength(1));
    });

    test('keys normalise case and space', () {
      expect(HomericWikiLinks.key('  The   Orchard '), 'the orchard');
    });

    test('a link is written with a clean alias', () {
      expect(HomericWikiLinks.linkTo('n1'), '[[n1]]');
      expect(HomericWikiLinks.linkTo('n1', alias: 'a [b] | c'), '[[n1|a b c]]');
    });

    test('renaming a link changes its words, never its target', () {
      HomericWikiLinkMatch link(String text) =>
          HomericWikiLinks.allMatches(text).single;
      expect(link('[[n1]]').withWords('the walk'), '[[n1|the walk]]');
      expect(link('[[n1|old]]').withWords('  new  words '), '[[n1|new words]]');
      // Brackets, bars and line breaks would break the link: they read
      // as spaces.
      expect(link('[[n1|old]]').withWords('a [b] |\nc'), '[[n1|a b c]]');
      // Blank words, or the target again, give the plain link back.
      expect(link('[[n1|old]]').withWords(''), '[[n1]]');
      expect(link('[[n1|old]]').withWords(null), '[[n1]]');
      expect(link('[[The Orchard|walk]]').withWords('the  orchard'),
          '[[The Orchard]]');
      // The target keeps its own spelling.
      expect(link('[[ Orchard ]]').withWords('walk'), '[[ Orchard |walk]]');
    });

    test('readable text shows labels and titles', () {
      String? title(String target) => target == 'n1' ? 'The orchard' : null;
      expect(
        HomericWikiLinks.readable('[[n1]], [[n2|two]] and [[n3]]', title),
        'The orchard, two and n3',
      );
    });

    test('a linked title reads whole unless a cap is asked for', () {
      const long = 'The old orchard by the river where the apple trees grow';
      String? title(String _) => long;
      expect(HomericWikiLinks.readable('see [[n1]]', title), 'see $long');
      expect(
        HomericWikiLinks.readable('see [[n1]]', title, maxTitle: 14),
        'see The old orchar…',
      );
    });

    test('the [[ being typed is a query until it closes', () {
      expect(
        HomericLinkQuery.at('b', 'see [[orch', 10),
        const HomericLinkQuery(blockId: 'b', start: 4, end: 10, target: 'orch'),
      );
      expect(HomericLinkQuery.at('b', 'see [[orch|walk', 15)!.alias, 'walk');
      expect(HomericLinkQuery.at('b', 'see [[orch]]', 10), isNull);
      expect(HomericLinkQuery.at('b', 'see [[[orch', 11), isNull);
    });
  });

  group('to-dos', () {
    test('lines tick and untick', () {
      final m = HomericChecklists.line.firstMatch('[x] done')!;
      expect(HomericChecklists.isDone('[x] done', m), isTrue);
      expect(HomericChecklists.toggled('[ ]'), '[x]');
      expect(HomericChecklists.toggled('- [x]'), '- [ ]');
      expect(HomericChecklists.toggled('☐'), '☑');
      expect(HomericChecklists.toggled('nope'), isNull);
    });

    test('live preview puts a box at the start of the hidden marker', () {
      final ds = HomericSyntax.all.decorationsFor(_block('[ ] task')).toList();
      final box = ds.singleWhere((d) => d.spec is HomericChecklistSpec);
      expect(box.start, 0);
      expect(
        HomericSyntax.toggledChecklistMarker(
          '[ ] task',
          box.spec! as HomericChecklistSpec,
        ),
        '[x]',
      );
    });
  });

  group('syntax switches', () {
    List<Decoration> derive(String text, HomericSyntax syntax) =>
        syntax.decorationsFor(_block(text)).toList();

    test('a divider line is drawn as a rule, its source shown at the caret',
        () {
      expect(
        derive('---', HomericSyntax.all).map((d) => d.spec),
        contains(const HomericDividerSpec()),
      );
      expect(
        HomericSyntax.all
            .decorationsFor(_block('---'), caret: 3)
            .map((d) => d.spec),
        isNot(contains(const HomericDividerSpec())),
      );
      expect(HomericDivider.isTyped('—-'), isTrue);
    });

    test('quote lines hide their marker and mark their words', () {
      bool quoted(String text) => derive(text, HomericSyntax.all)
          .map((d) => d.spec)
          .whereType<HomericMarkSpec>()
          .any((s) => s.kind == HomericMarkKind.quote);
      final ds = derive('> one\n>\n> two', HomericSyntax.all);
      final quotes = ds
          .where((d) =>
              d.spec is HomericMarkSpec &&
              (d.spec as HomericMarkSpec).kind == HomericMarkKind.quote)
          .map((d) => (d.start, d.end))
          .toList();
      expect(quotes, [(2, 5), (10, 13)]);
      expect(
          ds.where(isMarkdownMarkHideDecoration).map((d) => (d.start, d.end)),
          containsAll([(0, 2), (6, 7), (8, 10)]));
      expect(quoted('a > b'), isFalse);
      expect(quoted('>b'), isFalse);
      expect(HomericSyntax.isQuote('> a\n> b'), isTrue);
      expect(HomericSyntax.isQuote('> a\nb'), isFalse);
      expect(HomericSyntax.isCommentLines('%% a\n%% b'), isTrue);
      expect(HomericSyntax.isCommentLines('%% a\n> b'), isFalse);
    });

    test('a comment line is its own kind, apart from asides and quotes', () {
      Set<HomericMarkKind> kinds(String text) => derive(text, HomericSyntax.all)
          .map((d) => d.spec)
          .whereType<HomericMarkSpec>()
          .map((s) => s.kind)
          .toSet();
      expect(kinds('%% to self'), {HomericMarkKind.commentLine});
      expect(kinds('a ++aside++'), contains(HomericMarkKind.comment));
      expect(
          kinds('a ++aside++'), isNot(contains(HomericMarkKind.commentLine)));
    });

    test('each form can be switched off', () {
      bool has(
              String text, HomericSyntax syntax, bool Function(Object?) test) =>
          derive(text, syntax).any((d) => test(d.spec));
      bool kind(Object? spec, HomericMarkKind kind) =>
          spec is HomericMarkSpec && spec.kind == kind;

      expect(
          has('---', const HomericSyntax(dividers: false),
              (s) => s is HomericDividerSpec),
          isFalse);
      expect(
          has('a #tag', const HomericSyntax(tags: false),
              (s) => kind(s, HomericMarkKind.tag)),
          isFalse);
      expect(
          has('a #tag', HomericSyntax.all, (s) => kind(s, HomericMarkKind.tag)),
          isTrue);
      expect(
          has('[[n]]', const HomericSyntax(wikiLinks: false),
              (s) => s is HomericWikiLinkSpec),
          isFalse);
      expect(
          has('a^[n]', const HomericSyntax(footnotes: false),
              (s) => s is HomericFootnoteSpec),
          isFalse);
      expect(
          has('{{a|b}}', const HomericSyntax(annotations: false),
              (s) => s is HomericAnnotationNoteSpec),
          isFalse);
      expect(
          has('**b**', const HomericSyntax(markdown: false),
              (s) => kind(s, HomericMarkKind.bold)),
          isFalse);
      expect(
          has('~~s~~', const HomericSyntax(strike: false),
              (s) => kind(s, HomericMarkKind.strike)),
          isFalse);
      expect(
          has('++a++', const HomericSyntax(comments: false),
              (s) => kind(s, HomericMarkKind.comment)),
          isFalse);
      expect(
          has('^^Once', const HomericSyntax(dropCaps: false),
              (s) => kind(s, HomericMarkKind.dropCap)),
          isFalse);
      expect(
          has('(img a.png)', const HomericSyntax(images: false),
              (s) => s is HomericImageSpec),
          isFalse);
    });

    test('paint washes tags and highlights and underlines annotations', () {
      final ds = derive('a #tag ==hi== {{p|n}}', HomericSyntax.all);
      final layers = const HomericSyntaxPaint().layersFor(ds);
      expect(layers, hasLength(3));
      expect(layers.where((l) => l.band == PaintBand.overlay), hasLength(1));
    });
  });
}
