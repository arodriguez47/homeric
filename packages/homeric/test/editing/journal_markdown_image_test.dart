import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

import '../transform/transform_test_utils.dart';

/// 1×1 PNG used by the fake HTTP client so [Image.network] can decode.
final Uint8List _onePixelPng = Uint8List.fromList(<int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);

/// Mirrors the journal host contract: literal source, live deriveDecorations,
/// and slotBuilder that paints [HomericMarkdownImageSlot] from the URL.
final class _JournalPaintMap {
  _JournalPaintMap();

  final Map<int, TextStyle> resolved = <int, TextStyle>{};
  int paintCalls = 0;

  static const layoutOnly = TextStyle(fontSize: 14, color: Color(0xFF000000));

  static const markStyles = <String, TextStyle>{
    'link': TextStyle(
      fontSize: 14,
      color: Color(0xFF0066CC),
      decoration: TextDecoration.underline,
    ),
  };

  void beginBuild() => resolved.clear();

  TextStyle resolve(RunStyleContext run) {
    var style = layoutOnly;
    for (final decoration in run.decorations) {
      final mark = markStyles[decoration.spec];
      if (mark != null) style = mark;
    }
    resolved[run.viewStart] = style;
    return layoutOnly;
  }

  TextStyle paint(TextSegment<TextStyle> segment) {
    paintCalls += 1;
    final style = resolved[segment.viewStart] ?? segment.style;
    paintedStyles[segment.viewStart] = style;
    return style;
  }

  final Map<int, TextStyle> paintedStyles = <int, TextStyle>{};

  TextStyle? styleAtViewOffset(int offset) => paintedStyles[offset];
}

/// Broken host path: link-only regex eats `[alt](url)` and leaves `!`.
List<Decoration> journalBrokenLinkOnlyDecorations(Block block) {
  final text = block.text;
  final result = <Decoration>[];

  void hideDelimiter(int start, int end) {
    result.add(markdownMarkHideReplacement(block.id, start, end));
  }

  void styleRange(int start, int end, String spec) {
    if (end > start) {
      result.add(Decoration.inline(block.id, start, end, spec: spec));
    }
  }

  for (final match in RegExp(r'\[([^\]]+)\]\(([^)]+)\)').allMatches(text)) {
    final label = match.group(1)!;
    hideDelimiter(match.start, match.start + 1);
    hideDelimiter(match.start + 1 + label.length, match.end);
    styleRange(match.start + 1, match.start + 1 + label.length, 'link');
  }

  return result;
}

/// Taste GO leave path: tokenize images, hide chrome, widget slot with URL.
List<Decoration> journalMarkdownImagePictureDecorations(Block block) {
  final result = <Decoration>[];
  for (final match in HomericMarkdownImage.allMatches(block.text)) {
    result.addAll(
      HomericMarkdownImage.leavePictureDecorations(block.id, match),
    );
  }
  for (final match in HomericMarkdownLink.allMatches(block.text)) {
    result.add(
        markdownMarkHideReplacement(block.id, match.start, match.labelStart));
    result.add(
        markdownMarkHideReplacement(block.id, match.closeStart, match.end));
    result.add(Decoration.inline(
      block.id,
      match.labelStart,
      match.labelEnd,
      spec: 'link',
    ));
  }
  return result;
}

Document _document(String text) => Document([
      Block(
        id: 'b',
        type: 'paragraph',
        runs: [if (text.isNotEmpty) InlineRun(text)],
      ),
    ]);

