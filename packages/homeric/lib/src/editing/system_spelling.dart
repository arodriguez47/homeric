/// Spelling, autocorrect and text replacement from macOS's own checker
/// (NSSpellChecker), asked over the `homeric/spelling` channel the app
/// answers.
///
/// Flutter has no spell check service on macOS, so the app carries a small
/// Swift handler (see `docs/mac-spelling.md`). An app that doesn't answer
/// the channel gets no squiggles and no corrections; nothing else changes.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'spell_check.dart';

/// Words the writer teaches the checker, or tells it to pass over.
///
/// A [HomericSpellCheckProvider] that is also a dictionary gets Learn
/// Spelling and Ignore Spelling in the right-click menu, and every paragraph
/// checks again when [spellingChanges] fires.
abstract interface class HomericSpellingDictionary {
  /// Fires when the words the checker accepts change.
  Listenable get spellingChanges;

  /// Adds [word] to the writer's dictionary, for good.
  Future<void> learnSpelling(String word);

  /// Passes over [word] until the app quits.
  Future<void> ignoreSpelling(String word);
}

/// The system's corrections as the writer types: autocorrect and text
/// replacement, each on only while the system setting is.
abstract interface class HomericTypingCorrections {
  /// Fires when a setting or the replacement list changes.
  Listenable get typingCorrectionsChanged;

  /// Whether misspelled words are corrected as the writer types
  /// ("Correct spelling automatically").
  bool get correctsSpellingAutomatically;

  /// Whether [textReplacements] apply as the writer types.
  bool get replacesTextAutomatically;

  /// The writer's text replacements, shortcut to phrase (`omw` → `On my
  /// way!`).
  Map<String, String> get textReplacements;

  /// What the word at `[start, end)` of [text] is corrected to, or null to
  /// leave it.
  Future<String?> correction(String text, int start, int end);
}

/// macOS spelling: red squiggles, guesses, Learn and Ignore, autocorrect and
/// text replacement, all from NSSpellChecker in the system's own languages.
///
/// One per app: use [instance]. On other platforms [forPlatform] is null and
/// a host keeps whatever it passed before.
final class HomericMacSpelling extends ChangeNotifier
    with WidgetsBindingObserver
    implements
        HomericSpellCheckProvider,
        HomericSpellingDictionary,
        HomericTypingCorrections {
  HomericMacSpelling._(this._channel) {
    _channel.setMethodCallHandler(_handle);
    WidgetsBinding.instance.addObserver(this);
    _refreshSettings();
  }

  /// The channel the app's macOS side answers.
  static const MethodChannel channel = MethodChannel('homeric/spelling');

  static HomericMacSpelling? _instance;

  /// The app's checker, made on first use.
  static HomericMacSpelling get instance =>
      _instance ??= HomericMacSpelling._(channel);

  /// [instance] on macOS; null elsewhere.
  static HomericMacSpelling? get forPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS
          ? instance
          : null;

  /// A checker over [channel], for tests.
  @visibleForTesting
  factory HomericMacSpelling.forTesting(MethodChannel channel) {
    _instance?.dispose();
    return _instance = HomericMacSpelling._(channel);
  }

  final MethodChannel _channel;

  /// False once the app is known not to answer the channel.
  bool? get isAvailable => _available;
  bool? _available;

  bool _correctsSpelling = false;
  bool _replacesText = false;
  Map<String, String> _replacements = const <String, String>{};
  bool _disposed = false;

  @override
  Listenable get spellingChanges => this;

  @override
  Listenable get typingCorrectionsChanged => this;

  @override
  bool get correctsSpellingAutomatically => _correctsSpelling;

  @override
  bool get replacesTextAutomatically => _replacesText;

  @override
  Map<String, String> get textReplacements => _replacements;

  @override
  Future<List<SuggestionSpan>> check(HomericSpellCheckRequest request) async {
    if (_available == false || request.text.trim().isEmpty) {
      return const <SuggestionSpan>[];
    }
    final found = await _invoke<List<Object?>>(
      'check',
      <String, Object>{'text': request.text},
    );
    if (found == null) return const <SuggestionSpan>[];
    final spans = <SuggestionSpan>[];
    for (final entry in found) {
      if (entry is! Map) continue;
      final start = entry['start'];
      final end = entry['end'];
      final guesses = entry['guesses'];
      if (start is! int ||
          end is! int ||
          start < 0 ||
          end <= start ||
          end > request.text.length) {
        continue;
      }
      spans.add(SuggestionSpan(
        TextRange(start: start, end: end),
        <String>[
          if (guesses is List)
            for (final guess in guesses)
              if (guess is String && guess.isNotEmpty) guess,
        ],
      ));
    }
    return spans;
  }

  @override
  Future<void> learnSpelling(String word) async {
    if (word.trim().isEmpty) return;
    await _invoke<void>('learn', <String, Object>{'word': word});
    _changed();
  }

  @override
  Future<void> ignoreSpelling(String word) async {
    if (word.trim().isEmpty) return;
    await _invoke<void>('ignore', <String, Object>{'word': word});
    _changed();
  }

  @override
  Future<String?> correction(String text, int start, int end) async {
    if (_available == false || !_correctsSpelling) return null;
    if (start < 0 || end <= start || end > text.length) return null;
    final corrected = await _invoke<String>(
      'correct',
      <String, Object>{'text': text, 'start': start, 'end': end},
    );
    if (corrected == null ||
        corrected.isEmpty ||
        corrected == text.substring(start, end)) {
      return null;
    }
    return corrected;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The writer may have changed a setting or a replacement in System
    // Settings while the app was in the background.
    if (state == AppLifecycleState.resumed) _refreshSettings();
  }

  Future<Object?> _handle(MethodCall call) async {
    if (call.method == 'settingsChanged') await _refreshSettings();
    return null;
  }

  Future<void> _refreshSettings() async {
    final settings = await _invoke<Map<Object?, Object?>>('settings');
    if (settings == null || _disposed) return;
    final replacements = settings['replacements'];
    _correctsSpelling = settings['autocorrect'] == true;
    _replacesText = settings['replacement'] == true;
    _replacements = Map<String, String>.unmodifiable(<String, String>{
      if (replacements is Map)
        for (final MapEntry(:key, :value) in replacements.entries)
          if (key is String && value is String && key.isNotEmpty) key: value,
    });
    notifyListeners();
  }

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    if (_available == false) return null;
    try {
      final result = await _channel.invokeMethod<T>(method, arguments);
      if (_available != true) _available = true;
      return result;
    } on MissingPluginException {
      _available = false;
      return null;
    } on PlatformException {
      return null;
    }
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _channel.setMethodCallHandler(null);
    if (identical(_instance, this)) _instance = null;
    super.dispose();
  }
}

/// The system's spell checker for this platform: iOS and Android through
/// Flutter's spell check service, macOS through [HomericMacSpelling]; null
/// where there is none (Windows, Linux, the web).
HomericSpellCheckProvider? homericSystemSpellChecker({
  required Locale Function() locale,
}) {
  if (HomericPlatformSpellCheckProvider.isSupported) {
    return HomericPlatformSpellCheckProvider(locale: locale);
  }
  return HomericMacSpelling.forPlatform;
}
