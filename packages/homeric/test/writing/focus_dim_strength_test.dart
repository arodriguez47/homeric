import 'dart:ui' show Color;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/writing.dart';

double _contrast(Color foreground, Color background, double opacity) {
  final composited = Color.alphaBlend(
    background.withValues(alpha: opacity),
    foreground,
  );
  final a = composited.computeLuminance();
  final b = background.computeLuminance();
  final lighter = a > b ? a : b;
  final darker = a > b ? b : a;
  return (lighter + 0.05) / (darker + 0.05);
}

void main() {
  const ink = Color(0xFF2B2420);
  const paper = Color(0xFFFBF7F0);
  const nightInk = Color(0xFFE9E1D6);
  const night = Color(0xFF1C1816);

  group('homericFocusWashOpacity', () {
    test('the default strength dims as before', () {
      for (final (fg, bg) in [(ink, paper), (nightInk, night)]) {
        expect(
          homericFocusWashOpacity(foreground: fg, background: bg),
          homericFocusWashOpacity(
            foreground: fg,
            background: bg,
            desiredOpacity: 0.38,
            minimumContrast: 4.5,
          ),
        );
      }
    });

    test('zero strength never dims', () {
      expect(
        homericFocusWashOpacity(
            foreground: ink, background: paper, strength: 0),
        0,
      );
    });

    test('a stronger setting never dims less', () {
      for (final (fg, bg) in [(ink, paper), (nightInk, night)]) {
        var last = -1.0;
        for (var s = 0.0; s <= 1.0001; s += 0.1) {
          final o = homericFocusWashOpacity(
            foreground: fg,
            background: bg,
            strength: s,
          );
          expect(o, greaterThanOrEqualTo(last), reason: 'strength $s');
          last = o;
        }
      }
    });

    test('up to the default, dimmed text keeps AA contrast', () {
      for (final s in [0.1, 0.3, 0.5]) {
        final o = homericFocusWashOpacity(
          foreground: ink,
          background: paper,
          strength: s,
        );
        expect(_contrast(ink, paper, o), greaterThanOrEqualTo(4.49));
      }
    });

    test('the strongest still leaves the words there to read', () {
      for (final (fg, bg) in [(ink, paper), (nightInk, night)]) {
        final o = homericFocusWashOpacity(
          foreground: fg,
          background: bg,
          strength: 1,
        );
        expect(o, lessThanOrEqualTo(0.85));
        expect(_contrast(fg, bg, o), greaterThanOrEqualTo(1.59));
        expect(
          o,
          greaterThan(
            homericFocusWashOpacity(foreground: fg, background: bg),
          ),
        );
      }
    });
  });

  testWidgets('changing strength repaints at once', (tester) async {
    final controller = HomericFocusDimController(
      vsync: const TestVSync(),
      initialGranularity: HomericFocusGranularity.paragraph,
    );
    addTearDown(controller.dispose);
    expect(controller.strength, homericFocusDimDefaultStrength);
    var notified = 0;
    controller.addListener(() => notified++);
    controller.strength = 0.9;
    expect(controller.strength, 0.9);
    expect(notified, 1);
    controller.strength = 0.9;
    expect(notified, 1);
    controller.strength = 4;
    expect(controller.strength, 1);
    controller.strength = double.nan;
    expect(controller.strength, homericFocusDimDefaultStrength);
  });

  testWidgets('the wash a block gets follows strength', (tester) async {
    final doc = Document([
      Block(id: 'a', type: 'paragraph', runs: [InlineRun('Bright here.')]),
      Block(id: 'b', type: 'paragraph', runs: [InlineRun('Dimmed there.')]),
    ]);
    final editor = HomericEditorController(
      document: doc,
      selection: HomericSelection.collapsed(doc.positionAt(0, 2)),
    );
    addTearDown(editor.dispose);
    final controller = HomericFocusDimController(
      vsync: const TestVSync(),
      initialGranularity: HomericFocusGranularity.paragraph,
    );
    addTearDown(controller.dispose);
    double alpha() {
      final layers = controller.paintLayersFor(
        block: doc.blocks[1],
        editor: editor,
        foregroundColor: ink,
        backgroundColor: paper,
      );
      return (layers.single.spec as SolidWashSpec).color.a;
    }

    final medium = alpha();
    expect(
      medium,
      closeTo(
          homericFocusWashOpacity(foreground: ink, background: paper), 0.002),
    );
    controller.strength = 0.9;
    expect(alpha(), greaterThan(medium + 0.1));
    controller.strength = 0.2;
    expect(alpha(), lessThan(medium));
  });
}
