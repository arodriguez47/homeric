/// Optional low-clutter render hook for mirrored / provenance blocks.
///
/// Core editing stays free of presentation: this helper only emits a
/// [Decoration] when [HomericBlockAttributes.isMirror] is true. Hosts decide
/// whether that becomes a gutter chip, margin note, or nothing.
library;

import '../decoration/decoration.dart';
import '../model/block.dart';
import '../model/block_attributes.dart';

/// Opaque decoration payload identifying a mirror source affordance.
final class HomericMirrorSourceSpec {
  /// Creates a source affordance payload.
  const HomericMirrorSourceSpec({
    required this.sourceId,
    required this.sourceType,
  });

  /// Mirrored source identity.
  final String sourceId;

  /// Mirrored source type.
  final String sourceType;

  @override
  String toString() => 'HomericMirrorSourceSpec($sourceType:$sourceId)';
}

/// Derives a low-clutter mirror affordance decoration for [block], or `null`.
///
/// The decoration is a zero-length [Decoration.widget] at content offset 0 so
/// hosts can mount a small leading indicator without shifting text metrics
/// when they choose not to build a slot.
Decoration? homericMirrorSourceAffordance(
  Block block, {
  Object? spec,
}) {
  if (!HomericBlockAttributes.isMirror(block.attributes)) return null;
  final sourceId = HomericBlockAttributes.sourceIdOf(block.attributes)!;
  final sourceType = HomericBlockAttributes.sourceTypeOf(block.attributes)!;
  return Decoration.widget(
    block.id,
    0,
    spec: spec ??
        HomericMirrorSourceSpec(
          sourceId: sourceId,
          sourceType: sourceType,
        ),
  );
}
