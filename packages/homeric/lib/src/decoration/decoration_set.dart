/// An immutable collection of [Decoration]s that survives arbitrary edits.
///
/// Design provenance: prosemirror-view's `DecorationSet`
/// (`src/decoration.ts`, https://github.com/ProseMirror/prosemirror-view,
/// MIT; repository archived April 2026) — a document-shadowing tree with
/// node-local offsets, rebuilt only where the document changed. Design
/// reference only — no source code was copied. The flat block model turns
/// the shadowing tree into per-block shards keyed by stable block id,
/// which gives the same "untouched subtrees shared" property.
library;

import '../transform/change_list.dart';
import '../transform/mapping.dart';
import '../util/sort.dart';
import 'decoration.dart';

/// An immutable set of [Decoration]s, sharded by stable block id.
///
/// Every update ([add], [remove], [map]) is persistent-style: only touched
/// shards are rebuilt; every other shard is shared by reference with the
/// previous set. Within a shard, decorations are ordered by `start`, then
/// `end`, then insertion order.
final class DecorationSet {
  const DecorationSet._(this._shards);

  /// The set containing no decorations.
  static const DecorationSet empty =
      DecorationSet._(<String, List<Decoration>>{});

  /// Creates a set holding [decorations].
  factory DecorationSet.of(Iterable<Decoration> decorations) =>
      empty.add(decorations);

  final Map<String, List<Decoration>> _shards;

  /// Whether the set holds no decorations.
  bool get isEmpty => _shards.isEmpty;

  /// Whether the set holds any decoration.
  bool get isNotEmpty => _shards.isNotEmpty;

  /// Total number of decorations.
  int get length {
    var total = 0;
    for (final shard in _shards.values) {
      total += shard.length;
    }
    return total;
  }

  /// The ids of every block carrying at least one decoration.
  Iterable<String> get blockIds => _shards.keys;

  /// Every decoration, grouped by block id (ids in sorted order).
  Iterable<Decoration> get decorations sync* {
    final ids = _shards.keys.toList()..sort();
    for (final id in ids) {
      yield* _shards[id]!;
    }
  }

  /// The decorations anchored to block [blockId], ordered by `start` then
  /// `end`. The returned list is unmodifiable and — for an untouched
  /// shard — reference-identical across [add]/[remove]/[map] calls that
  /// did not affect it.
  List<Decoration> forBlock(String blockId) =>
      _shards[blockId] ?? const <Decoration>[];

  /// Returns a set with [decorations] added. Only the shards of the
  /// blocks involved are rebuilt; every other shard is shared.
  DecorationSet add(Iterable<Decoration> decorations) {
    final grouped = <String, List<Decoration>>{};
    for (final decoration in decorations) {
      (grouped[decoration.blockId] ??= <Decoration>[]).add(decoration);
    }
    if (grouped.isEmpty) return this;
    final next = Map<String, List<Decoration>>.of(_shards);
    grouped.forEach((blockId, added) {
      next[blockId] = _seal(<Decoration>[...?_shards[blockId], ...added]);
    });
    return DecorationSet._(next);
  }

  /// Returns a set with every decoration equal to one of [decorations]
  /// removed (equality per [Decoration.==]: anchor fields plus the same
  /// `spec` instance). Each given decoration removes at most one match.
  /// Returns `this` when nothing matches.
  DecorationSet remove(Iterable<Decoration> decorations) {
    final grouped = <String, List<Decoration>>{};
    for (final decoration in decorations) {
      (grouped[decoration.blockId] ??= <Decoration>[]).add(decoration);
    }
    if (grouped.isEmpty) return this;
    var changed = false;
    final next = Map<String, List<Decoration>>.of(_shards);
    grouped.forEach((blockId, targets) {
      final shard = _shards[blockId];
      if (shard == null) return;
      final pending = List<Decoration>.of(targets);
      final remaining = <Decoration>[];
      for (final decoration in shard) {
        final index = pending.indexOf(decoration);
        if (index >= 0) {
          pending.removeAt(index);
        } else {
          remaining.add(decoration);
        }
      }
      if (remaining.length == shard.length) return;
      changed = true;
      if (remaining.isEmpty) {
        next.remove(blockId);
      } else {
        next[blockId] = List<Decoration>.unmodifiable(remaining);
      }
    });
    if (!changed) return this;
    return DecorationSet._(next);
  }

