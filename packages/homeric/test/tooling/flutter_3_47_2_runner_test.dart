import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final repositoryRoot = Directory.current.parent.parent;
  final runner = File(
    '${repositoryRoot.path}/scripts/verify_flutter_3_47_2.sh',
  );

  test('Flutter 3.47.2 runner owns a current, self-validating manifest',
      () async {
    expect(
      runner.existsSync(),
      true,
      reason: 'MUTATION: without a checked-in runner the declared minimum '
          'Flutter SDK is verified only by an undocumented manual sequence',
    );

    final result = await Process.run(
      'bash',
      <String>[runner.path, '--check-manifest'],
      workingDirectory: repositoryRoot.path,
    );

    expect(
      result.exitCode,
      0,
      reason: '${result.stdout}\n${result.stderr}',
    );
    expect(result.stdout, contains('package tests: test'));
    expect(result.stdout, contains('playground tests: test'));
    expect(result.stdout, contains('manifest valid'));
  });

  test('Flutter 3.47.2 runner rejects a different SDK before running work',
      () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'homeric-flutter-version-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final fakeFlutter = File('${temporaryDirectory.path}/flutter');
    await fakeFlutter.writeAsString(
      '#!/bin/sh\n'
      "printf '%s\\n' '{\"frameworkVersion\": \"3.25.0\"}'\n",
    );
    final chmod = await Process.run('chmod', <String>['+x', fakeFlutter.path]);
    expect(chmod.exitCode, 0, reason: '${chmod.stdout}\n${chmod.stderr}');

    final result = await Process.run(
      'bash',
      <String>[runner.path, fakeFlutter.path],
      workingDirectory: repositoryRoot.path,
    );

    expect(result.exitCode, 2);
    expect(result.stderr, contains('Expected Flutter 3.47.2'));
  });

  test('GitHub Actions pins Flutter 3.47.2 exactly', () {
    final workflow = File('${repositoryRoot.path}/.github/workflows/ci.yaml');

    expect(workflow.readAsStringSync(), contains("flutter-version: '3.47.2'"));
  });
}
