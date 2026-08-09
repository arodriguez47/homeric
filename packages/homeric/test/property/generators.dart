// Seeded, reproducible generators and invariant checks for the Phase 1
// property/fuzz harness (U7).
//
// Every scenario is a pure function of its integer seed: the same seed
// always yields the same document, decorations, anchors, and edit
// sequence. Failures report the seed plus a one-line repro command.
//
// Generators are boundary-biased on purpose — empty blocks and runs,
// collapsed ranges, adjacent decorations, whole-block and zero-length
// replacements, edits at block edges and at the document's start/end.
// The bias is proven by generator self-tests in invariants_test.dart.

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

import '../transform/transform_test_utils.dart';

// ---------------------------------------------------------------------------
// Random primitives
// ---------------------------------------------------------------------------

final class _Rand {
  _Rand(int seed) : _random = Random(seed);

  final Random _random;

  /// Uniform integer in `[0, maxInclusive]`.
  int intTo(int maxInclusive) =>
      maxInclusive <= 0 ? 0 : _random.nextInt(maxInclusive + 1);

  /// Uniform integer in `[min, maxInclusive]`.
  int range(int min, int maxInclusive) => min + intTo(maxInclusive - min);

  /// True with probability [p].
  bool chance(double p) => _random.nextDouble() < p;

  /// Uniform pick from a non-empty list.
  T pick<T>(List<T> items) => items[_random.nextInt(items.length)];
}

const String _textPool = 'abcdefgh ';

String _randomText(_Rand r, int maxLength) {
  final length = r.intTo(maxLength);
  final buffer = StringBuffer();
  for (var i = 0; i < length; i++) {
    buffer.write(_textPool[r.intTo(_textPool.length - 1)]);
  }
  return buffer.toString();
}

/// Boundary-biased offset in `[0, length]`: snaps to 0 or `length` with
/// elevated probability.
int _biasedOffset(_Rand r, int length) {
  if (length == 0) return 0;
  if (r.chance(0.35)) return r.chance(0.5) ? 0 : length;
  return r.intTo(length);
}

/// Boundary-biased document position in `[0, doc.size]`: snaps to the
/// document's start/end and to block edges with elevated probability.
int _biasedDocPosition(_Rand r, Document doc) {
  final size = doc.size;
  if (r.chance(0.15)) return r.chance(0.5) ? 0 : size;
  if (doc.blockCount > 0 && r.chance(0.45)) {
    final index = r.intTo(doc.blockCount - 1);
    final before = doc.positionBeforeBlock(index);
    final after = doc.positionAfterBlock(index);
    return r.pick([before, before + 1, after - 1, after]);
  }
  return r.intTo(size);
}

// ---------------------------------------------------------------------------
// Generated payloads
// ---------------------------------------------------------------------------

/// An opaque spec giving each generated decoration a trackable identity.
final class FuzzSpec {
  FuzzSpec(this.label);

  /// Diagnostic label ('d0', 'd1', ...).
  final String label;

  @override
  String toString() => 'FuzzSpec($label)';
}

/// A Nexus-shaped metadata bag (R2's hosted-untranslated shape).
Attributes _nexusBag(String blockId) => {
      'nexus': {
        'blockId': blockId,
        'schemaVersion': 2,
        'mirror': {
          'mirrorId': 'mirror-$blockId',
          'source': 'daily/2026-08-08.md',
          'capturedAt': '2026-08-08T12:00:00Z',
          'sourceContentHash': 'sha256:0badc0de',
          'sourceSnapshotText': 'snapshot text',
          'groupId': 'group-1',
        },
      },
    };

// ---------------------------------------------------------------------------
// Generator statistics (bias proof)
// ---------------------------------------------------------------------------

/// Counters proving the boundary bias actually occurs; asserted by the
/// generator self-tests.
final class GeneratorStats {
  int emptyBlocks = 0;
  int emptyRuns = 0;
  int nexusBags = 0;
  int collapsedDecorations = 0;
  int adjacentDecorationPairs = 0;
  int wholeBlockReplaces = 0;
  int zeroLengthReplacements = 0;
  int editsAtBlockEdge = 0;
  int editsAtDocStart = 0;
  int editsAtDocEnd = 0;
  int collapsedAnchors = 0;

  /// Uses of each builder, by name.
  final Map<String, int> opCounts = <String, int>{};

  void countOp(String kind) {
    opCounts[kind] = (opCounts[kind] ?? 0) + 1;
  }