  /// Maps every decoration through [mapping], re-anchoring across the
  /// blocks [changes] reports as touched.
  ///
  /// StepMaps alone cannot re-localize block-local offsets, so the
  /// [ChangeList] supplies each touched block's old and new global spans:
  /// a decoration's offsets are lifted to global positions with the old
  /// span, mapped, and located in the new spans. That re-keys decorations
  /// across splits (a decoration past the split point follows its text
  /// into the trailing block), joins and cross-block replaces (a removed
  /// trailing block's decorations re-key to the leading id with shifted
  /// offsets), and moves (positions recover through the mirror pair
  /// `moveBlock` registers, **before** the drop rule below — a moved
  /// block's decorations never count as deleted, and its shard carries
  /// over under the preserved block id).
  ///
  /// Pinned semantics:
  ///
  /// - **Drop rule** — a decoration is dropped iff both mapped endpoints
  ///   are `deletedAcross` (after mirror recovery); dropped decorations
  ///   are reported to [onRemoved]. One-sided deletions clamp only the
  ///   affected endpoint, per its inclusivity assoc; deleting exactly the
  ///   decorated range leaves a zero-length survivor.
  /// - **Split spanning** — a decoration spanning a split point stays in
  ///   the leading block with its end clamped to the leading block's
  ///   content length; the part past the split is not re-created in the
  ///   trailing block. An endpoint exactly at the split point goes to the
  ///   leading or trailing side per its inclusivity assoc.
  /// - **Inverted endpoints** — when mapping inverts a range (an
  ///   insertion at an exclusive-both zero-length point), the decoration
  ///   collapses to the earlier of the two mapped positions.
  /// - **Sharing** — shards of untouched blocks are carried by reference
  ///   (`identical` before and after), and a map that changes nothing
  ///   returns `this`. Decorations for block ids the change list does not
  ///   mention (including ids absent from the document) are carried
  ///   unchanged.
  DecorationSet map(
    Mapping mapping,
    ChangeList changes, {
    void Function(Decoration decoration)? onRemoved,
  }) {
    if (_shards.isEmpty || changes.changes.isEmpty) return this;
    // Walk the (tiny) change list rather than every shard; when no touched
    // block carries a shard, nothing is built and `this` is returned.
    _HostTable? hosts;
    // Touched shards whose contents changed: block id -> surviving
    // decorations that stay under that id (possibly empty).
    final rebuilt = <String, List<Decoration>>{};
    final rekeyed = <String, List<Decoration>>{};
    for (final change in changes.changes) {
      final before = change.before;
      if (before == null) continue; // Created by the transaction.
      final shard = _shards[change.blockId];
      if (shard == null) continue;
      hosts ??= _HostTable.of(changes);
      final kept = <Decoration>[];
      var shardChanged = false;
      for (final decoration in shard) {
        final mapped = _mapDecoration(decoration, before, mapping, hosts);
        if (mapped == null) {
          shardChanged = true;
          onRemoved?.call(decoration);
          continue;
        }
        if (mapped.blockId == change.blockId) {
          if (!identical(mapped, decoration)) shardChanged = true;
          kept.add(mapped);
        } else {
          shardChanged = true;
          (rekeyed[mapped.blockId] ??= <Decoration>[]).add(mapped);
        }
      }
      if (shardChanged) rebuilt[change.blockId] = kept;
    }

    if (rebuilt.isEmpty && rekeyed.isEmpty) return this;

    // Untouched shards (and touched-but-unchanged ones) carry over by
    // reference; only touched entries are patched.
    final result = Map<String, List<Decoration>>.of(_shards);
    rekeyed.forEach((blockId, arrivals) {
      final base = rebuilt[blockId];
      if (base != null) {
        base.addAll(arrivals);
      } else {
        rebuilt[blockId] = <Decoration>[...?result[blockId], ...arrivals];
      }
    });
    rebuilt.forEach((blockId, items) {
      if (items.isEmpty) {
        result.remove(blockId);
      } else {
        result[blockId] = _seal(items);
      }
    });
    return DecorationSet._(result);
  }

