// Test expectations ported from prosemirror-transform test/test-mapping.ts
// @ 662b7a937bafde19b7e2a83241dbc8888e257c89 (MIT (c) Marijn Haverbeke).
// The input triples, positions, biases, and expected values mirror the
// upstream suite case-for-case; the harness code itself is original Dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/src/transform/mapping.dart';
import 'package:homeric/src/transform/step_map.dart';

/// One mapping expectation: `from` maps to `to` under `assoc`; when [lossy]
/// is false the inverted mapping must take `to` back to `from`.
typedef MapCase = (int from, int to, int assoc, bool lossy);

MapCase c(int from, int to, [int assoc = 1, bool lossy = false]) =>
    (from, to, assoc, lossy);

void checkMapping(Mapping mapping, List<MapCase> cases) {
  final inverted = mapping.invert();
  for (final (from, to, assoc, lossy) in cases) {
    expect(mapping.map(from, assoc: assoc), to,
        reason: 'map($from, assoc: $assoc)');
    if (!lossy) {
      expect(inverted.map(to, assoc: assoc), from,
          reason: 'inverted.map($to, assoc: $assoc)');
    }
  }
}

void checkDel(Mapping mapping, int pos, int side, String flags) {
  final r = mapping.mapResult(pos, assoc: side);
  var found = '';
  if (r.deleted) found += 'd';
  if (r.deletedBefore) found += 'b';
  if (r.deletedAfter) found += 'a';
  if (r.deletedAcross) found += 'x';
  expect(found, flags, reason: 'flags for pos $pos, assoc $side');
}

/// Builds a [Mapping] from a mix of range triples (appended as [StepMap]s)
/// and `{from: to}` mirror-pair declarations, like the upstream `mk` helper.
Mapping mk(List<Object> args) {
  final mapping = Mapping();
  for (final arg in args) {
    if (arg is List<int>) {
      mapping.appendMap(StepMap(arg));
    } else if (arg is Map<int, int>) {
      arg.forEach(mapping.setMirror);
    } else {
      throw ArgumentError.value(arg, 'args', 'expected List<int> or Map');
    }
  }
  return mapping;
}

