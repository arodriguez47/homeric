import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  HomericEditorController controllerFor(String text, {int? caret}) {
    final document = Document([
      Block(id: 'b', type: 'paragraph', runs: [InlineRun(text)]),
    ]);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(
        document.positionAt(0, caret ?? text.length),
      ),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  testWidgets('typing the closing braces strips them and requests a note',
      (tester) async {
    final requests = <HomericInlineAnnotationRequest>[];
    final controller = controllerFor('I felt {{curiosity} today', caret: 19);
    HomericInlineAnnotationShortcut(onAnnotate: requests.add)
        .installOn(controller);

    expect(controller.replaceSelection('}'), isTrue);

    expect(controller.document.blocks.single.text, 'I felt curiosity today');
    expect(
      controller.selection,
      HomericSelection.collapsed(controller.document.positionAt(0, 16)),
    );
    expect(requests, isEmpty, reason: 'the host hears after layout');
    await tester.pump();
    expect(requests, <HomericInlineAnnotationRequest>[
      const HomericInlineAnnotationRequest(
        blockId: 'b',
        start: 7,
        end: 16,
        text: 'curiosity',
      ),
    ]);
  });

  testWidgets('a note after | leaves the text and rides the request',
      (tester) async {
    final requests = <HomericInlineAnnotationRequest>[];
    const typed = 'I felt {{curiosity| the good kind } today';
    final controller = controllerFor(typed, caret: typed.indexOf('}') + 1);
    HomericInlineAnnotationShortcut(onAnnotate: requests.add)
        .installOn(controller);

    expect(controller.replaceSelection('}'), isTrue);

    expect(controller.document.blocks.single.text, 'I felt curiosity today');
    expect(
      controller.selection,
      HomericSelection.collapsed(controller.document.positionAt(0, 16)),
    );
    await tester.pump();
    expect(requests, <HomericInlineAnnotationRequest>[
      const HomericInlineAnnotationRequest(
        blockId: 'b',
        start: 7,
        end: 16,
        text: 'curiosity',
        note: 'the good kind',
      ),
    ]);

    controller.undo();
    expect(controller.document.blocks.single.text,
        'I felt {{curiosity| the good kind } today');
  });

  testWidgets('an empty note after | is no note', (tester) async {
    for (final text in <String>['{{words|}', '{{words|  }']) {
      final requests = <HomericInlineAnnotationRequest>[];
      final controller = controllerFor(text);
      HomericInlineAnnotationShortcut(onAnnotate: requests.add)
          .installOn(controller);

      controller.replaceSelection('}');
      await tester.pump();

      expect(controller.document.blocks.single.text, 'words', reason: text);
      expect(requests.single.note, isNull, reason: text);
      expect(requests.single.text, 'words', reason: text);
    }
  });

  testWidgets('the note may hold a further |', (tester) async {
    final requests = <HomericInlineAnnotationRequest>[];
    final controller = controllerFor('{{a|b|c}');
    HomericInlineAnnotationShortcut(onAnnotate: requests.add)
        .installOn(controller);

    controller.replaceSelection('}');
    await tester.pump();

    expect(controller.document.blocks.single.text, 'a');
    expect(requests.single.note, 'b|c');
  });

  testWidgets('one undo brings the braces back', (tester) async {
    final controller = controllerFor('{{note}');
    HomericInlineAnnotationShortcut(onAnnotate: (_) {}).installOn(controller);

    controller.replaceSelection('}');
    expect(controller.document.blocks.single.text, 'note');

    controller.undo();
    expect(controller.document.blocks.single.text, '{{note}');
    await tester.pump();
  });

  testWidgets('ignores empty, blank, nested and unopened braces',
      (tester) async {
    for (final text in <String>[
      '{{}',
      '{{  }',
      '{{a{b}',
      'a}',
      '{a}',
      '{{|note}',
      '{{ |note}'
    ]) {
      final requests = <HomericInlineAnnotationRequest>[];
      final controller = controllerFor(text);
      HomericInlineAnnotationShortcut(onAnnotate: requests.add)
          .installOn(controller);

      controller.replaceSelection('}');
      await tester.pump();

      expect(controller.document.blocks.single.text, '$text}', reason: text);
      expect(requests, isEmpty, reason: text);
    }
  });

  testWidgets('uninstalling stops the shortcut', (tester) async {
    final controller = controllerFor('{{note}');
    final remove = HomericInlineAnnotationShortcut(onAnnotate: (_) {})
        .installOn(controller);
    remove();

    controller.replaceSelection('}');

    expect(controller.document.blocks.single.text, '{{note}}');
  });
}
