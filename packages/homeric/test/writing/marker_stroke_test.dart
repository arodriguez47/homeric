import 'dart:ui' as ui;

import 'package:flutter/painting.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/writing.dart';

void main() {
  const line = Rect.fromLTWH(40, 100, 220, 30);

  group('markerStrokeShape', () {
    test('the same size and seed draw the same stroke', () {
      final a = markerStrokeShape(line, seed: 7).body.getBounds();
      final b = markerStrokeShape(line, seed: 7).body.getBounds();
      expect(a, b);
    });

    test('scrolling moves the stroke without reshaping it', () {
      final here = markerStrokeShape(line, seed: 7).body.getBounds();
      final there =
          markerStrokeShape(line.shift(const Offset(13, -480)), seed: 7)
              .body
              .getBounds();
      expect(there.shift(const Offset(-13, 480)), _rectCloseTo(here));
    });

    test('a stroke that grows keeps where it starts', () {
      final short = markerStrokeShape(line, seed: 7).body.getBounds();
      final long = markerStrokeShape(
        Rect.fromLTWH(line.left, line.top, line.width + 0.4, line.height),
        seed: 7,
      ).body.getBounds();
      expect(long.left, closeTo(short.left, 1e-3));
      expect(long.right - short.right, closeTo(0.4, 0.5));
    });

    test('a stroke that grows keeps the shape it had drawn', () {
      final short = markerStrokeShape(line, seed: 9).body;
      final long = markerStrokeShape(
        Rect.fromLTWH(line.left, line.top, line.width + 80, line.height),
        seed: 9,
      ).body;
      // Up to the last edge point the short stroke had, both agree.
      for (var x = line.left; x < line.left + line.width - 30; x += 3) {
        for (var y = line.top; y < line.bottom; y += 1) {
          final p = Offset(x, y);
          expect(long.contains(p), short.contains(p), reason: '$p');
        }
      }
    });

    test('a tall line keeps its ends close to the words', () {
      final bounds = markerStrokeShape(
        const Rect.fromLTWH(100, 0, 100, 300),
        seed: 4,
      ).body.getBounds();
      expect(bounds.left, greaterThan(100 - 10));
      expect(bounds.right, lessThan(200 + 12));
    });

    test('a different seed draws a different stroke', () {
      final a = markerStrokeShape(line, seed: 1).body.getBounds();
      final b = markerStrokeShape(line, seed: 2).body.getBounds();
      expect(a == b, isFalse);
    });

    test('runs a little past the words and keeps to its line', () {
      for (var seed = 0; seed < 50; seed++) {
        final bounds = markerStrokeShape(line, seed: seed).body.getBounds();
        expect(bounds.left, lessThan(line.left));
        expect(bounds.left, greaterThan(line.left - 10));
        expect(bounds.right, greaterThan(line.right));
        expect(bounds.right, lessThan(line.right + 12));
        expect(bounds.top, greaterThan(line.top - 1.5));
        expect(bounds.bottom, lessThan(line.bottom + 1.5));
      }
    });

    test('a long line tilts no more than a sixth of the band', () {
      const long = Rect.fromLTWH(0, 0, 900, 30);
      for (var seed = 0; seed < 50; seed++) {
        final bounds = markerStrokeShape(long, seed: seed).body.getBounds();
        expect(bounds.height, lessThan(30 * 0.7 + 30 * 0.7 / 6 + 4));
      }
    });

    test('doubles back over part of a stroke, not a one-letter one', () {
      final long = markerStrokeShape(line, seed: 3);
      expect(long.overlap, isNotNull);
      final overlap = long.overlap!.getBounds();
      expect(overlap.width, lessThan(long.body.getBounds().width * 0.4));
      final short = markerStrokeShape(
        const Rect.fromLTWH(0, 0, 9, 30),
        seed: 3,
      );
      expect(short.overlap, isNull);
    });
  });

  test('the painter draws an empty rect as nothing', () {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    markerStrokePainter(
      canvas,
      Rect.zero,
      const MarkerStrokeSpec(Color(0x55E8C547)),
    );
    recorder.endRecording().dispose();
  });

  test('highlights paint as marker strokes in the highlight ink', () {
    const ink = Color(0x66F2A65A);
    final block = Block(
        id: 'b', type: 'paragraph', runs: [InlineRun('a ==hi there== b')]);
    final layers = const HomericSyntaxPaint(highlightWash: ink)
        .layersFor(HomericSyntax.all.decorationsFor(block));
    final marker = layers.singleWhere((l) => l.spec is MarkerStrokeSpec);
    expect(marker.band, PaintBand.underlay);
    expect(identical(marker.painter, markerStrokePainter), isTrue);
    expect((marker.spec! as MarkerStrokeSpec).color, ink);
    expect(marker.fit, PaintLayerFit.inkLine);
  });

  test('each highlight in a block keeps its seed while its words change', () {
    int seedOf(String text, int index) {
      final block = Block(id: 'b', type: 'paragraph', runs: [InlineRun(text)]);
      final layers = const HomericSyntaxPaint()
          .layersFor(HomericSyntax.all.decorationsFor(block))
          .where((l) => l.spec is MarkerStrokeSpec)
          .toList();
      return (layers[index].spec! as MarkerStrokeSpec).seed;
    }

    expect(
        seedOf('==one== and ==two==', 0), seedOf('x ==one more== ==two==', 0));
    expect(
        seedOf('==one== and ==two==', 1), seedOf('==one== ==two words==', 1));
    expect(
      seedOf('==one== and ==two==', 0) == seedOf('==one== and ==two==', 1),
      isFalse,
    );
  });

  test('a fold inside a highlight keeps the next highlight\'s seed', () {
    List<int> seeds(List<Decoration> ds) => [
          for (final l in const HomericSyntaxPaint().layersFor(ds))
            if (l.spec case final MarkerStrokeSpec m) m.seed,
        ];
    const mark = HomericMarkSpec(HomericMarkKind.highlight);
    final plain = seeds([
      Decoration.inline('b', 2, 10, spec: mark),
      Decoration.inline('b', 20, 25, spec: mark),
    ]);
    final folded = seeds([
      Decoration.inline('b', 2, 5, spec: mark),
      Decoration.replace('b', 5, 8, replacementLength: 0),
      Decoration.inline('b', 8, 10, spec: mark),
      Decoration.inline('b', 20, 25, spec: mark),
    ]);
    expect(folded.first, folded[1]);
    expect(folded.last, plain.last);
  });

  test('bidi pieces with other words between them stay apart', () {
    final boxes = joinLineBoxes([
      const TextBox.fromLTRBD(10, 0, 40, 20, TextDirection.ltr),
      const TextBox.fromLTRBD(80, 0, 110, 20, TextDirection.rtl),
    ]);
    expect(boxes, hasLength(2));
  });

  test('fragments on one line join into one box per line', () {
    final boxes = joinLineBoxes([
      const TextBox.fromLTRBD(10, 0, 40, 20, TextDirection.ltr),
      const TextBox.fromLTRBD(40, 1, 70, 19, TextDirection.ltr),
      const TextBox.fromLTRBD(0, 24, 30, 44, TextDirection.ltr),
    ]);
    expect(boxes, hasLength(2));
    expect(boxes.first.toRect(), const Rect.fromLTRB(10, 0, 70, 20));
    expect(boxes.last.toRect(), const Rect.fromLTRB(0, 24, 30, 44));
  });
}

Matcher _rectCloseTo(Rect expected) => predicate<Rect>(
      (r) =>
          (r.left - expected.left).abs() < 1e-3 &&
          (r.top - expected.top).abs() < 1e-3 &&
          (r.right - expected.right).abs() < 1e-3 &&
          (r.bottom - expected.bottom).abs() < 1e-3,
      'close to $expected',
    );
