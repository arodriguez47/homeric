import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/src/render/homeric_paragraph.dart';

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
}
