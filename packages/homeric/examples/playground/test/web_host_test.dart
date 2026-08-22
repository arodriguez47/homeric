import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('playground retains the web acceptance host', () {
    final index = File('web/index.html');
    expect(
      index.existsSync(),
      true,
      reason: 'MUTATION: deleting the web host makes HOM-21 best-effort web '
          'input impossible to launch',
    );

    final source = index.readAsStringSync();
    expect(
      source,
      contains('<base href="\$FLUTTER_BASE_HREF">'),
      reason: 'MUTATION: a fixed base URL breaks hosted acceptance builds',
    );
    expect(
      source,
      contains('<script src="flutter_bootstrap.js" async></script>'),
      reason: 'MUTATION: removing Flutter bootstrap leaves a blank web host',
    );

    final metadata = File('.metadata').readAsStringSync();
    expect(
      metadata,
      contains('    - platform: web\n'),
      reason: 'MUTATION: dropping web migration ownership lets Flutter treat '
          'the acceptance host as unmanaged residue',
    );

    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(
      pubspec,
      contains('  cupertino_icons: ^1.0.8\n'),
      reason: 'MUTATION: removing the adaptive icon font brings back the '
          'release-web missing-font warning',
    );
  });
}
