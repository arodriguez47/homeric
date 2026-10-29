import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

void main() {
  tearDown(HomericLetterMetrics.debugReset);

  test('a registered face answers at once', () {
    HomericLetterMetrics.register('Spectral', 0.45);
    const style = TextStyle(fontFamily: 'Spectral', fontSize: 20);
    expect(HomericLetterMetrics.ratioOf(style), 0.45);
    expect(
      HomericLetterMetrics.midlineAboveBaseline(
        style,
        textScaler: const TextScaler.linear(2),
      ),
      closeTo(20 * 2 * 0.45 / 2, 1e-9),
    );
  });

  test('a registered weight wins over the family', () {
    HomericLetterMetrics.register('Face', 0.4);
    HomericLetterMetrics.register('Face', 0.5, weight: FontWeight.w700);
    expect(
      HomericLetterMetrics.ratioOf(
          const TextStyle(fontFamily: 'Face', fontWeight: FontWeight.w700)),
      0.5,
    );
    expect(
      HomericLetterMetrics.ratioOf(const TextStyle(fontFamily: 'Face')),
      0.4,
    );
  });

  testWidgets('an unknown face is measured from its ink, then remembered',
      (tester) async {
    const style = TextStyle(fontFamily: 'Unregistered', fontSize: 30);
    var fired = 0;
    void count() => fired++;
    HomericLetterMetrics.changes.addListener(count);
    addTearDown(() => HomericLetterMetrics.changes.removeListener(count));

    await tester.runAsync(() => HomericLetterMetrics.ensure([style]));

    final ratio = HomericLetterMetrics.ratioOf(style);
    expect(ratio, isNot(HomericLetterMetrics.fallback));
    // The test font draws an x as a square from its ascent to the
    // baseline.
    expect(ratio, inInclusiveRange(0.6, 0.9));
    expect(fired, 1);
  });

  testWidgets('ensure leaves a face registered by family alone as it is',
      (tester) async {
    HomericLetterMetrics.register('Family', 0.41);
    const style = TextStyle(
      fontFamily: 'Family',
      fontWeight: FontWeight.w600,
      fontSize: 30,
    );
    await tester.runAsync(() => HomericLetterMetrics.ensure([style]));
    expect(HomericLetterMetrics.ratioOf(style), 0.41);
  });

  testWidgets('fonts loading later have measured faces measured again',
      (tester) async {
    const style = TextStyle(fontFamily: 'Later', fontSize: 30);
    await tester.runAsync(() => HomericLetterMetrics.ensure([style]));
    expect(HomericLetterMetrics.ratioOf(style),
        isNot(HomericLetterMetrics.fallback));
    var fired = 0;
    void count() => fired++;
    HomericLetterMetrics.changes.addListener(count);
    addTearDown(() => HomericLetterMetrics.changes.removeListener(count));

    await tester.binding
        .handleSystemMessage(<String, dynamic>{'type': 'fontsChange'});
    await tester.pump();

    expect(fired, 1);
    // Forgotten: asked again, it answers the guess while it re-measures.
    expect(HomericLetterMetrics.ratioOf(style), HomericLetterMetrics.fallback);
    await tester.runAsync(() => HomericLetterMetrics.ensure([style]));
    expect(HomericLetterMetrics.ratioOf(style),
        isNot(HomericLetterMetrics.fallback));
  });
}
