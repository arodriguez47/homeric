import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/src/margin/margin_layout_solver.dart';

/// Line height used by every scenario: thresholds are then whole pixels
/// (two lines = 40 px, eight lines = 160 px).
const double _line = 20;

MarginNoteInput _note(
  String id,
  double anchorTop, {
  double fullHeight = _line,
  double compactHeight = _line,
  int rangeStart = 0,
}) =>
    MarginNoteInput(
      id: id,
      anchorTop: anchorTop,
      rangeStart: rangeStart,
      fullHeight: fullHeight,
      compactHeight: compactHeight,
    );

List<MarginNotePlacement> _solve(List<MarginBlockInput> blocks) =>
    solveMarginLayout(blocks, lineHeight: _line);

MarginNotePlacement _byId(List<MarginNotePlacement> out, String id) =>
    out.singleWhere((p) => p.id == id);

/// Asserts that no two placements share any vertical extent. Zero-height
/// placements occupy no space and therefore never overlap.
void _expectNoOverlap(List<MarginNotePlacement> out) {
  final sorted = [...out]..sort((a, b) => a.top.compareTo(b.top));
  for (var i = 1; i < sorted.length; i++) {
    final prev = sorted[i - 1];
    final next = sorted[i];
    expect(
      next.top,
      greaterThanOrEqualTo(prev.bottom),
      reason: '${next.id} (top ${next.top}) overlaps ${prev.id} '
          '(${prev.top}..${prev.bottom})',
    );
  }
}

