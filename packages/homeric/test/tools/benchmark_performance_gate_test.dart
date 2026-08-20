import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../../benchmarks/performance_gate.dart';

void main() {
  final repositoryRoot = Directory.current.parent.parent;

  Map<String, Object?> readJson(String path) =>
      jsonDecode(File('${repositoryRoot.path}/$path').readAsStringSync())
          as Map<String, Object?>;

  test('accepts a saved large-generated result within every budget', () {
    final failures = largeGeneratedBudgetFailures(
      result: readJson(
        'benchmarks/testdata/large-generated-passing.json',
      ),
      baseline: readJson('benchmarks/baseline.json'),
    );

    expect(failures, isEmpty);
  });

  test('rejects saved results at every absolute limit and p95 regression', () {
    final failures = largeGeneratedBudgetFailures(
      result: readJson(
        'benchmarks/testdata/large-generated-failing.json',
      ),
      baseline: readJson('benchmarks/baseline.json'),
    );

    expect(failures, hasLength(8));
    expect(
      failures.join('\n'),
      allOf(<Matcher>[
        contains('time to first frame'),
        contains('cold-load p95 frame time: 50000 us'),
        contains('scroll p50 frame time'),
        contains('scroll p95 frame time: 33000 us'),
        contains('active widget count'),
        contains('five-second cumulative paragraph layout'),
        contains('cold-load p95 frame time regression'),
        contains('scroll p95 frame time regression'),
      ]),
    );
  });

  test('preserves the instrumentation calibration gate', () {
    final result = readJson(
      'benchmarks/testdata/large-generated-passing.json',
    );
    result['calibration'] = <String, Object?>{
      'paired_total_p95_delta_basis_points': 501,
      'valid': false,
    };

    expect(
      instrumentationCalibrationFailure(result),
      'instrumentation calibration was noisy: 501 bp',
    );
  });

  test('allows exactly five percent p95 regression but rejects more', () {
    final result = readJson(
      'benchmarks/testdata/large-generated-passing.json',
    );
    final scroll = result['scroll_disabled']! as Map<String, Object?>;
    scroll['total_p95_us'] = 13496;

    expect(
      largeGeneratedBudgetFailures(
        result: result,
        baseline: readJson('benchmarks/baseline.json'),
      ),
      isEmpty,
    );

    scroll['total_p95_us'] = 13497;
    expect(
      largeGeneratedBudgetFailures(
        result: result,
        baseline: readJson('benchmarks/baseline.json'),
      ),
      contains(contains('scroll p95 frame time regression')),
    );
  });
}
