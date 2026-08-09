// Behavior spec derived from prosemirror-transform src/map.ts and
// test/test-mapping.ts @ 662b7a937bafde19b7e2a83241dbc8888e257c89
// (MIT (c) Marijn Haverbeke). Expected values follow ProseMirror's
// position-mapping semantics; the test code is original Dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/src/transform/step_map.dart';

void main() {
  group('StepMap.map', () {
    test('insertion shifts positions after it and biases at the point', () {
      final map = StepMap(const [2, 0, 4]);
      expect(map.map(0), 0);
      expect(map.map(1), 1);
      expect(map.map(2), 6); // default assoc = 1: after the insertion
      expect(map.map(2, assoc: -1), 2); // before the insertion
      expect(map.map(3), 7);
    });

    test('deletion collapses the range and shifts what follows', () {
      final map = StepMap(const [2, 4, 0]);
      expect(map.map(0), 0);
      expect(map.map(2), 2);
      expect(map.map(2, assoc: -1), 2);
      expect(map.map(3), 2); // strictly inside: snaps to the collapse point
      expect(map.map(5, assoc: -1), 2);
      expect(map.map(6), 2);
      expect(map.map(7), 3);
    });

    test('boundary positions of a replacement honor assoc', () {
      final map = StepMap(const [2, 4, 4]);
      // At the start of the replaced range the position stays put regardless
      // of assoc; at the end it lands after the new content regardless.
      expect(map.map(2, assoc: 1), 2);
      expect(map.map(2, assoc: -1), 2);
      expect(map.map(6, assoc: 1), 6);
      expect(map.map(6, assoc: -1), 6);
      // Strictly inside, assoc chooses the side.
      expect(map.map(4, assoc: 1), 6);
      expect(map.map(4, assoc: -1), 2);
    });

    test('zero-size range (pure insertion point) snaps only by assoc', () {
      final map = StepMap(const [2, 0, 0]);
      expect(map.map(2, assoc: 1), 2);
      expect(map.map(2, assoc: -1), 2);
      expect(map.map(5), 5);
    });

    test('adjacent triples: the earlier range claims the shared boundary', () {
      final map = StepMap(const [2, 2, 4, 4, 2, 0]);
      expect(map.map(0), 0);
      expect(map.map(2, assoc: 1), 2);
      expect(map.map(2, assoc: -1), 2);
      expect(map.map(3, assoc: 1), 6);
      expect(map.map(3, assoc: -1), 2);
      expect(map.map(4, assoc: 1), 6);
      expect(map.map(4, assoc: -1), 6);
      expect(map.map(5, assoc: 1), 6);
      expect(map.map(5, assoc: -1), 6);
      expect(map.map(6, assoc: 1), 6);
      expect(map.map(7), 7);
    });
  });

  group('StepMap.mapResult deletion flags', () {
    test('one-sided deletion before the position', () {
      final r = StepMap(const [0, 2, 0]).mapResult(2, assoc: -1);
      expect(r.deleted, isTrue);
      expect(r.deletedBefore, isTrue);
      expect(r.deletedAfter, isFalse);
      expect(r.deletedAcross, isFalse);
    });

    test('one-sided deletion after the position', () {
      final r = StepMap(const [2, 2, 0]).mapResult(2, assoc: 1);
      expect(r.deleted, isTrue);
      expect(r.deletedBefore, isFalse);
      expect(r.deletedAfter, isTrue);
      expect(r.deletedAcross, isFalse);
    });

    test('deletedAcross only when content on both sides is removed', () {
      for (final assoc in const [-1, 1]) {
        final r = StepMap(const [0, 4, 0]).mapResult(2, assoc: assoc);
        expect(r.deleted, isTrue, reason: 'assoc $assoc');
        expect(r.deletedBefore, isTrue, reason: 'assoc $assoc');
        expect(r.deletedAfter, isTrue, reason: 'assoc $assoc');
        expect(r.deletedAcross, isTrue, reason: 'assoc $assoc');
      }
    });

    test('untouched positions carry no flags', () {
      final r = StepMap(const [4, 2, 0]).mapResult(2);
      expect(r.deleted, isFalse);
      expect(r.deletedBefore, isFalse);
      expect(r.deletedAfter, isFalse);
      expect(r.deletedAcross, isFalse);
      expect(r.recoverValue, isNull);
    });
  });

  group('StepMap recover values', () {
    test('a deleted interior position gets a recover value', () {
      final map = StepMap(const [2, 4, 0]);
      final r = map.mapResult(4);
      expect(r.recoverValue, isNotNull);
    });

    test('recover on the inverted map restores the exact offset', () {
      final map = StepMap(const [2, 4, 0]);
      for (var pos = 3; pos <= 5; pos++) {
        final r = map.mapResult(pos);
        // The mirror image of this deletion is the matching insertion; its
        // recover() must land at start + the original offset into the range.
        final mirror = StepMap(const [2, 0, 4]);
        expect(mirror.recover(r.recoverValue!), pos, reason: 'pos $pos');
      }
    });

    test('recover accounts for size diffs of earlier ranges', () {
      final map = StepMap(const [0, 1, 3, 6, 2, 0]);
      final r = map.mapResult(7);
      expect(r.recoverValue, isNotNull);
      // Range index 1 starts at 6 in old coordinates; earlier range grew by
      // 2, so recover lands at 6 + 2 + offset(1) = 9.
      expect(map.recover(r.recoverValue!), 9);
    });

    test('positions at the kept edge get no recover value', () {
      final map = StepMap(const [2, 4, 0]);
      expect(map.mapResult(6, assoc: 1).recoverValue, isNull);
      expect(map.mapResult(2, assoc: -1).recoverValue, isNull);
    });
  });

  group('StepMap.invert', () {
    test('maps post-step positions back to pre-step positions', () {
      final map = StepMap(const [2, 4, 0]);
      final inverted = map.invert();
      expect(inverted.inverted, isTrue);
      expect(inverted.ranges, map.ranges);
      expect(inverted.map(2, assoc: -1), 2);
      expect(inverted.map(2, assoc: 1), 6);
      expect(inverted.map(3), 7);
    });

    test('double inversion behaves like the original', () {
      final map = StepMap(const [2, 4, 4]);
      final twice = map.invert().invert();
      for (var pos = 0; pos <= 10; pos++) {
        for (final assoc in const [-1, 1]) {
          expect(twice.map(pos, assoc: assoc), map.map(pos, assoc: assoc));
        }
      }
    });

    test('round-trips every non-deleted position', () {
      final map = StepMap(const [2, 4, 4]);
      final inverted = map.invert();
      for (var pos = 0; pos <= 10; pos++) {
        for (final assoc in const [-1, 1]) {
          final r = map.mapResult(pos, assoc: assoc);
          if (r.deleted) continue;
          expect(inverted.map(r.pos, assoc: assoc), pos,
              reason: 'pos $pos, assoc $assoc');
        }
      }
    });
  });

  group('StepMap.forEach', () {
    test('reports old and new coordinates of each changed range', () {
      final seen = <List<int>>[];
      StepMap(const [2, 4, 0, 8, 0, 3]).forEach(
          (oldStart, oldEnd, newStart, newEnd) =>
              seen.add([oldStart, oldEnd, newStart, newEnd]));
      expect(seen, [
        [2, 6, 2, 2],
        [8, 8, 4, 7],
      ]);
    });

    test('swaps coordinate roles on an inverted map', () {
      final seen = <List<int>>[];
      StepMap(const [2, 4, 0]).invert().forEach(
          (oldStart, oldEnd, newStart, newEnd) =>
              seen.add([oldStart, oldEnd, newStart, newEnd]));
      expect(seen, [
        [2, 2, 2, 6],
      ]);
    });
  });

  group('StepMap.empty and StepMap.offset', () {
    test('the empty map is the identity', () {
      expect(StepMap.empty.map(0), 0);
      expect(StepMap.empty.map(5, assoc: -1), 5);
      expect(StepMap.empty.mapResult(5).recoverValue, isNull);
    });

    test('offset shifts all positions', () {
      expect(StepMap.offset(3).map(1), 4);
      expect(StepMap.offset(3).map(0, assoc: -1), 0);
      expect(StepMap.offset(-2).map(3), 1);
      expect(identical(StepMap.offset(0), StepMap.empty), isTrue);
    });
  });

  group('Error paths', () {
    test('range list length must be a multiple of three', () {
      expect(
          () => StepMap(const [1, 2]), throwsA(isA<MalformedStepMapError>()));
      expect(() => StepMap(const [1, 2, 3, 4]),
          throwsA(isA<MalformedStepMapError>()));
    });

    test('negative range values are rejected', () {
      expect(() => StepMap(const [-1, 0, 2]),
          throwsA(isA<MalformedStepMapError>()));
      expect(() => StepMap(const [0, -2, 0]),
          throwsA(isA<MalformedStepMapError>()));
      expect(() => StepMap(const [0, 0, -2]),
          throwsA(isA<MalformedStepMapError>()));
    });

    test('unsorted or overlapping triples are rejected', () {
      expect(() => StepMap(const [4, 2, 0, 2, 2, 0]),
          throwsA(isA<MalformedStepMapError>()));
      expect(() => StepMap(const [2, 4, 0, 3, 2, 0]),
          throwsA(isA<MalformedStepMapError>()));
    });

    test('mapping a negative position throws', () {
      final map = StepMap(const [2, 4, 0]);
      expect(() => map.map(-1), throwsA(isA<NegativePositionError>()));
      expect(() => map.mapResult(-1), throwsA(isA<NegativePositionError>()));
      expect(
          () => StepMap.empty.map(-7), throwsA(isA<NegativePositionError>()));
    });

    test('recover with an invalid value throws', () {
      final map = StepMap(const [2, 4, 0]);
      expect(() => map.recover(-1), throwsA(isA<ArgumentError>()));
      // Range index 3 does not exist in a single-triple map.
      expect(() => map.recover(3), throwsA(isA<ArgumentError>()));
    });
  });
}
