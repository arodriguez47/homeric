// Headless benchmark for Homeric. Run with:
//   flutter test integration_test/benchmark_test.dart --machine
//
// Phase 1 Week 2 deliverable. The integration_test binding's `traceAction`
// produces a Chrome trace whose summary we extract to JSON for CI diffing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:benchmark_100k/main.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('cold load + scroll benchmark, large.md', (tester) async {
    await binding.traceAction(
      () async {
        await tester.pumpWidget(const BenchmarkApp());
        await tester.pumpAndSettle(const Duration(seconds: 10));

        // Scroll the full document end-to-end and back.
        await tester.fling(find.byType(Scrollable).first, const Offset(0, -5000), 1500);
        await tester.pumpAndSettle();
        await tester.fling(find.byType(Scrollable).first, const Offset(0, 5000), 1500);
        await tester.pumpAndSettle();
      },
      reportKey: 'homeric_benchmark',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
