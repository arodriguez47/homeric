import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/writing.dart';

const _style = TextStyle(fontSize: 14);
const _ink = Color(0xFF1B1B1B);
const _paper = Color(0xFFFFFFFF);

// Line focus learns where the caret's line runs from the paragraph's
// layout, which comes a frame after each keystroke. Until then the
// paragraph was all lit, so every keystroke flashed the paragraph's other
// lines bright for a frame: a flicker while typing.
void main() {
  testWidgets('a keystroke keeps the other lines of the paragraph dimmed', (
    tester,
  ) async {
    final document = Document(<Block>[
      Block(id: 'a', type: 'paragraph', runs: [InlineRun('Above.')]),
      Block(
        id: 'b',
        type: 'paragraph',
        runs: [
          InlineRun(
            'one two three four five six seven eight nine ten eleven '
            'twelve thirteen fourteen fifteen sixteen seventeen eighteen',
          ),
        ],
      ),
    ]);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(1, 7)),
    );
    final session = HomericTextInputSession(controller: controller);
    final dim = HomericFocusDimController(
      vsync: const TestVSync(),
      initialGranularity: HomericFocusGranularity.line,
    );
    addTearDown(() {
      dim.dispose();
      session.dispose();
      controller.dispose();
    });

    List<BlockTextRange> dimmed() => [
          for (final layer in dim.paintLayersFor(
            block: controller.document.blockById('b')!,
            editor: controller,
            foregroundColor: _ink,
            backgroundColor: _paper,
          ))
            BlockTextRange(layer.range.start.value, layer.range.end.value),
        ];

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Localizations(
          locale: const Locale('en'),
          delegates: const <LocalizationsDelegate<dynamic>>[
            DefaultWidgetsLocalizations.delegate,
          ],
          child: Overlay(
            initialEntries: <OverlayEntry>[
              OverlayEntry(
                builder: (_) => Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 200,
                    height: 400,
                    child: HomericEditableDocument.builder(
                      controller: controller,
                      inputSession: session,
                      estimatedBlockHeight: 44,
                      blockBuilder: (context, block, focusNode) =>
                          ListenableBuilder(
                        listenable: dim,
                        builder: (context, _) => HomericEditableParagraph(
                          controller: controller,
                          inputSession: session,
                          blockId: block.id,
                          focusNode: focusNode,
                          resolveStyle: (_) => _style,
                          derivePaintLayers: (b, _) => dim.paintLayersFor(
                            block: b,
                            editor: controller,
                            foregroundColor: _ink,
                            backgroundColor: _paper,
                          ),
                          overlayBuilder: (context, geometry) {
                            dim.observeGeometry(
                              geometry: geometry,
                              block: controller.document.blockById(block.id)!,
                              document: controller.document,
                              selection: controller.selection,
                            );
                            return const <Widget>[];
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final measured = dimmed();
    // The caret sits on the first line; the lines after it are dimmed.
    expect(measured, hasLength(1));
    expect(measured.single.start, greaterThan(7));

    for (var i = 0; i < 3; i++) {
      controller.replaceSelection('x');
      // What the frame after the keystroke paints, before that frame's
      // layout reports the line again.
      final carried = dimmed();
      expect(carried, hasLength(1), reason: 'keystroke $i lit the paragraph');
      expect(carried.single.start, measured.single.start + i + 1);
      await tester.pump();
      await tester.pump();
      expect(dimmed(), carried);
    }
  });
}
