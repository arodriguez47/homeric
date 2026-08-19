/// Optional projected-text spelling boundary for editable Homeric paragraphs.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Supplies spelling suggestions without coupling Homeric to a platform engine.
abstract interface class HomericSpellCheckProvider {
  /// Checks the exact projected text and content revision in [request].
  Future<List<SuggestionSpan>> check(
    HomericSpellCheckRequest request,
  );
}

/// Immutable input to a [HomericSpellCheckProvider].
@immutable
final class HomericSpellCheckRequest {
  /// Creates a request for one visible paragraph snapshot.
  const HomericSpellCheckRequest({
    required this.blockId,
    required this.text,
    required this.contentRevision,
  });

  /// Stable canonical block id.
  final String blockId;

  /// Projected text visible when this request was created.
  final String text;

  /// Canonical text revision witnessed by this request.
  final int contentRevision;
}
