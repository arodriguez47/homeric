import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/src/margin/margin_layout_memory.dart';
import 'package:homeric/src/margin/margin_layout_solver.dart';

const double _line = 20;

/// A block at [top] whose notes are given relative to it, so scrolling is
/// a change of [top] alone.
MarginBlockInput _block(
  String id,
  double top,
  List<({String id, double anchor, double height})> notes,
) =>
    MarginBlockInput(blockId: id, top: top, notes: [
      for (final note in notes)
        MarginNoteInput(
          id: note.id,
          anchorTop: top + note.anchor,
          rangeStart: 0,
          fullHeight: note.height,
          compactHeight: _line,
        ),
    ]);

({String id, double anchor, double height}) _n(
  String id, {
  double anchor = 0,
  double height = _line,
}) =>
    (id: id, anchor: anchor, height: height);

MarginNotePlacement _byId(List<MarginNotePlacement> out, String id) =>
    out.singleWhere((p) => p.id == id);

void _expectNoOverlap(List<MarginNotePlacement> out) {
  final sorted = [...out]..sort((a, b) => a.top.compareTo(b.top));
  for (var i = 1; i < sorted.length; i++) {
    expect(sorted[i].top, greaterThanOrEqualTo(sorted[i - 1].bottom),
        reason: '${sorted[i].id} overlaps ${sorted[i - 1].id}');
  }
}

/// Five crowded notes on one line: a compact stack 5 * 28 px tall.
List<({String id, double anchor, double height})> _crowd(String prefix) => [
      for (var index = 0; index < 5; index++) _n('$prefix$index', height: 100),
    ];