Widget _documentHarness({
  required HomericEditorController controller,
  required HomericTextInputSession session,
  required _JournalPaintMap paintMap,
  required List<Decoration> Function(Block block) deriveDecorations,
  SlotWidgetBuilder? slotBuilder,
}) =>
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
              builder: (_) => SizedBox(
                width: 320,
                child: HomericEditableDocument.builder(
                  controller: controller,
                  inputSession: session,
                  cacheExtent: 0,
                  estimatedBlockHeight: 44,
                  blockBuilder: (context, block, focusNode) =>
                      HomericEditableParagraph(
                    controller: controller,
                    inputSession: session,
                    blockId: block.id,
                    focusNode: focusNode,
                    deriveDecorations: deriveDecorations,
                    resolveStyle: paintMap.resolve,
                    paintStyler: paintMap.paint,
                    slotBuilder: slotBuilder,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

RenderHomericParagraph _paragraphRender(WidgetTester tester) =>
    tester.renderObject<RenderHomericParagraph>(
      find.descendant(
        of: find.byType(HomericEditableParagraph),
        matching: find.byType(HomericParagraph),
      ),
    );

Widget _imageSlotBuilder(SlotSegment<TextStyle> slot) {
  final spec = slot.spec;
  expect(spec, isA<HomericMarkdownImageSpec>());
  return HomericMarkdownImageSlot(
    key: const ValueKey<String>('markdown-image'),
    spec: spec! as HomericMarkdownImageSpec,
    width: 24,
    height: 16,
  );
}

void main() {
  group('characterization: link-only host path on images', () {
    test('naive link hide+style leaves !alt as a link in view text', () {
      final block = para('b', '![alt](https://x.test/i.png) ');
      final derived = deriveViewText(
        block,
        journalBrokenLinkOnlyDecorations(block),
      );
      expect(derived.viewText, '!alt ',
          reason: 'broken host path: ! survives; alt stays as styled label');
      expect(
        derived.styledRanges.any((r) => r.decoration.spec == 'link'),
        isTrue,
        reason: 'alt is still painted as a link',
      );
    });
  });

  group('image tokens: picture from markdown URL after leave', () {
    test('leavePictureDecorations hide chrome+alt and carry url in slot spec',
        () {
      final block = para('b', '![alt](https://x.test/i.png) ');
      final derived = deriveViewText(
        block,
        journalMarkdownImagePictureDecorations(block),
      );
      expect(derived.viewText, '$objectReplacementCharacter ');
      expect(derived.viewText.contains('!'), isFalse);
      expect(derived.viewText.contains('alt'), isFalse);
      expect(
        derived.styledRanges.any((r) => r.decoration.spec == 'link'),
        isFalse,
      );
      expect(derived.slots, hasLength(1));
      expect(
        derived.slots.single.decoration.spec,
        const HomericMarkdownImageSpec(
          url: 'https://x.test/i.png',
          alt: 'alt',
        ),
      );
    });

    testWidgets(
        'after leave, HomericMarkdownImageSlot paints Image.network from url',
        (tester) async {
      const imageUrl = 'https://x.test/i.png';
      const literal = '![alt]($imageUrl) ';
      final document = _document(literal);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(
          document.positionAt(0, literal.length),
        ),
      );
      final session = HomericTextInputSession(controller: controller);
      final paintMap = _JournalPaintMap();
      addTearDown(session.dispose);
      addTearDown(controller.dispose);

      await HttpOverrides.runZoned(() async {
        paintMap.beginBuild();
        await tester.pumpWidget(_documentHarness(
          controller: controller,
          session: session,
          paintMap: paintMap,
          deriveDecorations: journalMarkdownImagePictureDecorations,
          slotBuilder: _imageSlotBuilder,
        ));
        await tester.pump();
        // Let NetworkImage complete against the fake HTTP client.
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump();

        expect(_paragraphRender(tester).source.viewText,
            '$objectReplacementCharacter ');
        expect(find.textContaining('!alt'), findsNothing);
        expect(find.byType(HomericMarkdownImageSlot), findsOneWidget);

        final image = tester.widget<Image>(find.byType(Image));
        expect(image.image, isA<NetworkImage>());
        expect((image.image as NetworkImage).url, imageUrl,
            reason: 'picture must paint from the URL already in markdown');

        // Reveal then leave — picture returns; !alt-as-link does not.
        controller.setSelection(
          HomericSelection.collapsed(document.positionAt(0, 0)),
        );
        await tester.pump();
        controller.setSelection(
          HomericSelection.collapsed(
            document.positionAt(0, literal.length),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(_paragraphRender(tester).source.viewText,
            '$objectReplacementCharacter ');
        expect(find.byType(HomericMarkdownImageSlot), findsOneWidget);
        final imageAfterLeave = tester.widget<Image>(find.byType(Image));
        expect((imageAfterLeave.image as NetworkImage).url, imageUrl);
        expect(find.textContaining('!alt'), findsNothing);
      }, createHttpClient: (_) => _FakePngHttpClient());
    });
  });
}

/// Minimal HTTP client that serves [_onePixelPng] for any GET.
final class _FakePngHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _FakePngRequest(url);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakePngRequest implements HttpClientRequest {
  _FakePngRequest(this._url);

  final Uri _url;

  @override
  Future<HttpClientResponse> close() async => _FakePngResponse();

  @override
  Uri get uri => _url;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakePngResponse extends Stream<List<int>>
    implements HttpClientResponse {
  @override
  int get statusCode => HttpStatus.ok;

  @override
  int get contentLength => _onePixelPng.length;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.fromIterable(<List<int>>[_onePixelPng]).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
