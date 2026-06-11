// Homeric — 100k-word benchmark harness.
//
// Phase 1 deliverable. Loads a Markdown fixture from `tools/corpus/` and
// renders it in a SuperEditor. Reports widget count, render object count,
// and frame timings to stdout.
//
// Run with:
//   flutter run -d macos --release --dart-define=HOMERIC_FIXTURE=large.md

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric_markdown/homeric_markdown.dart';

const _kFixture = String.fromEnvironment(
  'HOMERIC_FIXTURE',
  defaultValue: 'small.md',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BenchmarkApp());
}

class BenchmarkApp extends StatelessWidget {
  const BenchmarkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Homeric Benchmark',
      home: BenchmarkScreen(fixture: _kFixture),
    );
  }
}

class BenchmarkScreen extends StatefulWidget {
  const BenchmarkScreen({super.key, required this.fixture});
  final String fixture;

  @override
  State<BenchmarkScreen> createState() => _BenchmarkScreenState();
}

class _BenchmarkScreenState extends State<BenchmarkScreen> {
  MutableDocument? _document;
  Editor? _editor;
  final _frameTimings = <FrameTiming>[];
  late final DateTime _loadStarted;

  @override
  void initState() {
    super.initState();
    _loadStarted = DateTime.now();
    SchedulerBinding.instance.addTimingsCallback(_onFrame);
    _loadFixture();
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onFrame);
    super.dispose();
  }

  void _onFrame(List<FrameTiming> timings) {
    _frameTimings.addAll(timings);
  }

  Future<void> _loadFixture() async {
    final corpusDir = Platform.environment['HOMERIC_CORPUS_DIR'] ??
        '${Directory.current.path}/../../tools/corpus/out';
    final file = File('$corpusDir/${widget.fixture}');
    final markdown = await file.readAsString();

    final doc = deserializeMarkdownToDocument(markdown);
    final editor = createDefaultDocumentEditor(
      document: doc,
      composer: MutableDocumentComposer(),
    );

    final loadedMs = DateTime.now().difference(_loadStarted).inMilliseconds;
    debugPrint('[homeric.benchmark] fixture=${widget.fixture} '
        'blocks=${doc.nodeCount} loadMs=$loadedMs');

    setState(() {
      _document = doc;
      _editor = editor;
    });
  }

  @override
  Widget build(BuildContext context) {
    final doc = _document;
    final editor = _editor;
    if (doc == null || editor == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('Homeric · ${widget.fixture} · ${doc.nodeCount} blocks'),
        actions: [
          IconButton(
            icon: const Icon(Icons.assessment_outlined),
            tooltip: 'Dump frame stats',
            onPressed: _dumpStats,
          ),
        ],
      ),
      body: SuperEditor(editor: editor),
    );
  }

  void _dumpStats() {
    if (_frameTimings.isEmpty) {
      debugPrint('[homeric.benchmark] no frames recorded yet');
      return;
    }
    final buildMicros = _frameTimings.map((t) => t.buildDuration.inMicroseconds).toList()..sort();
    final rasterMicros = _frameTimings.map((t) => t.rasterDuration.inMicroseconds).toList()..sort();
    String pct(List<int> sorted, double p) {
      final idx = ((sorted.length - 1) * p).round();
      return '${(sorted[idx] / 1000).toStringAsFixed(1)}ms';
    }

    debugPrint('[homeric.benchmark] frames=${_frameTimings.length} '
        'build p50=${pct(buildMicros, 0.50)} '
        'p95=${pct(buildMicros, 0.95)} '
        'p99=${pct(buildMicros, 0.99)} | '
        'raster p50=${pct(rasterMicros, 0.50)} '
        'p95=${pct(rasterMicros, 0.95)} '
        'p99=${pct(rasterMicros, 0.99)}');
  }
}
