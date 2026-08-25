import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/src/render/homeric_paragraph.dart';

import '../transform/transform_test_utils.dart';
import 'render_test_utils.dart';

Future<void> _sendFontsChange(WidgetTester tester) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.system.name,
    SystemChannels.system.codec
        .encodeMessage(<String, dynamic>{'type': 'fontsChange'}),
    (_) {},
  );
}

Widget _cachedParagraph(
  HomericParagraphLayoutCache cache,
  String key,
  String text,
) =>
    harness(
      HomericParagraphLayoutCacheScope(
        cache: cache,
        cacheKey: key,
        child: HomericParagraph(source: sourceOf(text)),
      ),
    );

Future<void> _detach(
  WidgetTester tester,
  HomericParagraphLayoutCache cache,
  String key,
  String text,
) async {
  await tester.pumpWidget(_cachedParagraph(cache, key, text));
  await tester.pumpWidget(const SizedBox.shrink());
}

/// Nexus journal pattern: resolveStyle stores the desired mark style and
/// returns a layout-only handle; paintStyler reads the map at shape time.
final class _PaintResolveMap {
  final Map<int, TextStyle> resolved = <int, TextStyle>{};
  final Set<Color> paintedMarkColors = <Color>{};
  int paintCalls = 0;

  static const layoutOnly = TextStyle(fontSize: 14, color: Color(0xFF000000));

  static const markStyles = <String, TextStyle>{
    'bold': TextStyle(fontSize: 14, color: Color(0xFF100000)),
    'italic': TextStyle(fontSize: 14, color: Color(0xFF010000)),
    'code': TextStyle(fontSize: 14, color: Color(0xFF001000)),
    'strike': TextStyle(fontSize: 14, color: Color(0xFF000100)),
    'link': TextStyle(fontSize: 14, color: Color(0xFF000010)),
  };

  void beginBuild() => resolved.clear();

  TextStyle resolve(RunStyleContext run) {
    TextStyle style = layoutOnly;
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
    final color = style.color;
    if (color != null && color != layoutOnly.color) {
      paintedMarkColors.add(color);
    }
    return style;
  }
}

ParagraphSource<TextStyle> _fiveMarkSource(_PaintResolveMap map) {
  // "B I C S L" — one letter per mark, spaces plain.
  const text = 'B I C S L';
  return ParagraphSource.build(
    block: para('b', text),
    decorations: [
      Decoration.inline('b', 0, 1, spec: 'bold'),
      Decoration.inline('b', 2, 3, spec: 'italic'),
      Decoration.inline('b', 4, 5, spec: 'code'),
      Decoration.inline('b', 6, 7, spec: 'strike'),
      Decoration.inline('b', 8, 9, spec: 'link'),
    ],
    resolveStyle: map.resolve,
  );
}

Widget _cachedPaintMapped(
  HomericParagraphLayoutCache cache,
  ParagraphSource<TextStyle> source,
  PaintOnlyStyler paintStyler,
) =>
    harness(
      HomericParagraphLayoutCacheScope(
        cache: cache,
        cacheKey: 'b',
        child: HomericParagraph(source: source, paintStyler: paintStyler),
      ),
    );

void main() {
  testWidgets('entry and text budgets evict least-recently released shapes',
      (tester) async {
    final entryCache = HomericParagraphLayoutCache(
      maximumEntries: 2,
      maximumTextCodeUnits: 100,
    )..retainKeys(<Object>{'a', 'b', 'c'});
    addTearDown(entryCache.dispose);

    await _detach(tester, entryCache, 'a', 'aaaa');
    await _detach(tester, entryCache, 'b', 'bbbb');
    await _detach(tester, entryCache, 'c', 'cccc');
    expect(entryCache.entryCount, 2);
    expect(entryCache.textCodeUnits, 8);

    final evictedProbe = HomericParagraphLayoutProbe.start();
    await tester.pumpWidget(_cachedParagraph(entryCache, 'a', 'aaaa'));
    final evicted = evictedProbe.stop();
    expect(evicted.countFor(HomericParagraphLayoutCategory.live), 1,
        reason: 'the oldest entry must shape again after eviction');
    await tester.pumpWidget(const SizedBox.shrink());

    final textCache = HomericParagraphLayoutCache(
      maximumEntries: 10,
      maximumTextCodeUnits: 6,
    )..retainKeys(<Object>{'a', 'b'});
    addTearDown(textCache.dispose);
    await _detach(tester, textCache, 'a', 'aaaa');
    await _detach(tester, textCache, 'b', 'bbbb');
    expect(textCache.entryCount, 1);
    expect(textCache.textCodeUnits, 4);
  });

  testWidgets('mounted font notification clears every detached shape',
      (tester) async {
    final cache = HomericParagraphLayoutCache(
      maximumEntries: 4,
      maximumTextCodeUnits: 100,
    )..retainKeys(<Object>{'a', 'b', 'mounted'});
    addTearDown(cache.dispose);
    await _detach(tester, cache, 'a', 'aaaa');
    await _detach(tester, cache, 'b', 'bbbb');
    expect(cache.entryCount, 2);

    await tester.pumpWidget(_cachedParagraph(cache, 'mounted', 'mounted'));
    await _sendFontsChange(tester);
    await tester.pump();
    expect(cache.entryCount, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    final probe = HomericParagraphLayoutProbe.start();
    await tester.pumpWidget(_cachedParagraph(cache, 'a', 'aaaa'));
    final report = probe.stop();
    expect(report.countFor(HomericParagraphLayoutCategory.live), 1);
  });

  testWidgets(
      'cached paint after cleared resolve map still styles the five marks',
      (tester) async {
    final cache = HomericParagraphLayoutCache(
      maximumEntries: 4,
      maximumTextCodeUnits: 100,
    )..retainKeys(<Object>{'b'});
    addTearDown(cache.dispose);

    final map = _PaintResolveMap();
    // Stable tear-off so the layout cache accepts the remounted shape.
    final PaintOnlyStyler paintStyler = map.paint;

    // Poison the cache: shape while the resolve map is empty so the baked
    // ui.Paragraph carries layoutOnly (plain) styles for every mark run.
    final poisoned = _fiveMarkSource(map);
    map.beginBuild();
    map.paintCalls = 0;
    await tester.pumpWidget(_cachedPaintMapped(cache, poisoned, paintStyler));
    expect(map.paintCalls, greaterThan(0));
    expect(map.resolved, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(cache.entryCount, 1);

    // Fresh frame: beginBuild cleared the map; resolveStyle refills it;
    // remount hits the layout cache. Cached paint must still consult
    // paintStyler so the five marks are not left as layoutOnly.
    map.beginBuild();
    map.paintCalls = 0;
    map.paintedMarkColors.clear();
    final fresh = _fiveMarkSource(map);
    expect(
      map.resolved.values
          .where((style) => style != _PaintResolveMap.layoutOnly),
      hasLength(5),
      reason: 'resolveStyle must have stored bold/italic/code/strike/link',
    );
    expect(cache.entryCount, 1);
    await tester.pumpWidget(_cachedPaintMapped(cache, fresh, paintStyler));

    expect(map.paintCalls, greaterThan(0),
        reason: 'cache hit must still apply paintStyler after resolve refill');
    expect(
      map.paintedMarkColors,
      _PaintResolveMap.markStyles.values.map((style) => style.color!).toSet(),
      reason: 'bold, italic, code, strike, and link must paint as themselves',
    );
  });
}
