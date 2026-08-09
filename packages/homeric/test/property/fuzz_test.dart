// U7 — the randomized fuzz loop over the six Phase 1 invariants.
//
// The default run is CI-feasible and fully deterministic (a fixed base
// seed). Two environment variables tune it:
//
//   HOMERIC_FUZZ_SEED=<n>        run exactly seed n (the repro mode that
//                                failure messages point at)
//   HOMERIC_FUZZ_ITERATIONS=<n>  override the default iteration count
//   HOMERIC_DEEP_FUZZ=1          also run the opt-in deep loop (slow)

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'generators.dart';

void main() {
  final reproSeed =
      int.tryParse(Platform.environment['HOMERIC_FUZZ_SEED'] ?? '');
  if (reproSeed != null) {
    test('fuzz repro: seed $reproSeed', () => runSeed(reproSeed));
    return;
  }

  const baseSeed = 20260808;
  final iterations =
      int.tryParse(Platform.environment['HOMERIC_FUZZ_ITERATIONS'] ?? '') ??
          10000;

  test(
    'fuzz: six invariants over $iterations scenarios '
    '(seeds $baseSeed..${baseSeed + iterations - 1})',
    () {
      for (var i = 0; i < iterations; i++) {
        runSeed(baseSeed + i);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  final deepEnabled = Platform.environment.containsKey('HOMERIC_DEEP_FUZZ');
  test(
    'deep fuzz: 50000 scenarios (opt-in)',
    () {
      for (var i = 0; i < 50000; i++) {
        runSeed(baseSeed + 100000 + i);
      }
    },
    skip: deepEnabled
        ? false
        : 'opt-in: HOMERIC_DEEP_FUZZ=1 flutter test test/property '
            '(or `melos run fuzz-deep`)',
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