  /// Adds [other]'s counters into this one.
  void absorb(GeneratorStats other) {
    emptyBlocks += other.emptyBlocks;
    emptyRuns += other.emptyRuns;
    nexusBags += other.nexusBags;
    collapsedDecorations += other.collapsedDecorations;
    adjacentDecorationPairs += other.adjacentDecorationPairs;
    wholeBlockReplaces += other.wholeBlockReplaces;
    zeroLengthReplacements += other.zeroLengthReplacements;
    editsAtBlockEdge += other.editsAtBlockEdge;
    editsAtDocStart += other.editsAtDocStart;
    editsAtDocEnd += other.editsAtDocEnd;
    collapsedAnchors += other.collapsedAnchors;
    other.opCounts.forEach((kind, count) {
      opCounts[kind] = (opCounts[kind] ?? 0) + count;
    });
  }
}

// ---------------------------------------------------------------------------
// Edit ops (recorded so a scenario can be replayed op-per-transaction)
// ---------------------------------------------------------------------------

/// One recorded builder call with concrete arguments. Replaying the same
/// ops from the same starting document reproduces the same documents.
sealed class EditOp {
  const EditOp();

  /// Applies this op's builder to [tx].
  void applyTo(Transaction tx);
}

final class InsertTextOp extends EditOp {
  const InsertTextOp(this.position, this.text, this.attributes);

  final int position;
  final String text;
  final Attributes attributes;

  @override
  void applyTo(Transaction tx) =>
      tx.insertText(position, text, attributes: attributes);

  @override
  String toString() => "insertText($position, '$text')";
}

final class DeleteRangeOp extends EditOp {
  const DeleteRangeOp(this.from, this.to);

  final int from;
  final int to;

  @override
  void applyTo(Transaction tx) => tx.deleteRange(from, to);

  @override
  String toString() => 'deleteRange($from, $to)';
}

final class SplitBlockOp extends EditOp {
  const SplitBlockOp(this.position, this.trailingBlockId);

  final int position;
  final String trailingBlockId;

  @override
  void applyTo(Transaction tx) =>
      tx.splitBlock(position, trailingBlockId: trailingBlockId);

  @override
  String toString() => "splitBlock($position, '$trailingBlockId')";
}

final class JoinBlocksOp extends EditOp {
  const JoinBlocksOp(this.boundary);

  final int boundary;

  @override
  void applyTo(Transaction tx) => tx.joinBlocks(boundary);

  @override
  String toString() => 'joinBlocks($boundary)';
}

final class MoveBlockOp extends EditOp {
  const MoveBlockOp(this.blockId, this.targetIndex);

  final String blockId;
  final int targetIndex;

  @override
  void applyTo(Transaction tx) => tx.moveBlock(blockId, targetIndex);

  @override
  String toString() => "moveBlock('$blockId', $targetIndex)";
}

final class SetBlockTypeOp extends EditOp {
  const SetBlockTypeOp(this.blockId, this.type);

  final String blockId;
  final String type;

  @override
  void applyTo(Transaction tx) => tx.setBlockType(blockId, type);

  @override
  String toString() => "setBlockType('$blockId', '$type')";
}

final class ToggleMarkOp extends EditOp {
  const ToggleMarkOp(this.from, this.to, this.key, this.value);

  final int from;
  final int to;
  final String key;
  final Object? value;

  @override
  void applyTo(Transaction tx) => tx.toggleMark(from, to, key, value);

  @override
  String toString() => "toggleMark($from, $to, '$key', $value)";
}

// ---------------------------------------------------------------------------
// Scenario generation
// ---------------------------------------------------------------------------

/// A tracked anchor: a position pair plus the text between them at
/// generation time (invariant 6).
final class TrackedAnchor {
  const TrackedAnchor(this.from, this.to, this.text);

  final int from;
  final int to;
  final String text;

  @override
  String toString() => 'anchor[$from, $to)=${Error.safeToString(text)}';
}

/// One fully generated fuzz scenario: a document, decorations, tracked
/// anchors, and an applied edit sequence — all determined by [seed].
final class FuzzScenario {
  FuzzScenario._(this.seed, this.before, this.decorations, this.anchors,
      this.ops, this.tx, this.stats);

  /// Deterministically generates the scenario for [seed] and applies its
  /// edit sequence to [tx].
  factory FuzzScenario.generate(int seed) {
    final r = _Rand(seed);
    final stats = GeneratorStats();

    final blockCount = r.range(1, 6);
    final blocks = <Block>[
      for (var i = 0; i < blockCount; i++) _randomBlock(r, i, stats),
    ];
    final before = Document(blocks);

    var decorationIndex = 0;
    final decorations = <Decoration>[];
    for (final block in before.blocks) {
      decorations.addAll(_randomDecorationsFor(
          r, block, stats, () => 'd${decorationIndex++}'));
    }
    final set = DecorationSet.of(decorations);

    final anchors = <TrackedAnchor>[];
    final anchorCount = r.intTo(3);
    for (var i = 0; i < anchorCount; i++) {
      anchors.add(_randomAnchor(r, before, stats));
    }

    final tx = Transaction(before);
    final ops = <EditOp>[];
    var splitCounter = 0;
    final opCount = r.range(1, 7);
    for (var i = 0; i < opCount; i++) {
      if (tx.doc.isEmpty) break;
      final op = _randomOp(r, tx.doc, stats, () => 'sp${splitCounter++}');
      op.applyTo(tx);
      ops.add(op);
    }

    return FuzzScenario._(seed, before, set, anchors, ops, tx, stats);
  }

