// Shared helpers for the transform-layer tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/src/transform/run_ops.dart';

/// Builds a block with a single plain run over [text] (or no runs when
/// [text] is empty), unless explicit [runs] are given.
Block para(
  String id,
  String text, {
  String type = 'paragraph',
  Attributes attributes = emptyAttributes,
  List<InlineRun>? runs,
}) {
  return Block(
    id: id,
    type: type,
    attributes: attributes,
    runs: runs ?? [if (text.isNotEmpty) InlineRun(text)],
  );
}

/// A three-block fixture used across the transform tests.
///
/// Layout (PM tokens): `a` "alpha" spans [0, 7), `b` "bravo" spans [7, 14),
/// `c` "charlie" spans [14, 23); document size 23.
Document threeBlocks() => Document([
      para('a', 'alpha', attributes: {
        'nexus': {'blockId': 'a', 'schemaVersion': 1},
      }),
      para('b', 'bravo', type: 'heading', attributes: {'level': 2}),
      para('c', 'charlie'),
    ]);

/// A single-block, open-both slice carrying plain inline [text] — the shape
/// every text insertion uses.
Slice inlineSlice(String text, {Attributes attributes = emptyAttributes}) {
  return Slice(
    [
      Block(id: '', type: '', runs: [
        InlineRun(text, attributes: attributes),
      ]),
    ],
    openStart: true,
    openEnd: true,
  );
}

/// Canonical string for a JSON-compatible value (map keys sorted) so that
/// attribute bags compare structurally.
String canon(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    final parts = keys.map((k) => '$k:${canon(value[k])}');
    return '{${parts.join(',')}}';
  }
  if (value is List) {
    return '[${value.map(canon).join(',')}]';
  }
  if (value is String) return '"$value"';
  return '$value';
}

/// Canonical one-line-per-block dump of a document: id, type, attribute
/// bag, and normalized runs (via the library's own [normalizeRuns], so
/// documents compare by content rather than by run-boundary accidents).
String dumpDoc(Document doc) {
  final lines = <String>[];
  for (final block in doc.blocks) {
    final runs = normalizeRuns(block.runs)
        .map((r) => '${canon(r.text)}@${canon(r.attributes)}')
        .join(' ');
    lines.add('${block.id}|${block.type}|${canon(block.attributes)}|$runs');
  }
  return lines.join('\n');
}

/// Minimal [ReplacementContent] payload shared by the view and property
/// tests.
final class ReplacementText implements ReplacementContent {
  const ReplacementText(this.text);

  @override
  final String text;

  @override
  String toString() => 'ReplacementText(${Error.safeToString(text)})';
}

/// Expects [actual] and [expected] to be the same document up to run
/// normalization: same block ids, types, attribute bags, text, and inline
/// attributes.
void expectSameDoc(Document actual, Document expected, {String? reason}) {
  expect(dumpDoc(actual), dumpDoc(expected), reason: reason);
}

/// Applies [step] to [before], asserts success, then asserts that
/// `step.invert(before)` applied to the result restores [before] exactly.
Document expectInvertRoundTrip(Document before, Step step) {
  final result = step.apply(before);
  expect(result.failed, isFalse,
      reason: 'step should apply cleanly: ${result.failure}');
  final after = result.doc!;
  final inverted = step.invert(before);
  final back = inverted.apply(after);
  expect(back.failed, isFalse,
      reason: 'inverted step should apply cleanly: ${back.failure}');
  expectSameDoc(back.doc!, before,
      reason: 'invert must restore the original document');
  return after;
}