void main() {
  group('solveMarginLayout', () {
    test('AE1: one note with free space sits at its anchor, full, no connector',
        () {
      final out = _solve([
        MarginBlockInput(blockId: 'b1', top: 100, notes: [
          _note('n1', 112, fullHeight: 40),
        ]),
      ]);

      expect(out, hasLength(1));
      final n1 = out.single;
      expect(n1.id, 'n1');
      expect(n1.blockId, 'b1');
      expect(n1.form, MarginNoteForm.full);
      expect(n1.top, 112);
      expect(n1.blockRelativeTop, 12);
      expect(n1.anchorTop, 112);
      expect(n1.height, 40);
      expect(n1.displaced, isFalse);
    });

    test(
        'AE2: a close second note shifts less than two lines, stays full and '
        'has a connector', () {
      final out = _solve([
        MarginBlockInput(blockId: 'b1', top: 0, notes: [
          _note('n1', 0, fullHeight: 30),
          _note('n2', 10, fullHeight: 20, rangeStart: 5),
        ]),
      ]);

      final n1 = _byId(out, 'n1');
      final n2 = _byId(out, 'n2');
      expect(n1.form, MarginNoteForm.full);
      expect(n1.displaced, isFalse);
      expect(n2.form, MarginNoteForm.full);
      expect(n2.top, 38); // 0 + 30 + 8 gap
      expect(n2.top - n2.anchorTop, lessThan(2 * _line));
      expect(n2.displaced, isTrue);
      expect(n2.anchorTop, 10);
      _expectNoOverlap(out);
    });

    test(
        'AE3: a group ending below the next annotated block turns entirely '
        'compact and the next group is unaffected by its overflow', () {
      final second = MarginBlockInput(blockId: 'b2', top: 100, notes: [
        _note('m1', 100, fullHeight: 40),
        _note('m2', 120, fullHeight: 20, rangeStart: 9),
      ]);
      final out = _solve([
        MarginBlockInput(blockId: 'b1', top: 0, notes: [
          _note('n1', 0, fullHeight: 40),
          // Full form would sit at 48 and end at 108 > 100.
          _note('n2', 30, fullHeight: 60, rangeStart: 4),
        ]),
        second,
      ]);

      final n1 = _byId(out, 'n1');
      final n2 = _byId(out, 'n2');
      expect(n1.form, MarginNoteForm.compact);
      expect(n2.form, MarginNoteForm.compact);
      expect(n1.top, 0);
      expect(n1.height, _line);
      expect(n2.top, 30); // compact n1 ends at 20; 20 + 8 < 30
      expect(n2.displaced, isFalse);

      final alone = _solve([second]);
      expect(out.where((p) => p.blockId == 'b2').toList(), alone);
      _expectNoOverlap(out);
    });

    test(
        'AE4: a three-line note beside a one-line block with nothing below '
        'stays full', () {
      final out = _solve([
        MarginBlockInput(blockId: 'b1', top: 0, notes: [
          _note('n1', 0, fullHeight: 3 * _line),
        ]),
        // A following un-annotated block is not a collision source.
        const MarginBlockInput(blockId: 'b2', top: _line, notes: []),
      ]);

      final n1 = out.single;
      expect(n1.form, MarginNoteForm.full);
      expect(n1.height, 3 * _line);
      expect(n1.displaced, isFalse);
    });

    test(
        'AE4: a note taller than eight lines turns compact with unlimited space',
        () {
      final out = _solve([
        MarginBlockInput(blockId: 'b1', top: 0, notes: [
          _note('n1', 0, fullHeight: 8 * _line + 1),
        ]),
      ]);
      expect(out.single.form, MarginNoteForm.compact);
      expect(out.single.height, _line);
      expect(out.single.top, 0);
      expect(out.single.displaced, isFalse);

      final exactly = _solve([
        MarginBlockInput(blockId: 'b1', top: 0, notes: [
          _note('n1', 0, fullHeight: 8 * _line),
        ]),
      ]);
      expect(exactly.single.form, MarginNoteForm.full);
    });

    test('a shift of exactly two lines stays full; one pixel more compacts',
        () {
      // n1 occupies 0..52, so n2 can start no higher than 60.
      List<MarginNotePlacement> solveWithAnchor(double anchor) => _solve([
            MarginBlockInput(blockId: 'b1', top: 0, notes: [
              _note('n1', 0, fullHeight: 52),
              _note('n2', anchor, rangeStart: 3),
            ]),
          ]);

      final atCap = solveWithAnchor(60 - 2 * _line);
      expect(_byId(atCap, 'n2').top - _byId(atCap, 'n2').anchorTop, 2 * _line);
      expect(atCap.map((p) => p.form), everyElement(MarginNoteForm.full));
      expect(_byId(atCap, 'n2').displaced, isTrue);

      final overCap = solveWithAnchor(60 - 2 * _line - 1);
      expect(overCap.map((p) => p.form), everyElement(MarginNoteForm.compact));
    });

    test(
        'compact previews that do not fit keep stacking, later groups cascade '
        'and nothing overlaps', () {
      final out = _solve([
        MarginBlockInput(blockId: 'b1', top: 0, notes: [
          for (var i = 0; i < 5; i++) _note('n$i', 0, rangeStart: i),
        ]),
        MarginBlockInput(blockId: 'b2', top: 40, notes: [
          _note('m0', 40),
        ]),
        MarginBlockInput(blockId: 'b3', top: 400, notes: [
          _note('k0', 400),
        ]),
      ]);

      // Five compact previews at 0, 28, 56, 84, 112.
      for (var i = 0; i < 5; i++) {
        final n = _byId(out, 'n$i');
        expect(n.form, MarginNoteForm.compact);
        expect(n.top, i * (_line + 8));
        expect(n.displaced, i > 0);
      }
      // b2 cascades below the stack: 112 + 20 + 8 = 140, shifted 100 px, so
      // its group is compact and connected.
      final m0 = _byId(out, 'm0');
      expect(m0.top, 140);
      expect(m0.blockRelativeTop, 100);
      expect(m0.form, MarginNoteForm.compact);
      expect(m0.displaced, isTrue);
      // b3 has room again and is untouched.
      final k0 = _byId(out, 'k0');
      expect(k0.top, 400);
      expect(k0.form, MarginNoteForm.full);
      expect(k0.displaced, isFalse);
      _expectNoOverlap(out);
    });

    test('empty input returns empty output', () {
      expect(_solve(const []), isEmpty);
      expect(
        _solve([
          const MarginBlockInput(blockId: 'b1', top: 0, notes: []),
        ]),
        isEmpty,
      );
    });

    test('a note with a non-finite anchor is dropped', () {
      final out = _solve([
        MarginBlockInput(blockId: 'b1', top: 0, notes: [
          _note('nan', double.nan),
          _note('inf', double.infinity),
          _note('ninf', double.negativeInfinity),
          _note('ok', 10),
        ]),
      ]);
      expect(out.map((p) => p.id), ['ok']);
      expect(out.single.top, 10);
      expect(out.single.displaced, isFalse);
    });

    test('output is identical for any list order within a block', () {
      final notes = [
        _note('a', 0, fullHeight: 30, rangeStart: 0),
        _note('b', 0, fullHeight: 10, rangeStart: 4),
        _note('c', 0, fullHeight: 10, rangeStart: 4),
        _note('d', 15, fullHeight: 25, rangeStart: 9),
        _note('e', 90, fullHeight: 20, rangeStart: 20),
      ];
      final expected = _solve([
        MarginBlockInput(blockId: 'b1', top: 0, notes: notes),
      ]);
      final rng = Random(7);
      for (var i = 0; i < 20; i++) {
        final shuffled = [...notes]..shuffle(rng);
        expect(
          _solve([MarginBlockInput(blockId: 'b1', top: 0, notes: shuffled)]),
          expected,
        );
      }
      // Ties on anchor break on range start, then id.
      expect(expected.map((p) => p.id), ['a', 'b', 'c', 'd', 'e']);
    });

    test('identical anchors stack in tie-break order with connectors', () {
      final out = _solve([
        MarginBlockInput(blockId: 'b1', top: 0, notes: [
          _note('y', 50, rangeStart: 2),
          _note('x', 50, rangeStart: 2),
        ]),
      ]);
      expect(out.map((p) => p.id), ['x', 'y']);
      expect(_byId(out, 'x').top, 50);
      expect(_byId(out, 'x').displaced, isFalse);
      expect(_byId(out, 'y').top, 78);
      expect(_byId(out, 'y').displaced, isTrue);
      expect(out.map((p) => p.form), everyElement(MarginNoteForm.full));
    });

    test('a single block with many spaced notes stays full and undisplaced',
        () {
      final out = _solve([
        MarginBlockInput(blockId: 'b1', top: 0, notes: [
          for (var i = 0; i < 12; i++)
            _note('n$i', i * 40.0, rangeStart: i * 10),
        ]),
      ]);
      expect(out, hasLength(12));
      expect(out.map((p) => p.form), everyElement(MarginNoteForm.full));
      expect(out.map((p) => p.displaced), everyElement(isFalse));
      _expectNoOverlap(out);
    });

    test('a zero-height note occupies no space but still takes a gap', () {
      final out = _solve([
        MarginBlockInput(blockId: 'b1', top: 0, notes: [
          _note('z', 0, fullHeight: 0, compactHeight: 0),
          _note('n', 0, rangeStart: 1),
        ]),
      ]);
      expect(_byId(out, 'z').height, 0);
      expect(_byId(out, 'z').top, 0);
      expect(_byId(out, 'n').top, 8);
      expect(out.map((p) => p.form), everyElement(MarginNoteForm.full));
      _expectNoOverlap(out);
    });

    test('an un-annotated block between two annotated ones changes nothing',
        () {
      final a = MarginBlockInput(blockId: 'b1', top: 0, notes: [
        _note('n1', 0, fullHeight: 60),
      ]);
      final c = MarginBlockInput(blockId: 'b3', top: 50, notes: [
        _note('m1', 50),
      ]);
      final without = _solve([a, c]);
      final withEmpty = _solve([
        a,
        const MarginBlockInput(blockId: 'b2', top: 30, notes: []),
        c,
      ]);
      expect(withEmpty, without);
      // b1 would end at 60 > 50, the first anchor of b3, so it is compact.
      expect(_byId(without, 'n1').form, MarginNoteForm.compact);
    });

    test('a block whose notes are all dropped is not a collision source', () {
      final a = MarginBlockInput(blockId: 'b1', top: 0, notes: [
        _note('n1', 0, fullHeight: 60),
      ]);
      final out = _solve([
        a,
        MarginBlockInput(blockId: 'b2', top: 30, notes: [
          _note('gone', double.nan),
        ]),
      ]);
      expect(out, _solve([a]));
      expect(out.single.form, MarginNoteForm.full);
    });

    test('thresholds are parameters', () {
      final blocks = [
        MarginBlockInput(blockId: 'b1', top: 0, notes: [
          _note('n1', 0, fullHeight: 4 * _line),
        ]),
      ];
      expect(
        solveMarginLayout(blocks, lineHeight: _line, maxFullLines: 3)
            .single
            .form,
        MarginNoteForm.compact,
      );
      expect(
        solveMarginLayout(blocks, lineHeight: _line).single.form,
        MarginNoteForm.full,
      );

      final close = [
        MarginBlockInput(blockId: 'b1', top: 0, notes: [
          _note('n1', 0),
          _note('n2', 0, rangeStart: 1),
        ]),
      ];
      expect(
        _byId(solveMarginLayout(close, lineHeight: _line, gap: 2), 'n2').top,
        22,
      );
      expect(
        solveMarginLayout(close, lineHeight: _line, maxShiftLines: 1)
            .map((p) => p.form),
        everyElement(MarginNoteForm.compact),
      );
    });

    test('invalid parameters are rejected', () {
      expect(
        () => solveMarginLayout(const [], lineHeight: 0),
        throwsArgumentError,
      );
      expect(
        () => solveMarginLayout(const [], lineHeight: double.nan),
        throwsArgumentError,
      );
      expect(
        () => solveMarginLayout(const [], lineHeight: _line, gap: -1),
        throwsArgumentError,
      );
      expect(
        () => solveMarginLayout(const [], lineHeight: _line, floor: double.nan),
        throwsArgumentError,
      );
      expect(
        () => solveMarginLayout(const [],
            lineHeight: _line, trailingAnchor: double.negativeInfinity),
        throwsArgumentError,
      );
    });

    test('a floor pushes the first note down as a kept note above would', () {
      final blocks = [
        MarginBlockInput(blockId: 'b1', top: 0, notes: [_note('n1', 10)]),
      ];
      final out = solveMarginLayout(blocks, lineHeight: _line, floor: 30);
      expect(out.single.top, 30);
      expect(out.single.displaced, isTrue);
      expect(out.single.form, MarginNoteForm.full);
      // Beyond two lines of shift the group compacts, as with any cascade.
      final far = solveMarginLayout(blocks, lineHeight: _line, floor: 51);
      expect(far.single.form, MarginNoteForm.compact);
      expect(far.single.top, 51);
      // A floor above the anchor changes nothing.
      expect(solveMarginLayout(blocks, lineHeight: _line, floor: -100),
          _solve(blocks));
    });

    test('a trailing anchor bounds the last group like a next block would', () {
      final blocks = [
        MarginBlockInput(blockId: 'b1', top: 0, notes: [
          _note('n1', 0, fullHeight: 60),
        ]),
      ];
      expect(
        solveMarginLayout(blocks, lineHeight: _line, trailingAnchor: 60)
            .single
            .form,
        MarginNoteForm.full,
      );
      expect(
        solveMarginLayout(blocks, lineHeight: _line, trailingAnchor: 59)
            .single
            .form,
        MarginNoteForm.compact,
      );
      // Equivalent to an annotated block whose first anchor is there.
      final withNext = _solve([
        ...blocks,
        MarginBlockInput(blockId: 'b2', top: 59, notes: [_note('n2', 59)]),
      ]);
      expect(_byId(withNext, 'n1').form, MarginNoteForm.compact);
    });

    test(
        'property: random inputs never overlap, never rise above their anchor '
        'and solve deterministically', () {
      final rng = Random(20261005);
      for (var run = 0; run < 300; run++) {
        final blocks = <MarginBlockInput>[];
        var y = rng.nextDouble() * 50;
        final blockCount = rng.nextInt(6);
        for (var b = 0; b < blockCount; b++) {
          final blockHeight = 10 + rng.nextDouble() * 200;
          final noteCount = rng.nextInt(5);
          blocks.add(MarginBlockInput(
            blockId: 'b$b',
            top: y,
            notes: [
              for (var n = 0; n < noteCount; n++)
                _note(
                  'b$b-n$n',
                  rng.nextInt(20) == 0
                      ? double.nan
                      : y + rng.nextDouble() * blockHeight,
                  fullHeight: rng.nextDouble() * 12 * _line,
                  compactHeight: _line,
                  rangeStart: rng.nextInt(40),
                ),
            ],
          ));
          y += blockHeight;
        }

        final out = solveMarginLayout(blocks, lineHeight: _line);
        _expectNoOverlap(out);
        for (final p in out) {
          expect(p.top, greaterThanOrEqualTo(p.anchorTop));
          expect(p.displaced, p.top > p.anchorTop);
          final block = blocks.singleWhere((b) => b.blockId == p.blockId);
          expect(p.blockRelativeTop, closeTo(p.top - block.top, 1e-9));
        }
        expect(solveMarginLayout(blocks, lineHeight: _line), out);
      }
    });
  });
}