void main() {
  group('MarginLayoutMemory', () {
    test('the first solve equals a fresh solve', () {
      final blocks = [
        _block('a', 0, _crowd('a')),
        _block('b', 30, [_n('b0')]),
      ];
      expect(MarginLayoutMemory().solve(blocks, lineHeight: _line),
          solveMarginLayout(blocks, lineHeight: _line));
    });

    test('scrolling translates every placement unchanged', () {
      final memory = MarginLayoutMemory();
      final before = memory.solve([
        _block('a', 0, _crowd('a')),
        _block('b', 30, [_n('b0')]),
      ], lineHeight: _line);
      final after = memory.solve([
        _block('a', -37.25, _crowd('a')),
        _block('b', -7.25, [_n('b0')]),
      ], lineHeight: _line);
      for (final placement in before) {
        final moved = _byId(after, placement.id);
        expect(moved.form, placement.form);
        expect(moved.blockRelativeTop, placement.blockRelativeTop);
        expect(moved.top, closeTo(placement.top - 37.25, 1e-9));
      }
    });

    test('a block mounting below never compacts a kept group', () {
      final memory = MarginLayoutMemory();
      final a = _block('a', 0, [_n('a0', height: 100)]);
      final first = memory.solve([a], lineHeight: _line);
      expect(first.single.form, MarginNoteForm.full);

      final b = _block('b', 40, [_n('b0')]);
      // From scratch, A would compact because its note ends below B.
      expect(
        _byId(solveMarginLayout([a, b], lineHeight: _line), 'a0').form,
        MarginNoteForm.compact,
      );
      final out = memory.solve([a, b], lineHeight: _line);
      expect(_byId(out, 'a0'), first.single);
      expect(_byId(out, 'b0').top, 108, reason: 'below the kept note');
      expect(_byId(out, 'b0').displaced, isTrue);
      _expectNoOverlap(out);
    });

    test('a block unmounting above leaves the notes it pushed in place', () {
      final memory = MarginLayoutMemory();
      final a = _block('a', 0, _crowd('a'));
      final b = _block('b', 30, [_n('b0')]);
      final before = memory.solve([a, b], lineHeight: _line);
      final pushed = _byId(before, 'b0');
      expect(pushed.top, 140, reason: 'below five compact previews');

      final out = memory.solve([b], lineHeight: _line);
      expect(out.single, pushed);
      // From scratch it would sit at its anchor.
      expect(solveMarginLayout([b], lineHeight: _line).single.top, 30);
    });

    test('a block mounting above is limited by the kept notes', () {
      final memory = MarginLayoutMemory();
      final b = _block('b', 100, [_n('b0')]);
      final kept = memory.solve([b], lineHeight: _line).single;

      final a = _block('a', 0, [_n('a0', height: 95)]);
      final out = memory.solve([a, b], lineHeight: _line);
      expect(_byId(out, 'b0'), kept);
      expect(_byId(out, 'a0').form, MarginNoteForm.compact,
          reason: 'full, it would end within the gap above the kept note');
      _expectNoOverlap(out);

      final fits = memory.solve([
        _block('a', 0, [_n('a0', height: 92)]),
        b,
      ], lineHeight: _line);
      expect(_byId(fits, 'a0').form, MarginNoteForm.full);
      expect(_byId(fits, 'b0'), kept);
    });

    test(
        'a block mounting above whose previews would overlap the kept notes '
        'falls back to a fresh solve', () {
      final memory = MarginLayoutMemory();
      final b = _block('b', 30, [_n('b0')]);
      memory.solve([b], lineHeight: _line);
      final a = _block('a', 0, _crowd('a'));

      final out = memory.solve([a, b], lineHeight: _line);
      expect(out, solveMarginLayout([a, b], lineHeight: _line));
      _expectNoOverlap(out);
    });

    test('an edit reopens the block before it and re-solves from there', () {
      final memory = MarginLayoutMemory();
      final x = _block('x', -500, [_n('x0')]);
      final a = _block('a', 0, [_n('a0', height: 100)]);
      memory.solve([x, a], lineHeight: _line);
      // B mounts below: A stays full by the mount rule.
      final b = _block('b', 40, [_n('b0')]);
      expect(
        _byId(memory.solve([x, a, b], lineHeight: _line), 'a0').form,
        MarginNoteForm.full,
      );

      // Then the writer edits B: A is reopened and compacts, X is kept.
      final edited = _block('b', 40, [_n('b0', anchor: 2)]);
      final out = memory.solve([x, a, edited], lineHeight: _line);
      expect(_byId(out, 'a0').form, MarginNoteForm.compact);
      expect(_byId(out, 'x0').top, -500);
      expect(out, solveMarginLayout([x, a, edited], lineHeight: _line));
    });

    test('a block moving relative to the others counts as an edit', () {
      final memory = MarginLayoutMemory();
      final a = _block('a', 0, [_n('a0', height: 100)]);
      memory.solve([a], lineHeight: _line);
      memory.solve([
        a,
        _block('b', 200, [_n('b0')])
      ], lineHeight: _line);

      // Text inserted between A and B pulls B up under A's note.
      final out = memory.solve([
        a,
        _block('b', 60, [_n('b0')])
      ], lineHeight: _line);
      expect(_byId(out, 'a0').form, MarginNoteForm.compact);
    });

    test('a block losing its notes while mounted releases its cascade', () {
      final memory = MarginLayoutMemory();
      final a = _block('a', 0, _crowd('a'));
      final b = _block('b', 30, [_n('b0')]);
      expect(_byId(memory.solve([a, b], lineHeight: _line), 'b0').top, 140);

      final out = memory.solve(
        [b],
        lineHeight: _line,
        isUnmounted: (blockId) => false,
      );
      expect(out.single.top, 30);
    });

    test('a block gaining notes between kept blocks reopens its predecessor',
        () {
      final memory = MarginLayoutMemory();
      final a = _block('a', 0, [_n('a0', height: 100)]);
      final c = _block('c', 400, [_n('c0')]);
      memory.solve([a, c], lineHeight: _line);

      final out = memory.solve(
        [
          a,
          _block('b', 40, [_n('b0')]),
          c
        ],
        lineHeight: _line,
      );
      expect(
          out,
          solveMarginLayout([
            a,
            _block('b', 40, [_n('b0')]),
            c
          ], lineHeight: _line));
    });

    test('changing a parameter or resetting solves fresh', () {
      final memory = MarginLayoutMemory();
      final a = _block('a', 0, [_n('a0', height: 100)]);
      final b = _block('b', 40, [_n('b0')]);
      memory.solve([a], lineHeight: _line);
      expect(_byId(memory.solve([a, b], lineHeight: _line), 'a0').form,
          MarginNoteForm.full);
      expect(memory.solve([a, b], lineHeight: _line, gap: 4),
          solveMarginLayout([a, b], lineHeight: _line, gap: 4));
      memory.solve([a], lineHeight: _line);
      memory.reset();
      expect(memory.solve([a, b], lineHeight: _line),
          solveMarginLayout([a, b], lineHeight: _line));
    });

    test('invalid parameters are rejected even with nothing to place', () {
      expect(() => MarginLayoutMemory().solve(const [], lineHeight: 0),
          throwsArgumentError);
    });

    test(
        'property: windows sliding over a document never overlap, never rise '
        'above an anchor, and keep notes that stay in the window', () {
      final rng = Random(20261005);
      for (var run = 0; run < 100; run++) {
        final document = <MarginBlockInput>[];
        var y = 0.0;
        for (var b = 0; b < 30; b++) {
          final height = 20 + rng.nextDouble() * 80;
          final count = rng.nextInt(10) < 6 ? 0 : 1 + rng.nextInt(4);
          document.add(_block('b$b', y, [
            for (var n = 0; n < count; n++)
              _n('b$b-n$n',
                  anchor: rng.nextDouble() * height,
                  height: rng.nextDouble() * 10 * _line),
          ]));
          y += height;
        }
        final memory = MarginLayoutMemory();
        var start = 0;
        var end = 5;
        Map<String, MarginNotePlacement>? previous;
        for (var step = 0; step < 40; step++) {
          final window = document.sublist(start, end);
          final out = memory.solve(window, lineHeight: _line);
          _expectNoOverlap(out);
          for (final placement in out) {
            expect(placement.top, greaterThanOrEqualTo(placement.anchorTop));
          }
          final current = {for (final p in out) p.id: p};
          // A pure slide (one block in or out at an end) moves nothing that
          // stays, unless it fell back to a fresh solve, which is rare and
          // still overlap-free.
          if (previous != null &&
              !_equals(out, solveMarginLayout(window, lineHeight: _line))) {
            for (final id in current.keys) {
              final before = previous[id];
              if (before == null) continue;
              final now = current[id]!;
              final reason = 'run $run step $step $id';
              expect(now.form, before.form, reason: reason);
              expect(now.blockRelativeTop, before.blockRelativeTop,
                  reason: reason);
              expect(now.top, closeTo(before.top, 1e-6), reason: reason);
            }
          }
          previous = current;
          final move = rng.nextInt(4);
          if (move == 0 && end < document.length) end++;
          if (move == 1 && end - start > 2) end--;
          if (move == 2 && start > 0) start--;
          if (move == 3 && end - start > 2) start++;
        }
      }
    });
  });
}

bool _equals(List<MarginNotePlacement> a, List<MarginNotePlacement> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].id != b[i].id ||
        a[i].form != b[i].form ||
        (a[i].top - b[i].top).abs() > 1e-6) {
      return false;
    }
  }
  return true;
}
