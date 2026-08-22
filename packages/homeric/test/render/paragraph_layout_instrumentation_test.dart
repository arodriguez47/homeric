import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

import 'render_test_utils.dart';

void main() {
  testWidgets('probe counts every paragraph layout category and total',
      (tester) async {
    final probe = HomericParagraphLayoutProbe.start();
    addTearDown(probe.stop);

    await tester.pumpWidget(_harness(
      HomericParagraph(
        source: sourceOf('alpha beta'),
      ),
    ));

    final render = tester.renderObject<RenderHomericParagraph>(
      find.byType(HomericParagraph),
    );
    render.getMinIntrinsicWidth(double.infinity);

    await tester.pumpWidget(_harness(
      HomericParagraph(
        source: sourceOf('alpha beta'),
        paintStyler: (segment) => segment.style.copyWith(color: Colors.red),
      ),
    ));

    final report = probe.stop();
    expect(
        report.countFor(HomericParagraphLayoutCategory.live), greaterThan(0));
    expect(
      report.countFor(HomericParagraphLayoutCategory.intrinsic),
      greaterThan(0),
    );
    expect(
      report.countFor(HomericParagraphLayoutCategory.paintRebuild),
      greaterThan(0),
    );
    expect(report.totalCount, report.counts.values.reduce((a, b) => a + b));
    expect(
      report.totalElapsed,
      report.elapsed.values.reduce((a, b) => a + b),
    );
  });

  testWidgets('empty layout reports the template category', (tester) async {
    final probe = HomericParagraphLayoutProbe.start();
    addTearDown(probe.stop);

    await tester.pumpWidget(
      _harness(
        Baseline(
          baseline: 30,
          baselineType: TextBaseline.alphabetic,
          child: HomericParagraph(source: sourceOf('')),
        ),
      ),
    );

    expect(
      probe.stop().countFor(HomericParagraphLayoutCategory.template),
      greaterThan(0),
    );
  });

  test('disabled instrumentation has no active probe', () {
    expect(HomericParagraphLayoutProbe.isActive, isFalse);
  });
}

Widget _harness(Widget child) => harness(child);
