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

/// Returns a deep-frozen copy of [attributes].
///
/// Every map and list in the result is unmodifiable, and later mutation of
/// the [attributes] argument (or any of its nested containers) cannot affect
/// the returned bag. Values outside the JSON domain cause an
/// [ArgumentError] naming the offending path.
Attributes freezeAttributes(Attributes attributes) {
  if (attributes.isEmpty) return emptyAttributes;
  return _freezeMap(attributes, r'$');
}

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
  return Map<String, Object?>.unmodifiable(frozen);
}

List<Object?> _freezeList(List<Object?> list, String path) {
  final frozen = <Object?>[
    for (var i = 0; i < list.length; i++) _freezeValue(list[i], '$path[$i]'),
  ];
  return List<Object?>.unmodifiable(frozen);
}

Object? _freezeValue(Object? value, String path) {
  return switch (value) {
    null || bool() || int() || double() || String() => value,
    final Map<Object?, Object?> map => _freezeMap(map, path),
    final List<Object?> list => _freezeList(list, path),
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