  final int seed;
  final Document before;
  final DecorationSet decorations;
  final List<TrackedAnchor> anchors;
  final List<EditOp> ops;
  final Transaction tx;
  final GeneratorStats stats;

  /// Whether the edit sequence contains a block move (which registers a
  /// mirror pair in the mapping).
  bool get hasMoves => ops.any((op) => op is MoveBlockOp);

  /// Replays the recorded ops one per transaction from [before]; the
  /// resulting document chain matches [tx]'s exactly.
  List<Transaction> sequentialTransactions() {
    final transactions = <Transaction>[];
    var doc = before;
    for (final op in ops) {
      final t = Transaction(doc);
      op.applyTo(t);
      transactions.add(t);
      doc = t.doc;
    }
    return transactions;
  }

  /// One-line scenario description for failure messages.
  String describe() =>
      'seed $seed; before=<${dumpDoc(before).replaceAll('\n', ' | ')}>; '
      '${decorations.length} decorations; anchors=$anchors; ops=$ops';
}

Block _randomBlock(_Rand r, int index, GeneratorStats stats) {
  final id = 'b$index';
  final runs = <InlineRun>[];
  if (!r.chance(0.2)) {
    final runCount = r.range(1, 3);
    for (var i = 0; i < runCount; i++) {
      final text = _randomText(r, 5);
      if (text.isEmpty) stats.emptyRuns++;
      final attributes =
          r.chance(0.3) ? <String, Object?>{'bold': true} : emptyAttributes;
      runs.add(InlineRun(text, attributes: attributes));
    }
  }
  Attributes attributes = emptyAttributes;
  if (r.chance(0.35)) {
    attributes = _nexusBag(id);
    stats.nexusBags++;
  }
  final block = Block(
    id: id,
    type: r.pick(const ['paragraph', 'heading']),
    attributes: attributes,
    runs: runs,
  );
  if (block.contentLength == 0) stats.emptyBlocks++;
  return block;
}

List<Decoration> _randomDecorationsFor(
  _Rand r,
  Block block,
  GeneratorStats stats,
  String Function() nextLabel,
) {
  final length = block.contentLength;
  final out = <Decoration>[];

  // Replace decorations: disjoint by construction (paired sorted cuts);
  // adjacent ranges (shared cut) are deliberately possible.
  final replaceCount = r.intTo(2);
  if (replaceCount > 0) {
    final cuts = <int>[
      for (var i = 0; i < replaceCount * 2; i++) _biasedOffset(r, length),
    ]..sort();
    for (var i = 0; i + 1 < cuts.length; i += 2) {
      final start = cuts[i];
      final end = cuts[i + 1];
      final replacementLength = r.chance(0.4) ? 0 : r.range(1, 3);
      if (replacementLength == 0) stats.zeroLengthReplacements++;
      if (start == 0 && end == length) stats.wholeBlockReplaces++;
      out.add(Decoration.replace(
        block.id,
        start,
        end,
        replacementLength: replacementLength,
        inclusiveStart: r.chance(0.5),
        inclusiveEnd: r.chance(0.5),
        spec: ReplacementText('*' * replacementLength),
      ));
      nextLabel(); // keep label sequence aligned across kinds
    }
  }

  // Inline decorations: may overlap anything freely.
  final inlineCount = r.intTo(2);
  for (var i = 0; i < inlineCount; i++) {
    var start = _biasedOffset(r, length);
    var end = _biasedOffset(r, length);
    if (end < start) {
      final swap = start;
      start = end;
      end = swap;
    }
    out.add(Decoration.inline(
      block.id,
      start,
      end,
      inclusiveStart: r.chance(0.5),
      inclusiveEnd: r.chance(0.5),
      spec: FuzzSpec(nextLabel()),
    ));
  }

  // Widget decorations: zero-length placeholder points.
  final widgetCount = r.intTo(2);
  for (var i = 0; i < widgetCount; i++) {
    out.add(Decoration.widget(
      block.id,
      _biasedOffset(r, length),
      inclusiveEnd: r.chance(0.5),
      spec: FuzzSpec(nextLabel()),
    ));
  }

  for (final decoration in out) {
    if (decoration.isCollapsed && decoration.kind != DecorationKind.widget) {
      stats.collapsedDecorations++;
    }
  }
  for (var i = 0; i < out.length; i++) {
    for (var j = i + 1; j < out.length; j++) {
      if (out[i].end == out[j].start || out[j].end == out[i].start) {
        stats.adjacentDecorationPairs++;
      }
    }
  }
  return out;
}

