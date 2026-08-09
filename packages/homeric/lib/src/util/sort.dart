/// Internal sorting helpers. Not exported from `homeric.dart`.
library;

/// Returns [items] sorted by [compare], preserving the original order of
/// elements that compare equal (Dart's `List.sort` is not stable).
///
/// Lists shorter than two elements are returned as-is (the same list
/// instance); otherwise a new growable list is returned and [items] is
/// left untouched.
List<T> stableSortedBy<T>(List<T> items, Comparator<T> compare) {
  if (items.length < 2) return items;
  final order = List<int>.generate(items.length, (i) => i)
    ..sort((x, y) {
      final byCompare = compare(items[x], items[y]);
      return byCompare != 0 ? byCompare : x.compareTo(y);
    });
  return <T>[for (final i in order) items[i]];
}