void main() {
  group('Mapping (ported from test-mapping.ts)', () {
    test('can map through a single insertion', () {
      checkMapping(
          mk([
            [2, 0, 4],
          ]),
          [
            c(0, 0),
            c(2, 6),
            c(2, 2, -1),
            c(3, 7),
          ]);
    });

    test('can map through a single deletion', () {
      checkMapping(
          mk([
            [2, 4, 0],
          ]),
          [
            c(0, 0),
            c(2, 2, -1),
            c(3, 2, 1, true),
            c(6, 2, 1),
            c(6, 2, -1, true),
            c(7, 3),
          ]);
    });

    test('can map through a single replace', () {
      checkMapping(
          mk([
            [2, 4, 4],
          ]),
          [
            c(0, 0),
            c(2, 2, 1),
            c(4, 6, 1, true),
            c(4, 2, -1, true),
            c(6, 6, -1),
            c(8, 8),
          ]);
    });

    test('can map through a mirrored delete-insert', () {
      checkMapping(
          mk([
            [2, 4, 0],
            [2, 0, 4],
            {0: 1},
          ]),
          [
            c(0, 0),
            c(2, 2),
            c(4, 4),
            c(6, 6),
            c(7, 7),
          ]);
    });

    test('can map through a mirrored insert-delete', () {
      checkMapping(
          mk([
            [2, 0, 4],
            [2, 4, 0],
            {0: 1},
          ]),
          [
            c(0, 0),
            c(2, 2),
            c(3, 3),
          ]);
    });

    test('can map through a delete-insert with an insert in between', () {
      checkMapping(
          mk([
            [2, 4, 0],
            [1, 0, 1],
            [3, 0, 4],
            {0: 2},
          ]),
          [
            c(0, 0),
            c(1, 2),
            c(4, 5),
            c(6, 7),
            c(7, 8),
          ]);
    });

    test('assigns the correct deleted flags when deletions happen before', () {
      checkDel(
          mk([
            [0, 2, 0],
          ]),
          2,
          -1,
          'db');
      checkDel(
          mk([
            [0, 2, 0],
          ]),
          2,
          1,
          'b');
      checkDel(
          mk([
            [0, 2, 2],
          ]),
          2,
          -1,
          'db');
      checkDel(
          mk([
            [0, 1, 0],
            [0, 1, 0],
          ]),
          2,
          -1,
          'db');
      checkDel(
          mk([
            [0, 1, 0],
          ]),
          2,
          -1,
          '');
    });

    test('assigns the correct deleted flags when deletions happen after', () {
      checkDel(
          mk([
            [2, 2, 0],
          ]),
          2,
          -1,
          'a');
      checkDel(
          mk([
            [2, 2, 0],
          ]),
          2,
          1,
          'da');
      checkDel(
          mk([
            [2, 2, 2],
          ]),
          2,
          1,
          'da');
      checkDel(
          mk([
            [2, 1, 0],
            [2, 1, 0],
          ]),
          2,
          1,
          'da');
      checkDel(
          mk([
            [3, 2, 0],
          ]),
          2,
          -1,
          '');
    });

    test('assigns the correct deleted flags when deletions happen across', () {
      checkDel(
          mk([
            [0, 4, 0],
          ]),
          2,
          -1,
          'dbax');
      checkDel(
          mk([
            [0, 4, 0],
          ]),
          2,
          1,
          'dbax');
      checkDel(
          mk([
            [0, 1, 0],
            [4, 1, 0],
            [0, 3, 0],
          ]),
          2,
          1,
          'dbax');
    });

    test('assigns the correct deleted flags when deletions happen around', () {
      checkDel(
          mk([
            [4, 1, 0],
            [0, 1, 0],
          ]),
          2,
          -1,
          '');
      checkDel(
          mk([
            [2, 1, 0],
            [0, 2, 0],
          ]),
          2,
          -1,
          'dba');
      checkDel(
          mk([
            [2, 1, 0],
            [0, 1, 0],
          ]),
          2,
          -1,
          'a');
      checkDel(
          mk([
            [3, 1, 0],
            [0, 2, 0],
          ]),
          2,
          -1,
          'db');
    });
  });

  group('Mapping composition', () {
    test('composed mapping equals sequential per-map application', () {
      final maps = [
        StepMap(const [2, 0, 4]),
        StepMap(const [8, 4, 0]),
        StepMap(const [0, 2, 1]),
      ];
      final mapping = Mapping();
      for (final m in maps) {
        mapping.appendMap(m);
      }
      for (var pos = 0; pos <= 14; pos++) {
        for (final assoc in const [-1, 1]) {
          var sequential = pos;
          for (final m in maps) {
            sequential = m.map(sequential, assoc: assoc);
          }
          expect(mapping.map(pos, assoc: assoc), sequential,
              reason: 'pos $pos, assoc $assoc');
          expect(mapping.mapResult(pos, assoc: assoc).pos, sequential,
              reason: 'mapResult pos $pos, assoc $assoc');
        }
      }
    });

    test('slice maps through a sub-range of the maps only', () {
      final mapping = Mapping()
        ..appendMap(StepMap(const [0, 0, 1]))
        ..appendMap(StepMap(const [10, 0, 2]));
      expect(mapping.map(11), 14);
      expect(mapping.slice(0, 1).map(11), 12);
      expect(mapping.slice(1).map(11), 13);
      expect(mapping.slice(1).map(5), 5);
    });

    test('appendMapping preserves and rebases mirror pairs', () {
      final inner = mk([
        [2, 4, 0],
        [2, 0, 4],
        {0: 1},
      ]);
      final outer = Mapping()..appendMap(StepMap(const [0, 0, 1]));
      outer.appendMapping(inner);
      expect(outer.getMirror(1), 2);
      expect(outer.getMirror(2), 1);
      // Offset by one, then through the mirrored delete-insert: identity + 1,
      // including positions strictly inside the deleted range (recovered).
      for (var pos = 0; pos <= 7; pos++) {
        expect(outer.map(pos), pos + 1, reason: 'pos $pos');
      }
    });

    test('invert flips mirror pairs', () {
      final mapping = mk([
        [2, 4, 0],
        [2, 0, 4],
        {0: 1},
      ]);
      final inverted = mapping.invert();
      expect(inverted.getMirror(0), 1);
      expect(inverted.getMirror(1), 0);
    });

    test('appending a mapping followed by its inverse is the identity', () {
      final mapping = mk([
        [2, 0, 4],
        [8, 2, 0],
      ]);
      final roundTrip = Mapping()
        ..appendMapping(mapping)
        ..appendMappingInverted(mapping);
      for (var pos = 0; pos <= 10; pos++) {
        if (mapping.mapResult(pos).deleted) continue;
        expect(roundTrip.map(pos), pos, reason: 'pos $pos');
      }
    });
  });

  group('Round-trip invertibility', () {
    test('invert().map(map(p)) == p for every non-deleted position', () {
      final mappings = [
        mk([
          [2, 0, 4],
        ]),
        mk([
          [2, 4, 0],
        ]),
        mk([
          [2, 4, 4],
        ]),
        mk([
          [2, 4, 0],
          [2, 0, 4],
          {0: 1},
        ]),
        mk([
          [2, 4, 0],
          [1, 0, 1],
          [3, 0, 4],
          {0: 2},
        ]),
      ];
      for (final mapping in mappings) {
        final inverted = mapping.invert();
        for (var pos = 0; pos <= 10; pos++) {
          for (final assoc in const [-1, 1]) {
            final result = mapping.mapResult(pos, assoc: assoc);
            if (result.deleted) continue;
            expect(inverted.map(result.pos, assoc: assoc), pos,
                reason: 'pos $pos, assoc $assoc');
          }
        }
      }
    });

    test('positions inside a mirrored delete recover to exact offsets', () {
      final mapping = mk([
        [2, 4, 0],
        [2, 0, 4],
        {0: 1},
      ]);
      // Interior positions of the deleted range survive exactly, and are not
      // reported as deleted across the mirrored pair.
      for (var pos = 3; pos <= 5; pos++) {
        expect(mapping.map(pos), pos);
        expect(mapping.mapResult(pos).deletedAcross, isFalse);
      }
    });

    test('unmirrored deletion still reports deletion', () {
      final mapping = mk([
        [2, 4, 0],
        [2, 0, 4],
      ]);
      // Same maps, no mirror pair: interior positions snap and are deleted.
      expect(mapping.mapResult(4).deleted, isTrue);
      expect(mapping.mapResult(4).deletedAcross, isTrue);
    });
  });

  group('Error paths', () {
    test('mapping a negative position throws', () {
      expect(() => Mapping().map(-1), throwsA(isA<PositionRangeError>()));
      expect(
          () => mk([
                [2, 4, 0],
              ]).map(-3),
          throwsA(isA<PositionRangeError>()));
      expect(() => Mapping().mapResult(-1), throwsA(isA<PositionRangeError>()));
    });

    test('appendMap with an out-of-range mirror index throws', () {
      final mapping = Mapping();
      expect(() => mapping.appendMap(StepMap(const [0, 1, 1]), 5),
          throwsA(isA<ArgumentError>()));
    });
  });
}