TrackedAnchor _randomAnchor(_Rand r, Document doc, GeneratorStats stats) {
  var from = _biasedDocPosition(r, doc);
  var to = _biasedDocPosition(r, doc);
  if (to < from) {
    final swap = from;
    from = to;
    to = swap;
  }
  if (from == to) stats.collapsedAnchors++;
  return TrackedAnchor(from, to, textBetween(doc, from, to));
}

void _notePositionStats(GeneratorStats stats, Document doc, int position) {
  if (position <= 1) stats.editsAtDocStart++;
  if (position >= doc.size - 1) stats.editsAtDocEnd++;
  final resolved = doc.resolve(position);
  if (resolved is BlockBoundaryPosition) {
    stats.editsAtBlockEdge++;
  } else if (resolved is InlinePosition &&
      (resolved.offset == 0 ||
          resolved.offset == resolved.block.contentLength)) {
    stats.editsAtBlockEdge++;
  }
}

EditOp _randomOp(
  _Rand r,
  Document doc,
  GeneratorStats stats,
  String Function() nextSplitId,
) {
  final kinds = <String>[
    'insertText',
    'insertText',
    'deleteRange',
    'deleteRange',
    'splitBlock',
    'setBlockType',
    'toggleMark',
    if (doc.blockCount >= 2) ...['joinBlocks', 'moveBlock'],
  ];
  final kind = r.pick(kinds);
  stats.countOp(kind);
  switch (kind) {
    case 'insertText':
      final index = r.intTo(doc.blockCount - 1);
      final block = doc.blocks[index];
      final offset = _biasedOffset(r, block.contentLength);
      final position = doc.positionAt(index, offset);
      _notePositionStats(stats, doc, position);
      final attributes =
          r.chance(0.3) ? <String, Object?>{'bold': true} : emptyAttributes;
      return InsertTextOp(position, _randomText(r, 3), attributes);
    case 'deleteRange':
      var from = _biasedDocPosition(r, doc);
      var to = _biasedDocPosition(r, doc);
      if (to < from) {
        final swap = from;
        from = to;
        to = swap;
      }
      _notePositionStats(stats, doc, from);
      _notePositionStats(stats, doc, to);
      return DeleteRangeOp(from, to);
    case 'splitBlock':
      final index = r.intTo(doc.blockCount - 1);
      final block = doc.blocks[index];
      final offset = _biasedOffset(r, block.contentLength);
      final position = doc.positionAt(index, offset);
      _notePositionStats(stats, doc, position);
      return SplitBlockOp(position, nextSplitId());
    case 'joinBlocks':
      final boundary = doc.positionAfterBlock(r.intTo(doc.blockCount - 2));
      _notePositionStats(stats, doc, boundary);
      return JoinBlocksOp(boundary);
    case 'moveBlock':
      final source = r.intTo(doc.blockCount - 1);
      var target = r.intTo(doc.blockCount - 2);
      if (target >= source) target += 1;
      return MoveBlockOp(doc.blocks[source].id, target);
    case 'setBlockType':
      final index = r.intTo(doc.blockCount - 1);
      return SetBlockTypeOp(doc.blocks[index].id,
          r.pick(const ['paragraph', 'heading', 'quote']));
    case 'toggleMark':
      var from = _biasedDocPosition(r, doc);
      var to = _biasedDocPosition(r, doc);
      if (to < from) {
        final swap = from;
        from = to;
        to = swap;
      }
      _notePositionStats(stats, doc, from);
      _notePositionStats(stats, doc, to);
      return ToggleMarkOp(from, to, r.pick(const ['bold', 'em']),
          r.pick(const <Object?>[true, 1, 'x']));
    default:
      throw StateError('unreachable op kind $kind');
  }
}

// ---------------------------------------------------------------------------
// Shared checking utilities
// ---------------------------------------------------------------------------

