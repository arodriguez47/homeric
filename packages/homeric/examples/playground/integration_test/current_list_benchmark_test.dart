import 'dart:ui' show FrameTiming;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric_playground/benchmark/benchmark_fixture.dart';
import 'package:homeric_playground/view_models/document_view_model.dart';
import 'package:homeric_playground/views/editor_page.dart';
import 'package:integration_test/integration_test.dart';

const _fixtureName = String.fromEnvironment('HOMERIC_BENCH_FIXTURE');
const _scenario = String.fromEnvironment(
  'HOMERIC_BENCH_SCENARIO',
  defaultValue: 'generated',
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Homeric document viewport profile trace', (tester) async {
    if (_fixtureName.isEmpty) {
      fail('HOMERIC_BENCH_FIXTURE must name a generated corpus file.');
    }
    tester.view
      ..physicalSize = const Size(1440, 900)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final coldLoad = Stopwatch()..start();
    final markdown = await rootBundle.loadString('benchmark_assets/current.md');
    final fixtureIdentity = benchmarkFixtureIdentity(markdown);
    final document = _scenarioDocument(markdown, _scenario);
    final viewModel = DocumentViewModel(document: document);
    addTearDown(viewModel.dispose);

    final firstController = ScrollController();
    final firstMount = Stopwatch()..start();
    await tester.pumpWidget(_surface(viewModel, firstController));
    firstMount.stop();
    coldLoad.stop();

    var maxMounted = _mountedRows();
    var maxParagraphCacheEntries = 0;
    var maxParagraphCacheTextCodeUnits = 0;
    final initialMounted = maxMounted;
    expect(initialMounted, lessThan(500));
    if (document.blockCount > 1) {
      expect(initialMounted, lessThan(document.blockCount),
          reason: 'the current control must stay lazy');
    }
    await tester.pumpWidget(const SizedBox.shrink());
    firstController.dispose();

    final disabledSamples = <Map<String, Object>>[];
    final instrumentedSamples = <Map<String, Object>>[];
    final coldMountSamples = <Map<String, Object>>[];
    final layoutCounts = <HomericParagraphLayoutCategory, int>{};
    final layoutElapsed = <HomericParagraphLayoutCategory, Duration>{};
    final layoutSampleTotalsUs = <int>[];
    for (var sample = 0; sample < 3; sample++) {
      final pair = await _runSamplePair(
        binding,
        tester,
        viewModel,
        instrumentedFirst: sample.isOdd,
        onMountedRows: (count) {
          if (count > maxMounted) maxMounted = count;
        },
      );
      disabledSamples.add(pair.disabledFrames);
      instrumentedSamples.add(pair.instrumentedFrames);
      coldMountSamples.addAll(pair.coldFrames);
      if (pair.paragraphCacheEntries > maxParagraphCacheEntries) {
        maxParagraphCacheEntries = pair.paragraphCacheEntries;
      }
      if (pair.paragraphCacheTextCodeUnits > maxParagraphCacheTextCodeUnits) {
        maxParagraphCacheTextCodeUnits = pair.paragraphCacheTextCodeUnits;
      }
      layoutSampleTotalsUs.add(
        pair.layout.totalElapsed.inMicroseconds,
      );
      for (final category in HomericParagraphLayoutCategory.values) {
        layoutCounts.update(
          category,
          (value) => value + pair.layout.countFor(category),
          ifAbsent: () => pair.layout.countFor(category),
        );
        layoutElapsed.update(
          category,
          (value) => value + (pair.layout.elapsed[category] ?? Duration.zero),
          ifAbsent: () => pair.layout.elapsed[category] ?? Duration.zero,
        );
      }
    }

    binding.reportData ??= <String, dynamic>{};
    binding.reportData!['scroll_disabled'] = _aggregate(disabledSamples);
    binding.reportData!['scroll_instrumented'] =
        _aggregate(instrumentedSamples);
    binding.reportData!['cold_mount'] = _aggregate(coldMountSamples);
    final overheadBps = _pairedDeltaBps(
      disabledSamples,
      instrumentedSamples,
      'total_p95_us',
    );
    binding.reportData!['calibration'] = <String, Object>{
      'paired_total_p95_delta_basis_points': overheadBps,
      'valid': overheadBps.abs() <= 500,
      'threshold_basis_points': 500,
    };
    binding.reportData!['homeric'] = <String, dynamic>{
      'fixture': _fixtureName,
      'scenario': _scenario,
      'fixture_words': fixtureIdentity.words,
      'fixture_fnv1a32': fixtureIdentity.fnv1a32,
      'blocks': document.blockCount,
      'viewport': <String, Object>{
        'logical_width': 1440,
        'logical_height': 900,
        'device_pixel_ratio': 1,
        'text_scale': 1,
        'cache_extent': 250,
      },
      'first_mount_us': firstMount.elapsedMicroseconds,
      'cold_load_first_frame_us': coldLoad.elapsedMicroseconds,
      'initial_mounted_rows': initialMounted,
      'max_mounted_rows': maxMounted,
      'paragraph_cache_entries': maxParagraphCacheEntries,
      'paragraph_cache_text_code_units': maxParagraphCacheTextCodeUnits,
      'layout_total_count':
          layoutCounts.values.fold(0, (sum, value) => sum + value),
      'layout_total_us': layoutElapsed.values.fold(
        0,
        (sum, value) => sum + value.inMicroseconds,
      ),
      'layout_sample_total_us': layoutSampleTotalsUs,
      'layout_median_sample_us': _median(List.of(layoutSampleTotalsUs)),
      'layout_counts': <String, int>{
        for (final category in HomericParagraphLayoutCategory.values)
          category.name: layoutCounts[category] ?? 0,
      },
      'layout_us': <String, int>{
        for (final category in HomericParagraphLayoutCategory.values)
          category.name:
              (layoutElapsed[category] ?? Duration.zero).inMicroseconds,
      },
      'trace': <String, Object>{
        'duration_ms': 5000,
        'steps': 100,
        'warmup_outward_traversals': 1,
        'samples_per_mode': 3,
        'order': 'paired alternating disabled/instrumented',
        'height_churn_changes': _scenario == 'height_churn' ? 3 : 0,
      },
    };
  });
}

