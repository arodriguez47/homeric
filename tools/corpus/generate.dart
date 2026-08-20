// Homeric corpus generator.
//
// Produces deterministic Markdown fixtures of N words for benchmarking.
// Run with:
//   dart run tools/corpus/generate.dart
//
// Writes to tools/corpus/out/{tiny,small,medium,large,xl}.md
//
// The text is generated from a fixed lexicon with a deterministic PRNG so
// every developer produces byte-identical fixtures. Block distribution
// approximates a long-form draft.

import 'dart:convert';
import 'dart:io';

/// A benchmark fixture's immutable generation contract.
final class CorpusFixtureSpec {
  const CorpusFixtureSpec(this.fileName, this.targetWords, this.seed);

  final String fileName;
  final int targetWords;
  final int seed;
}

/// Stable fixture names, exact word targets, and version-1 generator seeds.
const corpusFixtureSpecs = <CorpusFixtureSpec>[
  CorpusFixtureSpec('tiny.md', 1000, 0x00100001),
  CorpusFixtureSpec('small.md', 10000, 0x00100002),
  CorpusFixtureSpec('medium.md', 50000, 0x00100003),
  CorpusFixtureSpec('large.md', 100000, 0x00100004),
  CorpusFixtureSpec('xl.md', 500000, 0x00100005),
];

/// Versioned 32-bit generator whose arithmetic is defined in this file.
final class _CorpusPrngV1 {
  _CorpusPrngV1(int seed) : _state = seed & 0xffffffff;

  int _state;

  int nextInt(int upperBound) {
    if (upperBound <= 0) {
      throw ArgumentError.value(upperBound, 'upperBound', 'must be positive');
    }
    _state = (1664525 * _state + 1013904223) & 0xffffffff;
    return _state % upperBound;
  }
}

// A deliberately synthetic lexicon. Changing it changes committed fixture
// hashes and requires an explicit baseline decision.
const _lexicon = [
  'the',
  'and',
  'a',
  'of',
  'to',
  'in',
  'it',
  'is',
  'that',
  'with',
  'on',
  'for',
  'as',
  'by',
  'at',
  'this',
  'an',
  'he',
  'she',
  'they',
  'we',
  'you',
  'I',
  'his',
  'her',
  'their',
  'our',
  'your',
  'my',
  'word',
  'page',
  'note',
  'draft',
  'chapter',
  'section',
  'idea',
  'sentence',
  'paragraph',
  'thought',
  'plot',
  'character',
  'scene',
  'argument',
  'evidence',
  'conclusion',
  'introduction',
  'reference',
  'footnote',
  'comment',
  'annotation',
  'backlink',
  'document',
  'editor',
  'writer',
  'reader',
  'manuscript',
  'narrative',
  'voice',
  'style',
  'rhythm',
  'pace',
  'tension',
  'resolution',
  'theme',
];

String _word(_CorpusPrngV1 rng) => _lexicon[rng.nextInt(_lexicon.length)];

String _sentence(_CorpusPrngV1 rng) {
  final length = 8 + rng.nextInt(18);
  final words = List.generate(length, (_) => _word(rng));
  final s = words.join(' ');
  return '${s[0].toUpperCase()}${s.substring(1)}.';
}

String _paragraph(_CorpusPrngV1 rng) {
  final n = 3 + rng.nextInt(7);
  return List.generate(n, (_) => _sentence(rng)).join(' ');
}

String _heading(_CorpusPrngV1 rng, int level) {
  final words = List.generate(2 + rng.nextInt(4), (_) => _word(rng));
  final h = words.join(' ');
  return '${'#' * level} ${h[0].toUpperCase()}${h.substring(1)}';
}

String _listItem(_CorpusPrngV1 rng) => '- ${_sentence(rng)}';

String _blockquote(_CorpusPrngV1 rng) => '> ${_sentence(rng)}';

int _wordCount(String text) =>
    text.trim().isEmpty ? 0 : text.trim().split(RegExp(r'\s+')).length;

String _tail(_CorpusPrngV1 rng, int words) {
  final values = List.generate(words, (_) => _word(rng));
  if (values.isEmpty) return '';
  final joined = values.join(' ');
  return '${joined[0].toUpperCase()}${joined.substring(1)}.';
}

/// Generates exactly [CorpusFixtureSpec.targetWords] whitespace words.
String generateCorpusFixture(CorpusFixtureSpec spec) {
  final rng = _CorpusPrngV1(spec.seed);
  final blocks = <String>[];
  var written = 0;

  // Top-level title.
  final title = _heading(rng, 1);
  blocks.add(title);
  written += _wordCount(title);

  while (written < spec.targetWords) {
    final roll = rng.nextInt(100);
    String block;
    if (roll < 85) {
      block = _paragraph(rng);
    } else if (roll < 92) {
      final items = 3 + rng.nextInt(4);
      block = List.generate(items, (_) => _listItem(rng)).join('\n');
    } else if (roll < 97) {
      block = _heading(rng, 2 + rng.nextInt(2));
    } else {
      block = _blockquote(rng);
    }
    final blockWords = _wordCount(block);
    final remaining = spec.targetWords - written;
    if (blockWords > remaining) {
      blocks.add(_tail(rng, remaining));
      written += remaining;
    } else {
      blocks.add(block);
      written += blockWords;
    }
  }
  return '${blocks.join('\n\n')}\n';
}

/// FNV-1a over exact bytes, rendered as a lowercase 32-bit hex string.
String fnv1a32Hex(List<int> bytes) {
  const mask = 0xffffffff;
  const prime = 16777619;
  var hash = 2166136261;
  for (final byte in bytes) {
    hash ^= byte;
    hash = (hash * prime) & mask;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

Future<Map<String, String>> writeCorpusFixtures(Directory output) async {
  await output.create(recursive: true);
  final hashes = <String, String>{};
  for (final spec in corpusFixtureSpecs) {
    final bytes = utf8.encode(generateCorpusFixture(spec));
    final file = File('${output.path}/${spec.fileName}');
    await file.writeAsBytes(bytes);
    hashes[spec.fileName] = fnv1a32Hex(bytes);
    stdout.writeln(
      'wrote ${file.path} (${spec.targetWords} words, '
      '${hashes[spec.fileName]})',
    );
  }
  return hashes;
}

Future<void> main(List<String> arguments) async {
  var output = Directory('${Directory.current.path}/tools/corpus/out');
  var writesRepositoryManifest = true;
  for (var i = 0; i < arguments.length; i++) {
    if (arguments[i] == '--output-dir' && i + 1 < arguments.length) {
      output = Directory(arguments[++i]);
      writesRepositoryManifest = false;
      continue;
    }
    stderr.writeln('usage: dart run tools/corpus/generate.dart '
        '[--output-dir <directory>]');
    exitCode = 64;
    return;
  }

  final hashes = await writeCorpusFixtures(output);
  if (writesRepositoryManifest) {
    final manifest = <String, Object?>{
      'generator': 'homeric-corpus-v1-lcg32',
      'fixtures': {
        for (final spec in corpusFixtureSpecs)
          spec.fileName: {
            'words': spec.targetWords,
            'seed': '0x${spec.seed.toRadixString(16).padLeft(8, '0')}',
            'fnv1a32': hashes[spec.fileName],
          },
      },
    };
    const encoder = JsonEncoder.withIndent('  ');
    await File('${Directory.current.path}/tools/corpus/hashes.json')
        .writeAsString('${encoder.convert(manifest)}\n');
  }
}
