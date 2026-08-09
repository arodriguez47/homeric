// Attribute/mark step semantics ported from prosemirror-transform
// src/attr_step.ts and src/mark_step.ts
// @ 662b7a937bafde19b7e2a83241dbc8888e257c89; MIT (c) Marijn Haverbeke.
// The upstream source was read to learn the semantics; this implementation
// is original Dart and no source code was copied.
//
// Deliberate deviation from PM: mark steps are strict. AddMarkStep fails
// where the key is already present, and RemoveMarkStep fails where the
// current value differs — so every mark step inverts losslessly at the
// step level (PM instead relies on its Transform helpers to split ranges,
// and its raw steps can lose pre-existing marks on invert). Builders slice
// ranges into uniform segments before emitting steps.

import '../model/attributes.dart';
import '../model/block.dart';
import '../model/document.dart';
import '../model/inline_run.dart';
import 'mapping.dart';
import 'run_ops.dart';
import 'step.dart';
import 'step_map.dart';

/// Sets a block's type and/or replaces its attribute bag, keyed by stable
/// block id.
///
/// A `null` field means "leave unchanged". Because the key is the stable
/// id, position mapping never affects this step; it fails as a value when
/// the block no longer exists.
final class BlockAttrStep extends Step {
  /// Creates the step. [attributes], when given, is deep-frozen here so
  /// invalid values fail at construction, not at apply time.
  BlockAttrStep(this.blockId, {this.type, Attributes? attributes})
      : attributes = attributes == null ? null : freezeAttributes(attributes);

  /// The stable id of the block to change.
  final String blockId;

  /// The new block type, or `null` to keep the current one.
  final String? type;

  /// The new attribute bag, or `null` to keep the current one.
  final Attributes? attributes;

  @override
  StepResult apply(Document doc) {
    final index = doc.indexOfBlockId(blockId);
    if (index == null) {
      return StepResult.fail('no block with id "$blockId"');
    }
    final block = doc.blocks[index];
    return StepResult.ok(doc.updateBlock(
        index, block.copyWith(type: type, attributes: attributes)));
  }

  @override
  Step invert(Document docBefore) {
    final block = docBefore.blockById(blockId);
    if (block == null) {
      throw StateError('cannot invert BlockAttrStep: block "$blockId" is '
          'not in the given document');
    }
    return BlockAttrStep(
      blockId,
      type: type == null ? null : block.type,
      attributes: attributes == null ? null : block.attributes,
    );
  }

  @override
  Step? map(Mappable mapping) => this;

  @override
  Step? merge(Step other) {
    if (other is! BlockAttrStep || other.blockId != blockId) return null;
    return BlockAttrStep(
      blockId,
      type: other.type ?? type,
      attributes: other.attributes ?? attributes,
    );
  }

  @override
  String toString() => 'BlockAttrStep($blockId, type: $type, '
      'attributes: $attributes)';
}

/// Shared shape of [AddMarkStep] and [RemoveMarkStep]: a `[from, to)`
/// range plus one inline attribute key/value, with common range checking,
/// mapping, and same-kind range merging. Subclasses supply the run
/// transform (via [apply]) and the inverse.
sealed class _MarkStepBase extends Step {
  _MarkStepBase(this.from, this.to, this.key, Object? value)
      : value = freezeAttributeValue(value) {
    if (from < 0 || to < from) {
      throw ArgumentError('invalid mark range [$from, $to)');
    }
  }

  /// Start of the affected range.
  final int from;

  /// End of the affected range.
  final int to;

  /// The inline attribute key.
  final String key;

  /// The inline attribute value (frozen).
  final Object? value;

  /// Creates a step of this kind over a different range.
  Step _withRange(int from, int to);

  /// Maps the range through [mapping] the PM way: gone when both ends were
  /// deleted or the range collapsed.
  @override
  Step? map(Mappable mapping) {
    final span = mapSpan(mapping, from, to);
    if ((span.from.deleted && span.to.deleted) ||
        span.from.pos >= span.to.pos) {
      return null;
    }
    return _withRange(span.from.pos, span.to.pos);
  }

