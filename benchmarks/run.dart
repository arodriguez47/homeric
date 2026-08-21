import 'dart:convert';
import 'dart:io';

import 'performance_gate.dart';

const _fixtureCases = <(String, String)>[
  ('tiny.md', 'generated'),
  ('small.md', 'generated'),
  ('medium.md', 'generated'),
  ('large.md', 'generated'),
  ('xl.md', 'generated'),
  ('large.md', 'one_huge_block'),
  ('large.md', 'many_small_blocks'),
  ('large.md', 'alternating_heights'),
  ('large.md', 'biased_estimates'),
  ('large.md', 'height_churn'),
];

Future<void> main(List<String> arguments) async {
  final root = Directory.current.absolute;
  final playground = Directory(
    '${root.path}/packages/homeric/examples/playground',
  );
  final results = Directory('${root.path}/benchmarks/results');
  await results.create(recursive: true);

  final generator = await Process.run(
    'dart',
    ['run', 'tools/corpus/generate.dart'],
    workingDirectory: root.path,
  );
  stdout.write(generator.stdout);
  stderr.write(generator.stderr);
  if (generator.exitCode != 0) exit(generator.exitCode);

  final flutterVersion =
      await Process.run('flutter', ['--version', '--machine']);
  final metadata = <String, Object?>{
    'recorded_at_utc': DateTime.now().toUtc().toIso8601String(),
    'platform': Platform.operatingSystem,
    'platform_version': Platform.operatingSystemVersion,
    'dart_version': Platform.version,
    'flutter': flutterVersion.exitCode == 0
        ? jsonDecode(flutterVersion.stdout as String)
        : <String, Object?>{'error': 'flutter version unavailable'},
    'mode': 'profile',
    'device': 'macos',
    'aggregation': 'Flutter FrameTiming summary per fixed 5-second trace',
    'noise_policy':
        'Fresh-cache calibration uses four balanced paired exact-100-frame '
            'disabled/instrumented traces, must record real paragraph layouts, '
            'and must keep the median total-p95 delta within 5%.',
  };
  await File('${results.path}/run-metadata.json').writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(metadata)}\n',
  );

  final requested = arguments.isEmpty ? null : arguments.toSet();
  for (final (fixture, scenario) in _fixtureCases) {
    final name = '${fixture.substring(0, fixture.length - 3)}-$scenario';
    if (requested != null && !requested.contains(name)) continue;
    final fixturePath = '${root.path}/tools/corpus/out/$fixture';
    final resultPath = '${results.path}/$name.json';
    await File(fixturePath).copy(
      '${playground.path}/benchmark_assets/current.md',
    );
    stdout.writeln('benchmarking $name');
    final process = await Process.start(
      'flutter',
      [
        'drive',
        '--profile',
        '--no-dds',
        '-d',
        'macos',
        '--driver',
        'test_driver/perf_driver.dart',
        '--target',
        'integration_test/current_list_benchmark_test.dart',
        '--dart-define=HOMERIC_BENCH_FIXTURE=$fixture',
        '--dart-define=HOMERIC_BENCH_SCENARIO=$scenario',
      ],
      workingDirectory: playground.path,
      environment: {
        ...Platform.environment,
        'HOMERIC_BENCH_RESULT_PATH': resultPath,
      },
      mode: ProcessStartMode.inheritStdio,
    );
    final exitCode = await process.exitCode;
    if (exitCode != 0) exit(exitCode);
    if (name == 'large-generated') {
      await _enforceLargeGeneratedGate(root, resultPath);
    }
  }
}

Future<void> _enforceLargeGeneratedGate(
    Directory root, String resultPath) async {
  try {
    final result = jsonDecode(await File(resultPath).readAsString())
        as Map<String, Object?>;
    final calibrationFailure = instrumentationCalibrationFailure(result);
    if (calibrationFailure != null) {
      stderr.writeln('large-generated $calibrationFailure');
      exit(2);
    }

    final accepted = jsonDecode(
      await File('${root.path}/benchmarks/accepted.json').readAsString(),
    ) as Map<String, Object?>;
    final failures = largeGeneratedBudgetFailures(
      result: result,
      accepted: accepted,
    );
    if (failures.isEmpty) {
      stdout.writeln('large-generated performance gate passed');
      return;
    }

    stderr.writeln('large-generated performance gate failed:');
    for (final failure in failures) {
      stderr.writeln('  - $failure');
    }
    exit(3);
  } on FormatException catch (error) {
    stderr.writeln('large-generated performance gate could not be evaluated:');
    stderr.writeln('  - ${error.message}');
    exit(2);
  }
}
