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

  // KTD2: margin presentation is an optional module built on published
  // geometry. The core may not reach into it, and the core library does
  // not export it.
  test('core modules never import the margin module', () {
    const coreDirs = [
      'lib/src/model',
      'lib/src/transform',
      'lib/src/decoration',
      'lib/src/view',
      'lib/src/render',
      'lib/src/editing',
    ];
    final marginImport = RegExp(
      '''^\\s*(import|export)\\s+['"]([^'"]*/)?margin(/|\\.dart['"])''',
    );
    final offenders = <String>[];
    var scanned = 0;
    for (final dir in coreDirs) {
      final directory = Directory(dir);
      expect(directory.existsSync(), isTrue, reason: '$dir is missing');
      final files = directory
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'));
      for (final file in files) {
        scanned++;
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (marginImport.hasMatch(lines[i])) {
            offenders.add('${file.path}:${i + 1}: ${lines[i].trim()}');
          }
        }
      }
    }
    expect(scanned, greaterThanOrEqualTo(30));
    expect(offenders, isEmpty,
        reason: 'core modules must not depend on margin presentation '
            '(KTD2):\n${offenders.join('\n')}');

    expect(
        marginImport.hasMatch("import '../margin/margin_layer.dart';"), isTrue,
        reason: 'the guard must recognise a relative margin import');
    expect(
        marginImport.hasMatch("import 'package:homeric/margin.dart';"), isTrue);
    final library = File('lib/homeric.dart').readAsStringSync();
    expect(library, isNot(contains('margin')),
        reason: 'margin types ship only through package:homeric/margin.dart');
  });
}
