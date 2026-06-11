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

import 'dart:io';
import 'dart:math';

const _targets = <String, int>{
  'tiny.md': 1000,
  'small.md': 10000,
  'medium.md': 50000,
  'large.md': 100000,
  'xl.md': 500000,
};

// A small lexicon. Phase 1 Week 2 will replace this with Project Gutenberg
// public-domain corpora for more realistic line-break behavior.
const _lexicon = [
  'the', 'and', 'a', 'of', 'to', 'in', 'it', 'is', 'that', 'with',
  'on', 'for', 'as', 'by', 'at', 'this', 'an', 'he', 'she', 'they',
  'we', 'you', 'I', 'his', 'her', 'their', 'our', 'your', 'my',
  'word', 'page', 'note', 'draft', 'chapter', 'section', 'idea',
  'sentence', 'paragraph', 'thought', 'plot', 'character', 'scene',
  'argument', 'evidence', 'conclusion', 'introduction', 'reference',
  'footnote', 'comment', 'annotation', 'backlink', 'document',
  'editor', 'writer', 'reader', 'manuscript', 'narrative', 'voice',
  'style', 'rhythm', 'pace', 'tension', 'resolution', 'theme',
];

String _word(Random rng) => _lexicon[rng.nextInt(_lexicon.length)];

String _sentence(Random rng) {
  final length = 8 + rng.nextInt(18);
  final words = List.generate(length, (_) => _word(rng));
  final s = words.join(' ');
  return '${s[0].toUpperCase()}${s.substring(1)}.';
}

String _paragraph(Random rng) {
  final n = 3 + rng.nextInt(7);
  return List.generate(n, (_) => _sentence(rng)).join(' ');
}

String _heading(Random rng, int level) {
  final words = List.generate(2 + rng.nextInt(4), (_) => _word(rng));
  final h = words.join(' ');
  return '${'#' * level} ${h[0].toUpperCase()}${h.substring(1)}';
}

String _listItem(Random rng) => '- ${_sentence(rng)}';

String _blockquote(Random rng) => '> ${_sentence(rng)}';

Future<void> _write(String name, int words) async {
  final rng = Random(0xC0FFEE ^ name.hashCode);
  final buf = StringBuffer();
  var written = 0;

  // Top-level title.
  buf.writeln(_heading(rng, 1));
  buf.writeln();

  while (written < words) {
    final roll = rng.nextDouble();
    String block;
    if (roll < 0.85) {
      block = _paragraph(rng);
    } else if (roll < 0.92) {
      final items = 3 + rng.nextInt(4);
      block = List.generate(items, (_) => _listItem(rng)).join('\n');
    } else if (roll < 0.97) {
      block = _heading(rng, 2 + rng.nextInt(2));
    } else {
      block = _blockquote(rng);
    }
    buf.writeln(block);
    buf.writeln();
    written += block.split(RegExp(r'\s+')).length;
  }

  final outDir = Directory('${Directory.current.path}/tools/corpus/out');
  await outDir.create(recursive: true);
  final file = File('${outDir.path}/$name');
  await file.writeAsString(buf.toString());
  stdout.writeln('wrote ${file.path} (~$written words)');
}

Future<void> main() async {
  for (final entry in _targets.entries) {
    await _write(entry.key, entry.value);
  }
}