/// The text of the token range `[from, to)` of [doc]: content characters
/// verbatim, `(` for an opening block token, `)` for a closing one. (The
/// generator's text pool contains no parentheses, so token markers can
/// never collide with content.)
String textBetween(Document doc, int from, int to) {
  if (from < 0 || to > doc.size || to < from) {
    throw ArgumentError('invalid range [$from, $to) for $doc');
  }
  final buffer = StringBuffer();
  for (var i = 0; i < doc.blockCount; i++) {
    final open = doc.positionBeforeBlock(i);
    final block = doc.blocks[i];
    final contentStart = open + 1;
    final close = contentStart + block.contentLength;
    if (close < from) continue;
    if (open >= to) break;
    if (open >= from && open < to) buffer.write('(');
    final low = from > contentStart ? from : contentStart;
    final high = to < close ? to : close;
    if (high > low) {
      buffer
          .write(block.text.substring(low - contentStart, high - contentStart));
    }
    if (close >= from && close < to) buffer.write(')');
  }
  return buffer.toString();
}

/// Drops `replace` decorations that overlap an earlier-kept one, making a
/// mapped shard safe for [deriveViewText] (overlap is a documented
/// consumer bug there; independent mapping of two replace decorations can
/// legitimately produce it). [decorations] must be ordered by start then
/// end, as `DecorationSet.forBlock` returns them.
List<Decoration> viewSafeDecorations(List<Decoration> decorations) {
  final out = <Decoration>[];
  var replaceEnd = -1;
  for (final decoration in decorations) {
    if (decoration.kind == DecorationKind.replace) {
      if (decoration.start < replaceEnd) continue;
      replaceEnd = decoration.end;
    }
    out.add(decoration);
  }
  return out;
}

/// Walks [maps] tracking the range `[from, to]`, and reports whether any
/// step's changed range intersects it. Insertions/deletions exactly at
/// the range's edges do not count as intersecting (they land strictly
/// outside the anchored content) — unless the matching end is closed
/// ([closedFrom]/[closedTo], modeling an inclusive decoration end, which
/// legitimately absorbs an insertion exactly at its boundary).
bool editsIntersectTrackedRange(
  List<StepMap> maps,
  int from,
  int to, {
  int assocFrom = 1,
  int assocTo = -1,
  bool closedFrom = false,
  bool closedTo = false,
}) {
  var f = from;
  var t = to;
  for (final map in maps) {
    var hit = false;
    map.forEach((oldStart, oldEnd, newStart, newEnd) {
      if (oldStart < t && oldEnd > f) hit = true;
      if (closedFrom && oldStart == f && oldEnd == f) hit = true;
      if (closedTo && oldStart == t && oldEnd == t) hit = true;
    });
    if (hit) return true;
    f = map.map(f, assoc: assocFrom);
    t = map.map(t, assoc: assocTo);
    if (t < f) t = f;
  }
  return false;
}

/// Asserts that [composed] equals folding a position through [parts]
/// sequentially, for every position in `[0, oldSize]` and both assocs
/// (invariant 2, position half). Throws [StateError] on the first
/// mismatch.
void checkSequentialCompositionLaw(
  Mappable composed,
  List<Mappable> parts,
  int oldSize,
) {
  for (var pos = 0; pos <= oldSize; pos++) {
    for (final assoc in const [-1, 1]) {
      var sequential = pos;
      for (final part in parts) {
        sequential = part.map(sequential, assoc: assoc);
      }
      final composedPos = composed.map(pos, assoc: assoc);
      if (composedPos != sequential) {
        throw StateError('composition law violated at position $pos '
            '(assoc $assoc): composed -> $composedPos, '
            'sequential -> $sequential');
      }
    }
  }
}

/// Asserts `mapping.invert().map(mapping.map(p)) == p` for every
/// non-deleted position in `[0, oldSize]`, both assocs (invariant 5,
/// mapping half). Throws [StateError] on the first violation.
void checkMappingInvertLaw(Mapping mapping, int oldSize) {
  final inverted = mapping.invert();
  for (var pos = 0; pos <= oldSize; pos++) {
    for (final assoc in const [-1, 1]) {
      final result = mapping.mapResult(pos, assoc: assoc);
      if (result.deleted) continue;
      final back = inverted.map(result.pos, assoc: assoc);
      if (back != pos) {
        throw StateError('invert law violated at position $pos '
            '(assoc $assoc): mapped -> ${result.pos}, back -> $back');
      }
    }
  }
}

// ---------------------------------------------------------------------------
// The six invariants
// ---------------------------------------------------------------------------

/// Invariant 1 — round-trip identity: for every block of [doc], view-text
/// derivation round-trips every position outside replaced spans, and view
/// text equals document text over unreplaced spans.
void checkRoundTripInvariant(Document doc, DecorationSet decorations) {
  for (final block in doc.blocks) {
    final safe = viewSafeDecorations(decorations.forBlock(block.id));
    final derived = deriveViewText(block, safe);
    checkViewMapRoundTrip(derived.viewMap, block.contentLength);
    _checkUnreplacedSpans(block, derived);
  }
}

