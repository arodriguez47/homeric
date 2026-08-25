part of 'homeric_paragraph.dart';

/// Bounded owner for shaped paragraphs released by recycled document rows.
///
/// This cache is intentionally separate from the document height index: it
/// never sizes a row, and a miss always falls back to the paragraph's natural
/// engine layout. Entries are keyed by stable block ID and accepted only when
/// every paragraph input and the exact wrap width still match.
///
/// When a [PaintOnlyStyler] is present, a successful take still reshapes in
/// layout (see [RenderHomericParagraph.performLayout]): stylers may read a
/// consumer resolve map cleared and refilled after the cached glyphs were
/// baked, and the cache key cannot observe that side channel.
@internal
final class HomericParagraphLayoutCache {
  /// Creates a bounded cache suitable for one editable document viewport.
  HomericParagraphLayoutCache({
    this.maximumEntries = 2048,
    this.maximumTextCodeUnits = 1000000,
  })  : assert(maximumEntries > 0),
        assert(maximumTextCodeUnits > 0);

  /// Maximum number of detached shaped paragraphs retained.
  final int maximumEntries;

  /// Maximum combined source-text size retained by detached entries.
  final int maximumTextCodeUnits;

  final Map<Object, _CachedHomericParagraph> _entries =
      <Object, _CachedHomericParagraph>{};
  final Set<Object> _retainedKeys = <Object>{};
  int _textCodeUnits = 0;
  bool _disposed = false;

  /// Current detached entry count, exposed for benchmark contracts.
  int get entryCount => _entries.length;

  /// Current detached source-text footprint, in UTF-16 code units.
  int get textCodeUnits => _textCodeUnits;

  _CachedHomericParagraph? _take(
    Object key, {
    required ParagraphSource<TextStyle> source,
    required TextStyle? baseStyle,
    required TextAlign textAlign,
    required TextScaler textScaler,
    required ui.PlaceholderAlignment slotAlignment,
    required TextBaseline? slotBaseline,
    required PaintOnlyStyler? paintStyler,
    required List<PlaceholderDimensions> dimensions,
    required double maxWidth,
  }) {
    if (_disposed || !_retainedKeys.contains(key)) return null;
    final cached = _entries.remove(key);
    if (cached == null) return null;
    _textCodeUnits -= cached.textCodeUnits;
    if (!cached.matches(
      source: source,
      baseStyle: baseStyle,
      textAlign: textAlign,
      textScaler: textScaler,
      slotAlignment: slotAlignment,
      slotBaseline: slotBaseline,
      paintStyler: paintStyler,
      dimensions: dimensions,
      maxWidth: maxWidth,
    )) {
      cached.dispose();
      return null;
    }
    return cached;
  }

  void _release(Object key, _CachedHomericParagraph cached) {
    if (_disposed ||
        !_retainedKeys.contains(key) ||
        cached.textCodeUnits > maximumTextCodeUnits) {
      cached.dispose();
      return;
    }
    final replaced = _entries.remove(key);
    if (replaced != null) {
      _textCodeUnits -= replaced.textCodeUnits;
      replaced.dispose();
    }
    _entries[key] = cached;
    _textCodeUnits += cached.textCodeUnits;
    while (_entries.length > maximumEntries ||
        _textCodeUnits > maximumTextCodeUnits) {
      final oldestKey = _entries.keys.first;
      final oldest = _entries.remove(oldestKey)!;
      _textCodeUnits -= oldest.textCodeUnits;
      oldest.dispose();
    }
  }

  /// Replaces the live key set and disposes detached entries no longer live.
  @internal
  void retainKeys(Set<Object> keys) {
    if (_disposed) return;
    _retainedKeys
      ..clear()
      ..addAll(keys);
    final removedKeys =
        _entries.keys.where((key) => !_retainedKeys.contains(key)).toList();
    for (final key in removedKeys) {
      final removed = _entries.remove(key)!;
      _textCodeUnits -= removed.textCodeUnits;
      removed.dispose();
    }
  }

  /// Drops every detached engine paragraph, for font or viewport teardown.
  void clear() {
    for (final cached in _entries.values) {
      cached.dispose();
    }
    _entries.clear();
    _textCodeUnits = 0;
  }

  /// Permanently releases the cache and every engine paragraph it owns.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _retainedKeys.clear();
    clear();
  }
}

/// Supplies one document-owned paragraph cache and stable block key.
@internal
final class HomericParagraphLayoutCacheScope extends InheritedWidget {
  /// Creates a cache scope around one document block subtree.
  const HomericParagraphLayoutCacheScope({
    super.key,
    required this.cache,
    required this.cacheKey,
    required super.child,
  });

  /// The document-owned bounded cache.
  final HomericParagraphLayoutCache cache;

  /// The stable block identity within [cache].
  final Object cacheKey;

  static HomericParagraphLayoutCacheScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<
          HomericParagraphLayoutCacheScope>();

  @override
  bool updateShouldNotify(HomericParagraphLayoutCacheScope oldWidget) =>
      !identical(cache, oldWidget.cache) || cacheKey != oldWidget.cacheKey;
}

final class _CachedHomericParagraph {
  _CachedHomericParagraph({
    required this.paragraph,
    required this.source,
    required this.baseStyle,
    required this.textAlign,
    required this.textScaler,
    required this.slotAlignment,
    required this.slotBaseline,
    required this.paintStyler,
    required this.dimensions,
    required this.maxWidth,
  });

  final ui.Paragraph paragraph;
  final ParagraphSource<TextStyle> source;
  final TextStyle? baseStyle;
  final TextAlign textAlign;
  final TextScaler textScaler;
  final ui.PlaceholderAlignment slotAlignment;
  final TextBaseline? slotBaseline;
  final PaintOnlyStyler? paintStyler;
  final List<PlaceholderDimensions> dimensions;
  final double maxWidth;

  int get textCodeUnits => source.viewText.length;

  bool matches({
    required ParagraphSource<TextStyle> source,
    required TextStyle? baseStyle,
    required TextAlign textAlign,
    required TextScaler textScaler,
    required ui.PlaceholderAlignment slotAlignment,
    required TextBaseline? slotBaseline,
    required PaintOnlyStyler? paintStyler,
    required List<PlaceholderDimensions> dimensions,
    required double maxWidth,
  }) =>
      this.maxWidth == maxWidth &&
      identical(this.paintStyler, paintStyler) &&
      this.baseStyle == baseStyle &&
      this.textAlign == textAlign &&
      this.textScaler == textScaler &&
      this.slotAlignment == slotAlignment &&
      this.slotBaseline == slotBaseline &&
      listEquals(this.dimensions, dimensions) &&
      RenderHomericParagraph._paragraphSourceEquals(this.source, source);

  void dispose() => paragraph.dispose();
}
