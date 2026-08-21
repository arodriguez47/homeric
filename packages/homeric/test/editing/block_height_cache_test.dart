import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/src/editing/block_height_cache.dart';

void main() {
  test('measured heights update prefix offsets without forcing unknown rows',
      () {
    final cache = BlockHeightCache(estimatedHeight: 20)
      ..replaceOrder(<String>['a', 'b', 'c', 'd']);

    expect(cache.offsetBefore(3), 60);
    expect(cache.indexAtOffset(39), 1);
    expect(
      cache.record(
        cache.prepareMeasurement(
          blockId: 'b',
          documentRevision: 1,
          layoutSignature: 'wide',
        ),
        50,
      ),
      const BlockHeightChange(index: 1, delta: 30),
    );
    expect(cache.offsetBefore(3), 90);
    expect(cache.indexAtOffset(39), 1);
    expect(cache.indexAtOffset(70), 2);
  });

  test('stale layout and edit witnesses cannot overwrite current height', () {
    final cache = BlockHeightCache(estimatedHeight: 20)
      ..replaceOrder(<String>['a', 'b']);
    final old = cache.prepareMeasurement(
      blockId: 'a',
      documentRevision: 1,
      layoutSignature: 'wide',
    );
    final current = cache.prepareMeasurement(
      blockId: 'a',
      documentRevision: 2,
      layoutSignature: 'narrow',
    );

    expect(cache.record(old, 80), isNull);
    expect(cache.record(current, 40), isNotNull);
    expect(cache.heightFor('a'), 40);
    expect(cache.record(current, 40.1), isNull,
        reason: 'subpixel noise does not schedule anchor correction');
  });

  test('unchanged layout retains its in-flight measurement witness', () {
    final cache = BlockHeightCache(estimatedHeight: 20)
      ..replaceOrder(<String>['a']);
    final pending = cache.prepareMeasurement(
      blockId: 'a',
      documentRevision: 1,
      layoutSignature: 'wide',
    );

    final afterSelectionNotification = cache.prepareMeasurement(
      blockId: 'a',
      documentRevision: 2,
      layoutSignature: 'wide',
    );

    expect(afterSelectionNotification, same(pending));
    expect(cache.record(pending, 48), isNotNull);
    expect(cache.heightFor('a'), 48);
  });

  test('order replacement retains current IDs and evicts removed entries', () {
    final cache = BlockHeightCache(estimatedHeight: 20)
      ..replaceOrder(<String>['a', 'b', 'c']);
    cache.record(
      cache.prepareMeasurement(
        blockId: 'b',
        documentRevision: 1,
        layoutSignature: 'layout',
      ),
      45,
    );

    cache.replaceOrder(<String>['c', 'b', 'd']);

    expect(cache.heightFor('a'), isNull);
    expect(cache.heightFor('b'), 45);
    expect(cache.offsetBefore(2), 65);
    expect(cache.retainedEntryCount, 1);
  });

  test('global layout invalidation drops measurements but keeps order', () {
    final cache = BlockHeightCache(estimatedHeight: 20)
      ..replaceOrder(<String>['a', 'b']);
    cache.record(
      cache.prepareMeasurement(
        blockId: 'a',
        documentRevision: 1,
        layoutSignature: 'wide',
      ),
      40,
    );

    cache.invalidateAll();

    expect(cache.retainedEntryCount, 0);
    expect(cache.offsetBefore(2), 40);
  });
}
