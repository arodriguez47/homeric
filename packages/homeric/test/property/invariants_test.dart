// U7 — the six Phase 1 invariants over a fixed, deterministic seed
// corpus, generator self-tests proving the boundary bias occurs, and the
// mutation-tooth tests proving the harness catches a corrupted StepMap.

import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

import '../transform/transform_test_utils.dart';
import 'generators.dart';

/// The fixed seed corpus: deterministic in CI, small enough to stay fast.
const List<int> fixedSeeds = [
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10, //
  11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
  21, 22, 23, 24, 25, 26, 27, 28, 29, 30,
  31, 32, 33, 34, 35, 36, 37, 38, 39, 40,
  31337, 271828, 314159, 424242, 999983, 7919, 104729, 20260808,
];

void main() {
  group('six invariants over the fixed seed corpus', () {
    for (final seed in fixedSeeds) {
      test('seed $seed', () => runSeed(seed));
    }
  });

  group('generator self-tests (the boundary bias actually occurs)', () {
    final stats = GeneratorStats();
    setUpAll(() {
      for (var seed = 1; seed <= 300; seed++) {
        stats.absorb(FuzzScenario.generate(seed).stats);
      }
    });

    test('empty blocks and empty runs are generated', () {
      expect(stats.emptyBlocks, greaterThan(0));
      expect(stats.emptyRuns, greaterThan(0));
    });

    test('nexus-shaped attribute bags are generated', () {
      expect(stats.nexusBags, greaterThan(0));
    });

    test('collapsed and adjacent decorations are generated', () {
      expect(stats.collapsedDecorations, greaterThan(0));
      expect(stats.adjacentDecorationPairs, greaterThan(0));
    });

    test('whole-block and zero-length (hide) replacements are generated', () {
      expect(stats.wholeBlockReplaces, greaterThan(0));
      expect(stats.zeroLengthReplacements, greaterThan(0));
    });

    test('edits land on block edges and on the document start/end', () {
      expect(stats.editsAtBlockEdge, greaterThan(0));
      expect(stats.editsAtDocStart, greaterThan(0));
      expect(stats.editsAtDocEnd, greaterThan(0));
    });

    test('collapsed anchors are generated', () {
      expect(stats.collapsedAnchors, greaterThan(0));
    });

    test('every builder kind occurs in the corpus', () {
      const builders = [
        'insertText',
        'deleteRange',
        'splitBlock',
        'joinBlocks',
        'moveBlock',
        'setBlockType',
        'toggleMark',
      ];
      for (final kind in builders) {
        expect(stats.opCounts[kind] ?? 0, greaterThan(0),
            reason: 'builder $kind never occurred across the corpus');
      }
    });

    test('every decoration kind occurs in the corpus', () {
      for (final kind in DecorationKind.values) {
        expect(stats.decorationKindCounts[kind.name] ?? 0, greaterThan(0),
            reason: 'decoration kind ${kind.name} never occurred across the '
                'corpus');
      }
    });

    test('generation is deterministic per seed', () {
      final a = FuzzScenario.generate(424242);
      final b = FuzzScenario.generate(424242);
      expect(a.describe(), b.describe());
      expect(dumpDoc(a.tx.doc), dumpDoc(b.tx.doc));
      expect(a.tx.steps.length, b.tx.steps.length);
    });
  });

  group('regressions found by the fuzzer', () {
    test(
        'mark steps skip empty runs inside the range '
        '(seed 20362345; fixed in run_ops.dart)', () {
      // The model legally allows empty runs. toggleMark's segment scan is
      // character-based (empty runs contribute nothing), so with every
      // character marked it emits one RemoveMarkStep over the whole
      // range — which used to fail as soon as the range contained a
      // markless empty run.
      final doc = Document([
        Block(id: 'a', type: 'paragraph', runs: [
          InlineRun('ab', attributes: const {'bold': 1}),
          InlineRun(''),
          InlineRun('cd', attributes: const {'bold': 1}),
        ]),
      ]);
      final tx = Transaction(doc)..toggleMark(1, 5, 'bold', 1);
      final runs = tx.doc.blocks.single.runs;
      expect(tx.doc.blocks.single.text, 'abcd');
      expect(runs.any((r) => r.attributes.containsKey('bold')), isFalse,
          reason: 'toggling a fully marked range must remove the mark');
    });
  });

  group('mutation tooth (the harness catches a corrupted StepMap)', () {
    test('a perturbed triple is caught by the composition law', () {
      final doc = Document([para('a', 'alpha'), para('b', 'bravo')]);
      final tx = Transaction(doc)
        ..insertText(3, 'xy')
        ..deleteRange(10, 12);
      final parts = <Mappable>[for (final step in tx.steps) step.getMap()];

      // The healthy mapping satisfies both laws.
      checkSequentialCompositionLaw(tx.mapping, parts, doc.size);
      checkMappingInvertLaw(tx.mapping, doc.size);

      // Deliberately corrupt one triple: newSize off by one.
      final corruptedTriples = List<int>.of(tx.steps.first.getMap().ranges);
      corruptedTriples[2] += 1;
      final corrupted = Mapping()..appendMap(StepMap(corruptedTriples));
      for (final step in tx.steps.skip(1)) {
        corrupted.appendMap(step.getMap());
      }
      expect(
        () => checkSequentialCompositionLaw(corrupted, parts, doc.size),
        throwsStateError,
        reason: 'invariant 2 must detect the corrupted StepMap',
      );
    });

    test('a perturbed triple misplaces a tracked anchor', () {
      // Invariant 5/6 teeth: the corrupted map is internally consistent
      // (its own invert restores its own positions), so the catch is the
      // document ground truth — the text under the mapped anchor.
      final doc = Document([para('a', 'alpha'), para('b', 'bravo')]);
      final tx = Transaction(doc)..insertText(3, 'xy');
      const anchorFrom = 9; // 'rav' inside "bravo"
      const anchorTo = 12;
      expect(textBetween(doc, anchorFrom, anchorTo), 'rav');

      // The healthy mapping preserves the anchored text.
      final mappedFrom = tx.mapping.map(anchorFrom, assoc: 1);
      final mappedTo = tx.mapping.map(anchorTo, assoc: -1);
      expect(textBetween(tx.doc, mappedFrom, mappedTo), 'rav');

      // The corrupted one shifts it — exactly what invariant 6 asserts on.
      final corruptedTriples = List<int>.of(tx.steps.single.getMap().ranges);
      corruptedTriples[2] += 1;
      final corrupted = Mapping()..appendMap(StepMap(corruptedTriples));
      final badFrom = corrupted.map(anchorFrom, assoc: 1);
      final badTo = corrupted.map(anchorTo, assoc: -1);
      expect(textBetween(tx.doc, badFrom, badTo), isNot('rav'),
          reason: 'invariant 6 must detect the corrupted StepMap');
    });
  });
}
