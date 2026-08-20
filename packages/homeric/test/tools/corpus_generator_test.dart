import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../../tools/corpus/generate.dart' as corpus;

void main() {
  const expectedHashes = <String, String>{
    'tiny.md': '746ca979',
    'small.md': 'b51c5ba8',
    'medium.md': '1cd79634',
    'large.md': '7a87f8d5',
    'xl.md': '711a96fb',
  };

  test('fixture metadata pins exact word targets and stable seeds', () {
    expect(
      corpus.corpusFixtureSpecs
          .map((spec) => (spec.fileName, spec.targetWords, spec.seed)),
      const [
        ('tiny.md', 1000, 0x00100001),
        ('small.md', 10000, 0x00100002),
        ('medium.md', 50000, 0x00100003),
        ('large.md', 100000, 0x00100004),
        ('xl.md', 500000, 0x00100005),
      ],
    );
  });

  test('two clean generator processes produce byte-identical fixtures',
      () async {
    final first = await Directory.systemTemp.createTemp('homeric-corpus-a-');
    final second = await Directory.systemTemp.createTemp('homeric-corpus-b-');
    addTearDown(() async {
      await first.delete(recursive: true);
      await second.delete(recursive: true);
    });

    Future<void> generateInto(Directory directory) async {
      final result = await Process.run(
        'dart',
        [
          'run',
          '../../tools/corpus/generate.dart',
          '--output-dir',
          directory.path,
        ],
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    }

    await generateInto(first);
    await generateInto(second);

    for (final spec in corpus.corpusFixtureSpecs) {
      final firstBytes =
          await File('${first.path}/${spec.fileName}').readAsBytes();
      final secondBytes =
          await File('${second.path}/${spec.fileName}').readAsBytes();
      expect(secondBytes, firstBytes, reason: spec.fileName);
      expect(
        corpus.fnv1a32Hex(firstBytes),
        expectedHashes[spec.fileName],
        reason: spec.fileName,
      );
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
