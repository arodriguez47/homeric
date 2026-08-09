// R1 as a regression gate: the Phase 1 modules must stay pure Dart.
//
// The pubspec keeps its Flutter dependency (Phase 2 rendering needs it),
// so purity is enforced here instead: no file under the four Phase 1
// module directories may import or export `package:flutter` or `dart:ui`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Phase 1 modules import no Flutter and no dart:ui', () {
    const moduleDirs = [
      'lib/src/model',
      'lib/src/transform',
      'lib/src/decoration',
      'lib/src/view',
    ];
    final forbidden =
        RegExp('''^\\s*(import|export)\\s+['"](package:flutter|dart:ui)''');
    final offenders = <String>[];
    var scanned = 0;
    for (final dir in moduleDirs) {
      final directory = Directory(dir);
      expect(directory.existsSync(), isTrue,
          reason: '$dir is missing — did the Phase 1 layout move? '
              'Update this guard rather than deleting it.');
      final files = directory
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'));
      for (final file in files) {
        scanned++;
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (forbidden.hasMatch(lines[i])) {
            offenders.add('${file.path}:${i + 1}: ${lines[i].trim()}');
          }
        }
      }
    }
    expect(scanned, greaterThanOrEqualTo(15),
        reason: 'suspiciously few Dart files scanned — the guard may be '
            'looking at the wrong directories');
    expect(offenders, isEmpty,
        reason: 'Phase 1 modules must not touch Flutter or dart:ui '
            '(R1):\n${offenders.join('\n')}');
  });
}