void _checkUnreplacedSpans(Block block, DerivedViewText derived) {
  final triples = derived.viewMap.triples;
  var docPos = 0;
  var viewPos = 0;
  void compareSpan(int docEnd) {
    final docSpan = block.text.substring(docPos, docEnd);
    final viewSpan =
        derived.viewText.substring(viewPos, viewPos + (docEnd - docPos));
    if (docSpan != viewSpan) {
      throw StateError('view text diverges from document text over the '
          'unreplaced span [$docPos, $docEnd) of block "${block.id}": '
          'doc ${Error.safeToString(docSpan)}, '
          'view ${Error.safeToString(viewSpan)}');
    }
  }

  for (var i = 0; i < triples.length; i += 3) {
    final start = triples[i];
    final oldLength = triples[i + 1];
    final newLength = triples[i + 2];
    compareSpan(start);
    viewPos += (start - docPos) + newLength;
    docPos = start + oldLength;
  }
  compareSpan(block.contentLength);
}

/// The decoration's global token range in [before], with the mapping
/// assocs its inclusivity implies (matching `DecorationSet.map`).
({int start, int end, int assocStart, int assocEnd}) _globalRangeOf(
    Document before, Decoration decoration) {
  final index = before.indexOfBlockId(decoration.blockId)!;
  final start = before.positionAt(index, decoration.start);
  final end = before.positionAt(index, decoration.end);
  if (decoration.kind == DecorationKind.widget) {
    final assoc = decoration.inclusiveEnd ? 1 : -1;
    return (start: start, end: end, assocStart: assoc, assocEnd: assoc);
  }
  return (
    start: start,
    end: end,
    assocStart: decoration.inclusiveStart ? -1 : 1,
    assocEnd: decoration.inclusiveEnd ? 1 : -1,
  );
}

/// Whether step [index] of [tx] re-anchors block structure: a structural
/// replace (split/join) or half of a mirrored pair (a block move).
bool _isStructuralStep(Transaction tx, int index) {
  final step = tx.steps[index];
  if (step is ReplaceStep && step.structure) return true;
  return tx.mapping.getMirror(index) != null;
}

/// Whether [decoration]'s evolving range ever meets one of
/// `DecorationSet.map`'s lossy re-anchor rules, which make its final
/// position depend on map granularity:
///
/// - a structural step (split/join/move) touching the range boundary-
///   inclusively (the pinned split-spanning clamp / re-keying rules),
/// - a deletion strictly overlapping the range (endpoint snapping: the
///   per-call remnant re-anchors with a fresh history, while a one-shot
///   mapping keeps accumulating each original endpoint's deletion info),
/// - an endpoint inversion (the pinned collapse-to-earlier rule).
///
/// Decoration mapping is exactly composable only away from these events —
/// they are deliberately lossy, so where they fire the outcome depends on
/// whether the consumer maps once per transaction or once over a composed
/// mapping. Pinned fuzz counterexamples:
///
/// - seed 20260817: a decoration end exactly on a split point (inclusive
///   end → trailing side) rides into the trailing block, which then moves
///   away; one-shot mapping tears the range across blocks and collapses
///   it, while per-transaction mapping clamps at the split first and
///   keeps it in the leading block.
/// - seed 271828: a decoration spanning a split is clamped mid-sequence
///   by per-transaction mapping, while one-shot mapping of the same
///   endpoints ends up covering exactly the original text after a later
///   re-join — there the one-shot result is the more faithful one.
/// - seed 20260916: an insertion at a collapsed exclusive-both decoration
///   inverts its endpoints; per-transaction mapping collapses (resetting
///   the start), one-shot mapping lets the endpoints travel separately —
///   a later deletion then reaches a different drop decision.
/// - seed 20360861: a deletion snaps a range to a point; the remnant
///   later sits exactly on another deletion's edge and survives, while
///   the one-shot mapping sees both original endpoints deleted across
///   and drops the decoration.
///
/// Neither granularity is uniformly better, and the mid-sequence rules
/// cannot know the future, so exact equality is only guaranteed for
/// untorn decorations; the fuzz invariant asserts precisely that (drop
/// consistency and well-formedness for torn ones stay covered by the
/// conservation and survival checks).
bool _structurallyTorn(FuzzScenario scenario, Decoration decoration) {
  final range = _globalRangeOf(scenario.before, decoration);
  var f = range.start;
  var t = range.end;
  final maps = scenario.tx.mapping.maps;
  for (var i = 0; i < maps.length; i++) {
    final structural = _isStructuralStep(scenario.tx, i);
    var hit = false;
    maps[i].forEach((oldStart, oldEnd, newStart, newEnd) {
      if (structural && oldStart <= t && oldEnd >= f) hit = true;
      if (oldEnd > oldStart && oldStart < t && oldEnd > f) hit = true;
    });
    if (hit) return true;
    f = maps[i].map(f, assoc: range.assocStart);
    t = maps[i].map(t, assoc: range.assocEnd);
    if (t < f) return true; // the collapse rule would fire here
  }
  return false;
}

