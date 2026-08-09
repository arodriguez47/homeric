// Position-mapping semantics ported from prosemirror-transform src/map.ts
// @ 662b7a937bafde19b7e2a83241dbc8888e257c89; MIT (c) Marijn Haverbeke.
// The upstream source was read to learn the semantics; this implementation
// is original Dart and no source code was copied.

import 'dart:collection';

import 'step_map.dart';

/// The result of mapping a `[from, to)` span through a [Mappable] with
/// [mapSpan]: the raw per-end [MapResult]s plus the normalized (ordered)
/// span.
typedef MappedSpan = ({MapResult from, MapResult to, int start, int end});

/// Maps the span `[from, to)` through [mapping], the start with
/// [assocFrom] and the end with [assocTo].
///
/// This owns only the mechanical double-map: [MappedSpan.start] /
/// [MappedSpan.end] are the two mapped positions in ascending order (an
/// insertion at an exclusive-both zero-length span can invert them). Each
/// call site keeps its own drop/clamp/collapse policy, built from the raw
/// results.
MappedSpan mapSpan(
  Mappable mapping,
  int from,
  int to, {
  int assocFrom = 1,
  int assocTo = -1,
}) {
  final mappedFrom = mapping.mapResult(from, assoc: assocFrom);
  final mappedTo = mapping.mapResult(to, assoc: assocTo);
  final inverted = mappedTo.pos < mappedFrom.pos;
  return (
    from: mappedFrom,
    to: mappedTo,
    start: inverted ? mappedTo.pos : mappedFrom.pos,
    end: inverted ? mappedFrom.pos : mappedTo.pos,
  );
}

/// A pipeline of zero or more [StepMap]s, mapping positions through a
/// sequence of steps.
///
/// Mirror pairs make the pipeline lossless: when a position is deleted by
/// map `i` and a later map `m` is registered as its mirror image (an
/// inverted copy, as produced by rebasing or undo), the position is routed
/// through `m.recover(...)` instead of being snapped, restoring its exact
/// offset.
final class Mapping implements Mappable {
  /// Creates a mapping over [maps], optionally restricted to the index
  /// window [from]..[to]. When [maps] is given it is shared, not copied;
  /// the first mutation copies it (see [appendMap]). [mirror] lists mirror
  /// pairs as flattened index pairs (`[n1, m1, n2, m2, ...]`).
  Mapping([List<StepMap>? maps, List<int>? mirror, this.from = 0, int? to])
      : _maps = maps ?? [],
        _mirror = mirror == null ? null : _mirrorIndexOf(mirror),
        _ownData = maps == null && mirror == null,
        to = to ?? maps?.length ?? 0;

  Mapping._share(this._maps, this._mirror, this.from, this.to)
      : _ownData = false;

  static Map<int, int> _mirrorIndexOf(List<int> pairs) {
    final index = HashMap<int, int>();
    for (var i = 0; i + 1 < pairs.length; i += 2) {
      index[pairs[i]] = pairs[i + 1];
      index[pairs[i + 1]] = pairs[i];
    }
    return index;
  }

  List<StepMap> _maps;

  // Mirror lookup in both directions: `_mirror[n] == m` iff the maps at
  // indices n and m are mirror images of each other.
  Map<int, int>? _mirror;

  // Whether _maps/_mirror are owned by this instance. Slices share the
  // source's data; the first mutation copies it (copy-on-write).
  bool _ownData;

  /// The index of the first map used by [map] and [mapResult].
  int from;

  /// The index past the last map used by [map] and [mapResult].
  int to;

  UnmodifiableListView<StepMap>? _mapsView;

  /// The step maps in this mapping, unmodifiable.
  List<StepMap> get maps => _mapsView ??= UnmodifiableListView(_maps);

  /// Creates a mapping that maps only through maps [from]..[to] of this
  /// one, sharing the underlying data.
  Mapping slice([int from = 0, int? to]) =>
      Mapping._share(_maps, _mirror, from, to ?? _maps.length);

  void _ensureOwnData() {
    if (_ownData) return;
    _maps = List.of(_maps);
    _mapsView = null;
    final mirror = _mirror;
    _mirror = mirror == null ? null : HashMap.of(mirror);
    _ownData = true;
  }

  /// Appends [map] to this mapping. When [mirrors] is given, it is the
  /// index of the earlier map that is the mirror image of this one.
  void appendMap(StepMap map, [int? mirrors]) {
    if (mirrors != null && (mirrors < 0 || mirrors >= _maps.length)) {
      throw ArgumentError.value(
          mirrors, 'mirrors', 'must index an earlier map in this mapping');
    }
    _ensureOwnData();
    _maps.add(map);
    to = _maps.length;
    if (mirrors != null) setMirror(_maps.length - 1, mirrors);
  }

  /// Appends every map in [mapping] to this one, rebasing its mirror pairs.
  void appendMapping(Mapping mapping) {
    final startSize = _maps.length;
    for (var i = 0; i < mapping._maps.length; i++) {
      final mirr = mapping.getMirror(i);
      appendMap(
          mapping._maps[i], mirr != null && mirr < i ? startSize + mirr : null);
    }
  }

  /// Finds the index of the map that mirrors the map at index [n], if any.
  int? getMirror(int n) => _mirror?[n];

  /// Records that the maps at indices [n] and [m] are mirror images.
  void setMirror(int n, int m) {
    _ensureOwnData();
    final mirror = _mirror ??= HashMap<int, int>();
    mirror[n] = m;
    mirror[m] = n;
  }

  /// Appends the inverse of every map in [mapping] to this one, in reverse
  /// order, rebasing its mirror pairs.
  void appendMappingInverted(Mapping mapping) {
    final totalSize = _maps.length + mapping._maps.length;
    for (var i = mapping._maps.length - 1; i >= 0; i--) {
      final mirr = mapping.getMirror(i);
      appendMap(mapping._maps[i].invert(),
          mirr != null && mirr > i ? totalSize - mirr - 1 : null);
    }
  }

  /// Creates an inverted version of this mapping.
  Mapping invert() => Mapping()..appendMappingInverted(this);

  @override
  int map(int pos, {int assoc = 1}) => mapResult(pos, assoc: assoc).pos;

  @override
  MapResult mapResult(int pos, {int assoc = 1}) {
    if (pos < 0) throw PositionRangeError(pos);
    return _map(pos, assoc);
  }

  MapResult _map(int pos, int assoc) {
    var delInfo = 0;
    var mapped = pos;
    for (var i = from; i < to; i++) {
      final result = _maps[i].mapResult(mapped, assoc: assoc);
      final recoverValue = result.recoverValue;
      if (recoverValue != null) {
        final corr = getMirror(i);
        if (corr != null && corr > i && corr < to) {
          // Deleted here, restored by the mirror image: recover the exact
          // offset and resume after the mirror, skipping the maps between.
          mapped = _maps[corr].recover(recoverValue);
          i = corr;
          continue;
        }
      }
      delInfo |= result.delInfo;
      mapped = result.pos;
    }
    return MapResult(mapped, delInfo, null);
  }
}
