/// Optional projected-text spelling boundary for editable Homeric paragraphs.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Locale, WidgetsBinding;

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

/// Spelling from the platform's own checker (UITextChecker on iOS, the
/// spell checker service on Android).
///
/// [isSupported] is false where Flutter has no native spell check service,
/// such as macOS, the web and tests; a host passes no provider there.
final class HomericPlatformSpellCheckProvider
    implements HomericSpellCheckProvider {
  /// Checks text in the locale [locale] returns, read on every request.
  const HomericPlatformSpellCheckProvider({required this.locale});

  /// The writing locale, such as the app's current [Localizations] locale.
  final Locale Function() locale;

  /// Whether this platform has a native spell check service.
  static bool get isSupported =>
      WidgetsBinding.instance.platformDispatcher.nativeSpellCheckServiceDefined;

  @override
  Future<List<SuggestionSpan>> check(HomericSpellCheckRequest request) async {
    if (request.text.trim().isEmpty) return const <SuggestionSpan>[];
    // A fresh service per request: the service merges with its last result,
    // and requests here come from many blocks.
    final results = await DefaultSpellCheckService()
        .fetchSpellCheckSuggestions(locale(), request.text);
    return results ?? const <SuggestionSpan>[];
  }
}
