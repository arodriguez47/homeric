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

  test('rejects every absolute limit and the reproducible p95 regression', () {
    final failures = largeGeneratedBudgetFailures(
      result: readJson(
        'benchmarks/testdata/large-generated-failing.json',
      ),
      accepted: readJson('benchmarks/accepted.json'),
    );

    expect(failures, hasLength(9));
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
        contains('scroll p95 frame time regression'),
      ]),
    );
  });

  test('cold mount uses its absolute budget, not an irreproducible baseline',
      () {
    final result = readJson(
      'benchmarks/testdata/large-generated-passing.json',
    );
    final coldMount = result['cold_mount']! as Map<String, Object?>;
    coldMount['total_p95_us'] = 49999;

    expect(
      largeGeneratedBudgetFailures(
        result: result,
        accepted: readJson('benchmarks/accepted.json'),
      ),
      isEmpty,
    );
  });

  test('derives the symmetric instrumentation calibration gate', () {
    final result = readJson(
      'benchmarks/testdata/large-generated-passing.json',
    );
    final calibration = result['calibration']! as Map<String, Object?>;

    for (final delta in [-500, 500]) {
      calibration
        ..['paired_total_p95_delta_basis_points'] = delta
        ..['valid'] = true;
      expect(instrumentationCalibrationFailure(result), isNull);
    }

    for (final delta in [-501, 501]) {
      calibration
        ..['paired_total_p95_delta_basis_points'] = delta
        ..['valid'] = true;
      expect(
        instrumentationCalibrationFailure(result),
        'instrumentation calibration was noisy: $delta bp',
      );
    }

    calibration
      ..['paired_total_p95_delta_basis_points'] = 0
      ..['layout_total_count'] = 1
      ..['valid'] = false;
    expect(
      instrumentationCalibrationFailure(result),
      'instrumentation calibration validity flag disagrees with '
      'recorded evidence',
    );

    calibration
      ..['paired_total_p95_delta_basis_points'] = 0
      ..['layout_total_count'] = 0
      ..['valid'] = true;
    expect(
      instrumentationCalibrationFailure(result),
      'instrumentation calibration recorded no paragraph layouts',
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