  /// Merges two overlapping/adjacent steps of the same kind, key, and
  /// value into one covering their union.
  @override
  Step? merge(Step other) {
    if (other.runtimeType == runtimeType &&
        other is _MarkStepBase &&
        other.key == key &&
        attributesEqual(other.value, value) &&
        from <= other.to &&
        to >= other.from) {
      return _withRange(
          from < other.from ? from : other.from, to > other.to ? to : other.to);
    }
    return null;
  }
}

/// Adds inline attribute [key] = [value] to every character in
/// `[from, to)`.
///
/// Strict: fails where any character in the range already carries [key]
/// (see the library header), which is what makes the inverse — a
/// [RemoveMarkStep] over the same range — exact.
final class AddMarkStep extends _MarkStepBase {
  /// Creates the step; [value] is deep-frozen (invalid values throw here).
  AddMarkStep(super.from, super.to, super.key, super.value);

  @override
  StepResult apply(Document doc) {
    return _transformMarks(doc, from, to, (portion) {
      if (portion.attributes.containsKey(key)) return null;
      return portion.copyWith(attributes: {...portion.attributes, key: value});
    }, 'mark "$key" is already present inside [$from, $to)');
  }

  @override
  Step invert(Document docBefore) => RemoveMarkStep(from, to, key, value);

  @override
  Step _withRange(int from, int to) => AddMarkStep(from, to, key, value);

  @override
  String toString() => 'AddMarkStep($from, $to, $key: $value)';
}

/// Removes inline attribute [key] (whose current value must equal
/// [value]) from every character in `[from, to)`.
///
/// Strict: fails where any character lacks [key] or carries a different
/// value, so the inverse — an [AddMarkStep] with the same value — is
/// exact.
final class RemoveMarkStep extends _MarkStepBase {
  /// Creates the step; [value] is deep-frozen (invalid values throw here).
  RemoveMarkStep(super.from, super.to, super.key, super.value);

  @override
  StepResult apply(Document doc) {
    return _transformMarks(doc, from, to, (portion) {
      if (!portion.attributes.containsKey(key) ||
          !attributesEqual(portion.attributes[key], value)) {
        return null;
      }
      final next = {...portion.attributes}..remove(key);
      return portion.copyWith(attributes: next);
    },
        'mark "$key" with the expected value is not present across '
        '[$from, $to)');
  }

  @override
  Step invert(Document docBefore) => AddMarkStep(from, to, key, value);

  @override
  Step _withRange(int from, int to) => RemoveMarkStep(from, to, key, value);

  @override
  String toString() => 'RemoveMarkStep($from, $to, $key: $value)';
}

/// Applies [transform] to every run portion inside `[from, to)`, block by
/// block; block open/close tokens carry no marks and are skipped. Returns
/// a failed result with [failure] when [transform] rejects a portion.
StepResult _transformMarks(
  Document doc,
  int from,
  int to,
  InlineRun? Function(InlineRun portion) transform,
  String failure,
) {
  if (to > doc.size) {
    return StepResult.fail(
        'mark range [$from, $to) exceeds document size ${doc.size}');
  }
  var rejected = false;
  final updated = <int, Block>{};
  visitContentRanges(doc, from, to, (blockIndex, localStart, localEnd) {
    if (rejected) return;
    final block = doc.blocks[blockIndex];
    final runs =
        transformRunsInRange(block.runs, localStart, localEnd, transform);
    if (runs == null) {
      rejected = true;
      return;
    }
    updated[blockIndex] = block.copyWith(runs: normalizeRuns(runs));
  });
  if (rejected) return StepResult.fail(failure);
  if (updated.isEmpty) return StepResult.ok(doc);
  final first = updated.keys.first;
  final last = updated.keys.last;
  return StepResult.ok(doc.replaceBlockRange(first, last + 1, [
    for (var i = first; i <= last; i++) updated[i] ?? doc.blocks[i],
  ]));
}