/// Invariant 2 — map composition: the composed transaction mapping equals
/// sequential per-step/per-transaction mapping, for positions and for
/// decorations (decorations: exactly for every structurally untorn
/// decoration — see [_structurallyTorn]).
void checkMapCompositionInvariant(
    FuzzScenario scenario, DecorationSet composedMapped) {
  final transactions = scenario.sequentialTransactions();
  if (transactions.isNotEmpty &&
      dumpDoc(transactions.last.doc) != dumpDoc(scenario.tx.doc)) {
    throw StateError('sequential replay diverged from the composed '
        'transaction document');
  }
  checkSequentialCompositionLaw(
    scenario.tx.mapping,
    [for (final t in transactions) t.mapping],
    scenario.before.size,
  );
  if (!scenario.hasMoves) {
    // Without mirror pairs, the raw per-step map fold must agree too.
    checkSequentialCompositionLaw(
      scenario.tx.mapping,
      [for (final step in scenario.tx.steps) step.getMap()],
      scenario.before.size,
    );
  }
  var sequential = scenario.decorations;
  for (final t in transactions) {
    sequential = sequential.map(t.mapping, t.changes);
  }
  final torn = Set<Object>.identity();
  for (final decoration in scenario.decorations.decorations) {
    if (_structurallyTorn(scenario, decoration)) torn.add(decoration.spec!);
  }
  _requireSameDecorations(composedMapped, sequential, torn);
}

void _requireSameDecorations(
    DecorationSet composed, DecorationSet other, Set<Object> torn) {
  bool untorn(Decoration d) => !torn.contains(d.spec);
  final a = composed.decorations.where(untorn).toList()
    ..sort(_compareDecorations);
  final b = other.decorations.where(untorn).toList()..sort(_compareDecorations);
  var equal = a.length == b.length;
  if (equal) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        equal = false;
        break;
      }
    }
  }
  if (!equal) {
    throw StateError('decoration sets diverge:\n  composed:   $a\n'
        '  sequential: $b');
  }
}

int _compareDecorations(Decoration a, Decoration b) {
  var c = a.blockId.compareTo(b.blockId);
  if (c != 0) return c;
  c = a.start.compareTo(b.start);
  if (c != 0) return c;
  c = a.end.compareTo(b.end);
  if (c != 0) return c;
  c = a.kind.index.compareTo(b.kind.index);
  if (c != 0) return c;
  return identityHashCode(a.spec).compareTo(identityHashCode(b.spec));
}

/// Invariant 3 — decoration survival: every decoration is accounted for
/// (survivor or reported removal), survivors are well-anchored in the new
/// document, and a survivor whose range no edit intersected still covers
/// exactly its original text.
void checkDecorationSurvivalInvariant(
  FuzzScenario scenario,
  DecorationSet mapped,
  List<Decoration> removed,
) {
  if (mapped.length + removed.length != scenario.decorations.length) {
    throw StateError('decoration conservation violated: '
        '${scenario.decorations.length} in, ${mapped.length} survivors + '
        '${removed.length} removed out');
  }
  final specToOriginal = Map<Object, Decoration>.identity();
  for (final decoration in scenario.decorations.decorations) {
    specToOriginal[decoration.spec!] = decoration;
  }
  final newDoc = scenario.tx.doc;
  for (final survivor in mapped.decorations) {
    final block = newDoc.blockById(survivor.blockId);
    if (block == null) {
      throw StateError('survivor $survivor is anchored to a block missing '
          'from the document');
    }
    if (survivor.start < 0 ||
        survivor.end < survivor.start ||
        survivor.end > block.contentLength) {
      throw StateError('survivor $survivor is out of range for content '
          'length ${block.contentLength}');
    }
    if (survivor.kind == DecorationKind.widget &&
        survivor.start != survivor.end) {
      throw StateError('widget survivor $survivor is no longer collapsed');
    }
    final original = specToOriginal[survivor.spec!]!;
    final beforeBlock = scenario.before.blockById(original.blockId)!;
    final range = _globalRangeOf(scenario.before, original);
    final touched = editsIntersectTrackedRange(
          scenario.tx.mapping.maps,
          range.start,
          range.end,
          assocFrom: range.assocStart,
          assocTo: range.assocEnd,
          closedFrom: original.kind == DecorationKind.widget
              ? original.inclusiveEnd
              : original.inclusiveStart,
          closedTo: original.inclusiveEnd,
        ) ||
        // A lossy re-anchor (split/join/move at the boundary, endpoint
        // inversion) may legitimately change the covered text too — e.g.
        // a collapsed exclusive-both decoration exactly on a split point
        // is torn between the two halves.
        _structurallyTorn(scenario, original);
    if (!touched) {
      final expected = beforeBlock.text.substring(original.start, original.end);
      final actual = block.text.substring(survivor.start, survivor.end);
      if (actual != expected) {
        throw StateError('untouched decoration lost its text: $original '
            'covered ${Error.safeToString(expected)}, survivor $survivor '
            'covers ${Error.safeToString(actual)}');
      }
    }
  }
}

