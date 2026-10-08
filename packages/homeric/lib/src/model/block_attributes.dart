/// Documented schema helpers for common block attribute bags.
///
/// Homeric keeps [Block.attributes] opaque and JSON-compatible. These helpers
/// define a small, host-shared vocabulary for mirror / provenance metadata so
/// consumers (sprintnotes, Nexus) do not invent divergent key shapes.
library;

import 'attributes.dart';

/// Canonical keys and builders for mirror / provenance block attributes.
///
/// Schema (nested under the top-level `mirror` key unless using flat helpers):
/// ```json
/// {
///   "mirror": {
///     "sourceId": "note_123",
///     "sourceType": "note"
///   }
/// }
/// ```
final class HomericBlockAttributes {
  HomericBlockAttributes._();

  /// Top-level attribute key for the mirror bag.
  static const String mirrorKey = 'mirror';

  /// Key for the mirrored source identity inside [mirrorKey].
  static const String sourceIdKey = 'sourceId';

  /// Key for the mirrored source type inside [mirrorKey].
  static const String sourceTypeKey = 'sourceType';

  /// Builds a block attribute bag carrying mirror provenance.
  ///
  /// Additional [extra] entries are shallow-merged at the top level (not
  /// inside `mirror`). Existing `mirror` entries in [extra] are overwritten.
  static Attributes mirror({
    required String sourceId,
    required String sourceType,
    Attributes extra = emptyAttributes,
  }) {
    return freezeAttributes(<String, Object?>{
      ...extra,
      mirrorKey: <String, Object?>{
        sourceIdKey: sourceId,
        sourceTypeKey: sourceType,
      },
    });
  }

  /// Reads the mirror bag from [attributes], or `null` when absent / invalid.
  static Attributes? mirrorOf(Attributes attributes) {
    final raw = attributes[mirrorKey];
    if (raw is! Map) return null;
    final bag = <String, Object?>{};
    raw.forEach((key, value) {
      if (key is String) bag[key] = value as Object?;
    });
    return freezeAttributes(bag);
  }

  /// Source id from a mirror bag, or `null` when missing.
  static String? sourceIdOf(Attributes attributes) {
    final mirror = mirrorOf(attributes);
    final value = mirror?[sourceIdKey];
    return value is String ? value : null;
  }

  /// Source type from a mirror bag, or `null` when missing.
  static String? sourceTypeOf(Attributes attributes) {
    final mirror = mirrorOf(attributes);
    final value = mirror?[sourceTypeKey];
    return value is String ? value : null;
  }

  /// Whether [attributes] carries a recognizable mirror bag.
  static bool isMirror(Attributes attributes) =>
      sourceIdOf(attributes) != null && sourceTypeOf(attributes) != null;
}
