import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

const _wordCount = 2500;
const _cachedMoveCount = 200;
const _paragraphWidth = 720.0;
const _sampleCount = 5;
const _firstMoveBudgetUs = 100000;
const _cachedMoveAverageBudgetUs = 50.0;

Future<void> main() async {
  assert(false, 'Run this benchmark in profile or release mode.');
  var passed = false;
  await benchmarkWidgets((tester) async {
    final text = List<String>.generate(
      _wordCount,
      (index) => 'word${index % 100}',
      growable: false,
    ).join(' ');
    final source = ParagraphSource<TextStyle>.build(
      block: Block(
        id: 'visual-caret-benchmark',
        type: 'paragraph',
        runs: <InlineRun>[InlineRun(text)],
      ),
      decorations: const <Decoration>[],
      resolveStyle: (_) => const TextStyle(fontSize: 16),
    );
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: _paragraphWidth,
            child: HomericParagraph(source: source),
          ),
        ),
      ),
    );
    final render = tester.renderObject<RenderHomericParagraph>(
      find.byType(HomericParagraph),
    );
    final firstMoveSamplesUs = <int>[];
    final cachedMoveSamplesUs = <int>[];
    for (var sample = 0; sample < _sampleCount; sample++) {
      final geometry = ParagraphGeometry(render);
      final firstMove = Stopwatch()..start();
      geometry.moveCaret(
        DocOffset.zero,
        direction: CaretMovementDirection.right,
      );
      firstMove.stop();
      firstMoveSamplesUs.add(firstMove.elapsedMicroseconds);

      var result = geometry
          .moveCaret(
            DocOffset(text.length),
            direction: CaretMovementDirection.left,
          )
          .value;
      final cachedMoves = Stopwatch()..start();
      for (var index = 0; index < _cachedMoveCount; index++) {
        result = geometry
            .moveCaret(
              result.position,
              affinity: result.affinity,
              direction: CaretMovementDirection.left,
            )
            .value;
      }
      cachedMoves.stop();
      cachedMoveSamplesUs.add(cachedMoves.elapsedMicroseconds);
    }
    final firstMoveMedianUs = _median(firstMoveSamplesUs);
    final cachedMovesMedianUs = _median(cachedMoveSamplesUs);
    final cachedMoveAverageUs = cachedMovesMedianUs / _cachedMoveCount;
    passed = firstMoveMedianUs <= _firstMoveBudgetUs &&
        cachedMoveAverageUs <= _cachedMoveAverageBudgetUs;

    stdout.writeln(jsonEncode(<String, Object>{
      'benchmark': 'visual_caret_navigation',
      'profile': true,
      'words': _wordCount,
      'code_units': text.length,
      'samples': _sampleCount,
      'first_move_samples_us': firstMoveSamplesUs,
      'first_move_median_us': firstMoveMedianUs,
      'first_move_budget_us': _firstMoveBudgetUs,
      'cached_move_count': _cachedMoveCount,
      'cached_moves_samples_us': cachedMoveSamplesUs,
      'cached_moves_median_us': cachedMovesMedianUs,
      'cached_move_average_us': cachedMoveAverageUs,
      'cached_move_average_budget_us': _cachedMoveAverageBudgetUs,
      'within_budget': passed,
    }));
  });
  await Future<void>.delayed(const Duration(seconds: 2));
  exit(passed ? 0 : 2);
}

int _median(List<int> values) {
  values.sort();
  return values[values.length ~/ 2];
}