/// Invariant 5 — invert round-trip: applying every step's invert in
/// reverse restores the original document, and the mapping's inverse
/// restores every non-deleted position.
void checkInvertRoundTripInvariant(FuzzScenario scenario) {
  var doc = scenario.tx.doc;
  for (var i = scenario.tx.steps.length - 1; i >= 0; i--) {
    final inverted = scenario.tx.steps[i].invert(scenario.tx.docs[i]);
    final result = inverted.apply(doc);
    if (result.failed) {
      throw StateError('invert of step $i '
          '(${scenario.tx.steps[i]}) failed to apply: ${result.failure}');
    }
    doc = result.doc!;
  }
  if (dumpDoc(doc) != dumpDoc(scenario.before)) {
    throw StateError('applying inverted steps in reverse did not restore '
        'the original document:\n  restored: <${dumpDoc(doc)}>\n'
        '  original: <${dumpDoc(scenario.before)}>');
  }
  checkMappingInvertLaw(scenario.tx.mapping, scenario.before.size);
}

/// Invariant 6 — anchor survival: when every edit landed strictly outside
/// a tracked anchor's range, the text between the mapped positions equals
/// the original anchored text exactly.
void checkAnchorSurvivalInvariant(FuzzScenario scenario) {
  for (final anchor in scenario.anchors) {
    final touched = editsIntersectTrackedRange(
      scenario.tx.mapping.maps,
      anchor.from,
      anchor.to,
    );
    if (touched) continue;
    // A collapsed anchor is a single point: both ends map with one assoc,
    // or an insertion exactly at the point would tear them apart.
    final collapsed = anchor.from == anchor.to;
    final from =
        scenario.tx.mapping.map(anchor.from, assoc: collapsed ? -1 : 1);
    final to = scenario.tx.mapping.map(anchor.to, assoc: -1);
    if (to < from) {
      throw StateError('$anchor mapped to the inverted range [$from, $to)');
    }
    final text = textBetween(scenario.tx.doc, from, to);
    if (text != anchor.text) {
      throw StateError('$anchor no edit intersected it, but its mapped '
          'range [$from, $to) now covers ${Error.safeToString(text)}');
    }
  }
}

/// Runs invariants 1–6 for [scenario] (invariant 4 — boundary behavior —
/// is the generator bias feeding 1–3, proven separately by the generator
/// self-tests). Throws [StateError] on any violation.
void checkAllInvariants(FuzzScenario scenario) {
  final removed = <Decoration>[];
  final mapped = scenario.decorations
      .map(scenario.tx.mapping, scenario.tx.changes, onRemoved: removed.add);
  checkRoundTripInvariant(scenario.before, scenario.decorations);
  checkRoundTripInvariant(scenario.tx.doc, mapped);
  checkMapCompositionInvariant(scenario, mapped);
  checkDecorationSurvivalInvariant(scenario, mapped, removed);
  checkInvertRoundTripInvariant(scenario);
  checkAnchorSurvivalInvariant(scenario);
}

/// Generates the scenario for [seed] and checks all six invariants,
/// failing with the seed and a repro command on any violation.
void runSeed(int seed) {
  final FuzzScenario scenario;
  try {
    scenario = FuzzScenario.generate(seed);
  } catch (error, stackTrace) {
    fail('Scenario generation failed for seed $seed.\n'
        'Repro: HOMERIC_FUZZ_SEED=$seed flutter test '
        'test/property/fuzz_test.dart\n$error\n$stackTrace');
  }
  try {
    checkAllInvariants(scenario);
  } catch (error, stackTrace) {
    fail('Property invariant violated for seed $seed.\n'
        'Repro: HOMERIC_FUZZ_SEED=$seed flutter test '
        'test/property/fuzz_test.dart\n'
        'Scenario: ${scenario.describe()}\n$error\n$stackTrace');
  }
}