Widget _surface(DocumentViewModel viewModel, ScrollController controller) =>
    MaterialApp(
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: Scaffold(
        body: EditorPage(
          viewModel: viewModel,
          cacheExtent: 250,
          scrollController: controller,
        ),
      ),
    );

Future<_BenchmarkSamplePair> _runSamplePair(
  IntegrationTestWidgetsFlutterBinding binding,
  WidgetTester tester,
  DocumentViewModel viewModel, {
  required bool instrumentedFirst,
  required ValueChanged<int> onMountedRows,
}) async {
  final controlController = ScrollController();
  final controlColdFrames = await _watchFrames(
    binding,
    () => tester.pumpWidget(_surface(viewModel, controlController)),
  );
  onMountedRows(_mountedRows());
  await tester.pumpWidget(const SizedBox.shrink());
  controlController.dispose();

  final controller = ScrollController();
  final pairedColdFrames = await _watchFrames(
    binding,
    () => tester.pumpWidget(_surface(viewModel, controller)),
  );
  onMountedRows(_mountedRows());
  await _warmUp(tester, controller);
  late final Map<String, Object> disabledFrames;
  late final Map<String, Object> instrumentedFrames;
  late final HomericParagraphLayoutReport layout;
  late final int paragraphCacheEntries;
  late final int paragraphCacheTextCodeUnits;
  try {
    Future<void> runDisabled() async {
      disabledFrames = await _watchFrames(
        binding,
        () => _trace(tester, controller, onMountedRows),
      );
    }

    Future<void> runInstrumented() async {
      final probe = HomericParagraphLayoutProbe.start();
      try {
        instrumentedFrames = await _watchFrames(
          binding,
          () => _trace(tester, controller, onMountedRows),
        );
      } finally {
        layout = probe.stop();
      }
    }

    if (instrumentedFirst) {
      await runInstrumented();
      await runDisabled();
    } else {
      await runDisabled();
      await runInstrumented();
    }
    final documentState = tester.state<HomericEditableDocumentState>(
      find.byType(HomericEditableDocument),
    );
    paragraphCacheEntries = documentState.debugParagraphLayoutCacheEntries;
    paragraphCacheTextCodeUnits =
        documentState.debugParagraphLayoutCacheTextCodeUnits;
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  }
  return _BenchmarkSamplePair(
    disabledFrames,
    instrumentedFrames,
    <Map<String, Object>>[controlColdFrames, pairedColdFrames],
    layout,
    paragraphCacheEntries,
    paragraphCacheTextCodeUnits,
  );
}

final class _BenchmarkSamplePair {
  const _BenchmarkSamplePair(
    this.disabledFrames,
    this.instrumentedFrames,
    this.coldFrames,
    this.layout,
    this.paragraphCacheEntries,
    this.paragraphCacheTextCodeUnits,
  );

  final Map<String, Object> disabledFrames;
  final Map<String, Object> instrumentedFrames;
  final List<Map<String, Object>> coldFrames;
  final HomericParagraphLayoutReport layout;
  final int paragraphCacheEntries;
  final int paragraphCacheTextCodeUnits;
}

Map<String, Object> _aggregate(List<Map<String, Object>> samples) {
  const metrics = <String>[
    'build_p50_us',
    'build_p95_us',
    'raster_p50_us',
    'raster_p95_us',
    'total_p50_us',
    'total_p95_us',
    'total_worst_us',
  ];
  return <String, Object>{
    'sample_count': samples.length,
    'frame_count': samples.fold<int>(
      0,
      (sum, sample) => sum + (sample['sample_count']! as int),
    ),
    for (final metric in metrics)
      metric: _median([
        for (final sample in samples) sample[metric]! as int,
      ]),
    'samples': samples,
  };
}

