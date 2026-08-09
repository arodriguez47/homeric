/// JSON-compatible attribute bags.
///
/// An attribute bag is a `Map<String, Object?>` restricted to the JSON value
/// domain: `null`, `bool`, `int`, `double`, `String`, `List` of JSON values,
/// and `Map<String, Object?>` of JSON values. Bags are deep-frozen at
/// construction so a bag reference can be shared freely between document
/// versions without defensive copying (structural sharing depends on this).
///
/// Freezing happens exactly once, at the edge where a caller hands a map to
/// the model. After that, edits share the frozen bag by reference; nothing in
/// the model ever deep-copies an attribute bag.
library;

/// A JSON-compatible attribute bag.
typedef Attributes = Map<String, Object?>;

/// The canonical shared empty attribute bag.
const Attributes emptyAttributes = <String, Object?>{};

// Marks containers produced by the freezer so freezing is idempotent:
// passing an already-frozen bag returns the same reference instead of a
// copy. This is what lets edits hand one block's bag to another block (e.g.
// a split's trailing half) and genuinely share it.
final Expando<bool> _frozen = Expando<bool>('frozen attributes');

/// Returns a deep-frozen copy of [attributes].
///
/// Every map and list in the result is unmodifiable, and later mutation of
/// the [attributes] argument (or any of its nested containers) cannot affect
/// the returned bag. Values outside the JSON domain cause an
/// [ArgumentError] naming the offending path.
///
/// Freezing is idempotent: a bag this function previously produced is
/// returned as-is, preserving reference identity (structural sharing).
Attributes freezeAttributes(Attributes attributes) {
  if (attributes.isEmpty) return emptyAttributes;
  if (_frozen[attributes] ?? false) return attributes;
  return _freezeMap(attributes, r'$');
}

/// Returns a deep-frozen copy of a single JSON-compatible attribute [value],
/// with the same validation and idempotence as [freezeAttributes].
Object? freezeAttributeValue(Object? value) => _freezeValue(value, r'$');

Attributes _freezeMap(Map<Object?, Object?> map, String path) {
  final frozen = <String, Object?>{};
  map.forEach((key, value) {
    if (key is! String) {
      throw ArgumentError.value(
        key,
        'attributes',
        'non-String key at $path (attribute maps must have String keys)',
      );
    }
    frozen[key] = _freezeValue(value, '$path.$key');
  });
  final result = Map<String, Object?>.unmodifiable(frozen);
  _frozen[result] = true;
  return result;
}

List<Object?> _freezeList(List<Object?> list, String path) {
  final frozen = <Object?>[
    for (var i = 0; i < list.length; i++) _freezeValue(list[i], '$path[$i]'),
  ];
  final result = List<Object?>.unmodifiable(frozen);
  _frozen[result] = true;
  return result;
}

Object? _freezeValue(Object? value, String path) {
  return switch (value) {
    null || bool() || int() || double() || String() => value,
    final Map<Object?, Object?> map =>
      (_frozen[map] ?? false) ? map : _freezeMap(map, path),
    final List<Object?> list =>
      (_frozen[list] ?? false) ? list : _freezeList(list, path),
    _ => throw ArgumentError.value(
        value,
        'attributes',
        'non-JSON-compatible value of type ${value.runtimeType} at $path',
      ),
  };
}

/// Deep structural equality over JSON-compatible values.
///
/// Maps are equal when they have the same keys mapped to deep-equal values;
/// lists are equal when they have the same length and deep-equal elements in
/// the same order; everything else compares with `==`.
bool attributesEqual(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map<Object?, Object?> && b is Map<Object?, Object?>) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key)) return false;
      if (!attributesEqual(entry.value, b[entry.key])) return false;
    }
    return true;
  }
  if (a is List<Object?> && b is List<Object?>) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!attributesEqual(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
