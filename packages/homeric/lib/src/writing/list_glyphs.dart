/// What a list item's marker shows, by how deeply it is nested.
///
/// Bullets cycle ● ◯ □ and numbers 1 / a / I with each level, so a nested
/// list reads apart from its parent without indentation alone.
library;

/// List markers by depth.
abstract final class HomericListGlyphs {
  /// Bullets by depth, repeating.
  static const List<String> bullets = <String>['●', '◯', '□'];

  /// The bullet at [depth] (0 is a top-level item).
  static String bullet(int depth) => bullets[depth % bullets.length];

  /// Item number [value] at [depth]: decimal, then lower-case letters,
  /// then roman numerals, repeating.
  static String number(int value, int depth) => switch (depth % 3) {
        1 => latin(value),
        2 => roman(value),
        _ => '$value',
      };

  /// [value] as letters: 1 is a, 26 is z, 27 is aa. Zero and below stay
  /// decimal.
  static String latin(int value) {
    if (value <= 0) return '$value';
    var remaining = value;
    var result = '';
    while (remaining > 0) {
      final remainder = (remaining - 1) % 26;
      result = String.fromCharCode(97 + remainder) + result;
      remaining = (remaining - 1) ~/ 26;
    }
    return result;
  }

  /// [value] in roman numerals, 1 to 3999; others stay decimal.
  static String roman(int value) {
    if (value <= 0 || value > 3999) return '$value';
    var remaining = value;
    final result = StringBuffer();
    for (final part in const <(int, String)>[
      (1000, 'M'),
      (900, 'CM'),
      (500, 'D'),
      (400, 'CD'),
      (100, 'C'),
      (90, 'XC'),
      (50, 'L'),
      (40, 'XL'),
      (10, 'X'),
      (9, 'IX'),
      (5, 'V'),
      (4, 'IV'),
      (1, 'I'),
    ]) {
      while (remaining >= part.$1) {
        result.write(part.$2);
        remaining -= part.$1;
      }
    }
    return result.toString();
  }
}
