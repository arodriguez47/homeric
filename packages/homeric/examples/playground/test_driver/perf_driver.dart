import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() async {
  final outputPath = Platform.environment['HOMERIC_BENCH_RESULT_PATH'];
  if (outputPath == null || outputPath.isEmpty) {
    stderr.writeln('HOMERIC_BENCH_RESULT_PATH is required.');
    exitCode = 64;
    return;
  }
  await integrationDriver(
    responseDataCallback: (data) async {
      final file = File(outputPath);
      await file.parent.create(recursive: true);
      await file.writeAsString(
          '${const JsonEncoder.withIndent('  ').convert(data)}\n');
    },
    writeResponseOnFailure: true,
  );
}
