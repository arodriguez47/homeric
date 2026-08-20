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
      accepted: readJson('benchmarks/accepted.json'),
    );

    expect(failures, isEmpty);
  });

  test('rejects saved results at every absolute limit and p95 regression', () {
    final failures = largeGeneratedBudgetFailures(
      result: readJson(
        'benchmarks/testdata/large-generated-failing.json',
      ),
      accepted: readJson('benchmarks/accepted.json'),
    );

    expect(failures, hasLength(10));
    expect(
      failures.join('\n'),
      allOf(<Matcher>[
        contains('time to first frame'),
        contains('cold-load p95 frame time: 50000 us'),
        contains('scroll p50 frame time'),
        contains('scroll p95 frame time: 33000 us'),
        contains('active widget count'),
        contains('five-second cumulative paragraph layout'),
        contains('detached paragraph cache entries'),
        contains('detached paragraph cache text'),
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

  test('rejects fast results from a different corpus or scenario', () {
    final result = readJson(
      'benchmarks/testdata/large-generated-passing.json',
    );
    final homeric = result['homeric']! as Map<String, Object?>;
    homeric
      ..['scenario'] = 'height_churn'
      ..['fixture_words'] = 99999
      ..['fixture_fnv1a32'] = '00000000'
      ..['blocks'] = 1119;

    expect(
      largeGeneratedBudgetFailures(
        result: result,
        accepted: readJson('benchmarks/accepted.json'),
      ).join('\n'),
      allOf(
        contains('benchmark scenario mismatch'),
        contains('fixture word count mismatch'),
        contains('fixture fingerprint mismatch'),
        contains('fixture block count mismatch'),
      ),
    );
  });

  test('allows exactly five percent p95 regression but rejects more', () {
    final result = readJson(
      'benchmarks/testdata/large-generated-passing.json',
    );
    final accepted = readJson('benchmarks/accepted.json');
    final observed = accepted['observed']! as Map<String, Object?>;
    final acceptedP95 = observed['scroll_disabled_total_p95_us']! as int;
    final largestAllowedP95 = acceptedP95 * 105 ~/ 100;
    final scroll = result['scroll_disabled']! as Map<String, Object?>;
    scroll['total_p95_us'] = largestAllowedP95;

    expect(
      largeGeneratedBudgetFailures(
        result: result,
        accepted: accepted,
      ),
      isEmpty,
    );

    scroll['total_p95_us'] = largestAllowedP95 + 1;
    expect(
      largeGeneratedBudgetFailures(
        result: result,
        accepted: accepted,
      ),
      contains(contains('scroll p95 frame time regression')),
    );
  });
}