int _median(List<int> values) {
  values.sort();
  return values[values.length ~/ 2];
}

int _pairedDeltaBps(
  List<Map<String, Object>> control,
  List<Map<String, Object>> instrumented,
  String metric,
) {
  return _median([
    for (var index = 0; index < control.length; index++)
      ((((instrumented[index][metric]! as int) /
                      (control[index][metric]! as int)) -
                  1) *
              10000)
          .round(),
  ]);
}

Document _scenarioDocument(String markdown, String scenario) {
  final generated = benchmarkDocumentFromMarkdown(markdown);
  final words = markdown.trim().split(RegExp(r'\s+'));
  return switch (scenario) {
    'generated' => generated,
    'one_huge_block' => Document([
        Block(
          id: 'benchmark-huge',
          type: 'paragraph',
          runs: [InlineRun(markdown)],
        ),
      ]),
    'many_small_blocks' => Document([
        for (var index = 0; index < words.length; index += 4)
          Block(
            id: 'benchmark-small-$index',
            type: 'paragraph',
            runs: [
              InlineRun(
                words
                    .sublist(index, (index + 4).clamp(0, words.length))
                    .join(' '),
              ),
            ],
          ),
      ]),
    'alternating_heights' => Document([
        for (var index = 0; index < generated.blockCount; index++)
          Block(
            id: 'benchmark-alternating-$index',
            type: 'paragraph',
            runs: [
              InlineRun(index.isEven
                  ? 'short block'
                  : List.filled(4, generated.blocks[index].text).join(' ')),
            ],
          ),
      ]),
    'biased_estimates' => Document([
        for (var index = 0; index < generated.blockCount; index++)
          Block(
            id: 'benchmark-biased-$index',
            type: 'paragraph',
            runs: [
              InlineRun(index.isEven
                  ? 'short block'
                  : List.filled(4, generated.blocks[index].text).join(' ')),
            ],
          ),
      ]),
    'height_churn' => generated,
    _ => throw ArgumentError.value(scenario, 'scenario'),
  };
}

int _mountedRows() => find.byType(HomericEditableParagraph).evaluate().length;

Future<void> _warmUp(
  WidgetTester tester,
  ScrollController controller,
) async {
  final max = controller.position.maxScrollExtent;
  for (var step = 0; step < 50; step++) {
    controller.jumpTo(max * step / 49);
    await tester.pump();
  }
  controller.jumpTo(0);
  await tester.pump();
}

Future<void> _trace(
  WidgetTester tester,
  ScrollController controller,
  ValueChanged<int> onMountedRows, {
  Duration stepDuration = const Duration(milliseconds: 50),
  bool applyScenarioChanges = true,
}) async {
  final max = controller.position.maxScrollExtent;
  for (var step = 0; step < 100; step++) {
    final progress = step < 50 ? step / 49 : (99 - step) / 49;
    controller.jumpTo(max * progress);
    await tester.pump(stepDuration);
    if (applyScenarioChanges &&
        _scenario == 'height_churn' &&
        (step == 25 || step == 50 || step == 75)) {
      await tester.drag(
        find.byType(Slider),
        Offset(step == 50 ? -40 : 40, 0),
      );
      await tester.pump();
    }
    onMountedRows(_mountedRows());
  }
}

Future<Map<String, Object>> _watchFrames(
  IntegrationTestWidgetsFlutterBinding binding,
  Future<void> Function() action,
) async {
  final timings = <FrameTiming>[];
  final void Function(List<FrameTiming>) watcher = timings.addAll;
  binding.addTimingsCallback(watcher);
  try {
    await action();
    await Future<void>.delayed(const Duration(seconds: 2));
  } finally {
    binding.removeTimingsCallback(watcher);
  }
  if (timings.isEmpty) {
    throw StateError('The benchmark trace produced no FrameTiming samples.');
  }
  final build = [
    for (final timing in timings) timing.buildDuration.inMicroseconds,
  ]..sort();
  final raster = [
    for (final timing in timings) timing.rasterDuration.inMicroseconds,
  ]..sort();
  final total = [
    for (final timing in timings) timing.totalSpan.inMicroseconds,
  ]..sort();
  return <String, Object>{
    'sample_count': timings.length,
    'build_p50_us': _percentile(build, 0.50),
    'build_p95_us': _percentile(build, 0.95),
    'raster_p50_us': _percentile(raster, 0.50),
    'raster_p95_us': _percentile(raster, 0.95),
    'total_p50_us': _percentile(total, 0.50),
    'total_p95_us': _percentile(total, 0.95),
    'total_worst_us': total.last,
  };
}

int _percentile(List<int> sorted, double percentile) =>
    sorted[((sorted.length - 1) * percentile).ceil()];
