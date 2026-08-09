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
import '../model/position.dart';
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

/// Adds inline attribute [key] = [value] to every character in
/// `[from, to)`.
///
/// Strict: fails where any character in the range already carries [key]
/// (see the library header), which is what makes the inverse — a
/// [RemoveMarkStep] over the same range — exact.
final class AddMarkStep extends Step {
  /// Creates the step; [value] is deep-frozen (invalid values throw here).
  AddMarkStep(this.from, this.to, this.key, Object? value)
      : value = freezeAttributeValue(value) {
    _checkRange(from, to);
  }

  /// Start of the marked range.
  final int from;

  /// End of the marked range.
  final int to;

  /// The inline attribute key.
  final String key;

  /// The inline attribute value (frozen).
  final Object? value;

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
  Step? map(Mappable mapping) =>
      _mapMarkRange(mapping, from, to, (f, t) => AddMarkStep(f, t, key, value));

  @override
  Step? merge(Step other) {
    if (other is AddMarkStep &&
        other.key == key &&
        attributesEqual(other.value, value) &&
        from <= other.to &&
        to >= other.from) {
      return AddMarkStep(from < other.from ? from : other.from,
          to > other.to ? to : other.to, key, value);
    }
    return null;
  }

  @override
  String toString() => 'AddMarkStep($from, $to, $key: $value)';
}

/// Removes inline attribute [key] (whose current value must equal
/// [value]) from every character in `[from, to)`.
///
/// Strict: fails where any character lacks [key] or carries a different
/// value, so the inverse — an [AddMarkStep] with the same value — is
/// exact.
final class RemoveMarkStep extends Step {
  /// Creates the step; [value] is deep-frozen (invalid values throw here).
  RemoveMarkStep(this.from, this.to, this.key, Object? value)
      : value = freezeAttributeValue(value) {
    _checkRange(from, to);
  }

  /// Start of the unmarked range.
  final int from;

  /// End of the unmarked range.
  final int to;

  /// The inline attribute key.
  final String key;

  /// The value the range must currently carry (frozen).
  final Object? value;

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
  Step? map(Mappable mapping) => _mapMarkRange(
      mapping, from, to, (f, t) => RemoveMarkStep(f, t, key, value));

  @override
  Step? merge(Step other) {
    if (other is RemoveMarkStep &&
        other.key == key &&
        attributesEqual(other.value, value) &&
        from <= other.to &&
        to >= other.from) {
      return RemoveMarkStep(from < other.from ? from : other.from,
          to > other.to ? to : other.to, key, value);
    }
    return null;
  }

  @override
  String toString() => 'RemoveMarkStep($from, $to, $key: $value)';
}

void _checkRange(int from, int to) {
  if (from < 0 || to < from) {
    throw ArgumentError('invalid mark range [$from, $to)');
  }
}

/// Maps a mark range through [mapping] the PM way: gone when both ends
/// were deleted or the range collapsed.
Step? _mapMarkRange(
  Mappable mapping,
  int from,
  int to,
  Step Function(int from, int to) build,
) {
  final mappedFrom = mapping.mapResult(from, assoc: 1);
  final mappedTo = mapping.mapResult(to, assoc: -1);
  if ((mappedFrom.deleted && mappedTo.deleted) ||
      mappedFrom.pos >= mappedTo.pos) {
    return null;
  }
  return build(mappedFrom.pos, mappedTo.pos);
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
  if (from == to) return StepResult.ok(doc);
  final rFrom = doc.resolve(from);
  final rTo = doc.resolve(to);
  final firstIndex = rFrom is InlinePosition
      ? rFrom.blockIndex
      : (rFrom as BlockBoundaryPosition).insertionIndex;
  final endIndex = rTo is InlinePosition
      ? rTo.blockIndex + 1
      : (rTo as BlockBoundaryPosition).insertionIndex;
  if (endIndex <= firstIndex) return StepResult.ok(doc);
  final updated = <Block>[];
  var changed = false;
  for (var i = firstIndex; i < endIndex; i++) {
    final block = doc.blocks[i];
    final contentStart = doc.positionBeforeBlock(i) + 1;
    final localStart = from > contentStart ? from - contentStart : 0;
    var localEnd = to - contentStart;
    if (localEnd > block.contentLength) localEnd = block.contentLength;
    if (localEnd <= localStart) {
      updated.add(block);
      continue;
    }
    final runs =
        transformRunsInRange(block.runs, localStart, localEnd, transform);
    if (runs == null) return StepResult.fail(failure);
    updated.add(block.copyWith(runs: normalizeRuns(runs)));
    changed = true;
  }
  if (!changed) return StepResult.ok(doc);
  return StepResult.ok(doc.replaceBlockRange(firstIndex, endIndex, updated));
}