  /// Maps one decoration; `null` means dropped.
  Decoration? _mapDecoration(
    Decoration decoration,
    BlockSpan before,
    Mapping mapping,
    _HostTable hosts,
  ) {
    final oldStart = before.start + 1 + decoration.start;
    final oldEnd = before.start + 1 + decoration.end;
    final int start;
    final int end;
    if (decoration.kind == DecorationKind.widget) {
      // A zero-length slot maps as a single point; `inclusiveEnd` decides
      // whether an insertion at the slot pushes it after the new content.
      final mapped =
          mapping.mapResult(oldStart, assoc: decoration.inclusiveEnd ? 1 : -1);
      if (mapped.deletedAcross) return null;
      start = mapped.pos;
      end = mapped.pos;
    } else {
      final span = mapSpan(mapping, oldStart, oldEnd,
          assocFrom: decoration.inclusiveStart ? -1 : 1,
          assocTo: decoration.inclusiveEnd ? 1 : -1);
      if (span.from.deletedAcross && span.to.deletedAcross) return null;
      // Policy: an inverted range collapses to the earlier mapped
      // position (`span.to.pos` is that earlier position when inverted).
      start = span.start;
      end = span.to.pos;
    }
    final host = hosts.lookup(start);
    if (host == null) return null;
    var localStart = start - host.start - 1;
    if (localStart < 0) localStart = 0;
    if (localStart > host.contentLength) localStart = host.contentLength;
    int localEnd;
    if (end <= host.end) {
      localEnd = end - host.start - 1;
      if (localEnd > host.contentLength) localEnd = host.contentLength;
    } else {
      // The range continues past the host block (split spanning): clamp
      // to the leading block's content end.
      localEnd = host.contentLength;
    }
    if (localEnd < localStart) localEnd = localStart;
    if (host.id == decoration.blockId &&
        localStart == decoration.start &&
        localEnd == decoration.end) {
      return decoration;
    }
    return decoration.copyWith(
        blockId: host.id, start: localStart, end: localEnd);
  }

  /// Sorts by `start`, then `end`, then original order, into an
  /// unmodifiable list.
  static List<Decoration> _seal(List<Decoration> items) =>
      List<Decoration>.unmodifiable(stableSortedBy(items, (a, b) {
        final byStart = a.start.compareTo(b.start);
        return byStart != 0 ? byStart : a.end.compareTo(b.end);
      }));

  @override
  String toString() =>
      'DecorationSet($length decorations in ${_shards.length} blocks)';
}

/// One touched block's post-transaction geometry.
final class _Host {
  _Host(this.id, this.start, this.end) : contentLength = end - start - 2;

  final String id;
  final int start;
  final int end;
  final int contentLength;
}

/// The touched blocks that still exist after the transaction, ordered by
/// their new global span for binary-search lookup of mapped positions.
final class _HostTable {
  _HostTable.of(ChangeList changes)
      : _hosts = <_Host>[
          for (final change in changes.changes)
            if (change.after case final BlockSpan after)
              _Host(change.blockId, after.start, after.end),
        ]..sort((a, b) => a.start.compareTo(b.start));

  final List<_Host> _hosts;

  /// The host block whose span contains [pos], preferring the block that
  /// starts at [pos] when [pos] sits on a shared boundary. Returns `null`
  /// when [pos] lies outside every touched block.
  _Host? lookup(int pos) {
    var low = 0;
    var high = _hosts.length - 1;
    var found = -1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (_hosts[mid].start <= pos) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    if (found < 0) return null;
    final host = _hosts[found];
    return pos <= host.end ? host : null;
  }
}
