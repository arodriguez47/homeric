// The iOS keyboard draws light unless told otherwise, so an app drawn dark
// got a light keyboard under its dark editor. Editable paragraphs hand the
// input session their theme's brightness.

import 'package:flutter/material.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

void main() {
  testWidgets('the keyboard follows the theme around the editor',
      (tester) async {
    final controller = HomericEditorController(
      document: Document(<Block>[
        Block(id: 'a', type: 'paragraph', runs: <InlineRun>[InlineRun('Hi')]),
      ]),
    );
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    Widget app(Brightness brightness) => MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Material(
            child: HomericEditableParagraph(
              controller: controller,
              inputSession: session,
              blockId: 'a',
              resolveStyle: (_) => const TextStyle(fontSize: 14),
            ),
          ),
        );

    await tester.pumpWidget(app(Brightness.dark));
    expect(session.keyboardAppearance, Brightness.dark);

    // MaterialApp animates a theme change; brightness flips at its midpoint.
    await tester.pumpWidget(app(Brightness.light));
    await tester.pumpAndSettle();
    expect(session.keyboardAppearance, Brightness.light);
  });
}
