/// How wide the text column runs: Narrow, Standard, Wide or Full window.
///
/// The measure a writer chooses for prose. Hosts keep the choice, bind
/// keys to [HomericWritingWidth.narrower] and [HomericWritingWidth.wider],
/// and add any margin for sidenotes on top.
library;

/// The writing widths, narrowest first.
enum HomericWritingWidth {
  /// 520 logical pixels, about 60 characters of body text.
  narrow('Narrow', 520),

  /// 640 logical pixels, about 75 characters.
  standard('Standard', 640),

  /// 800 logical pixels.
  wide('Wide', 800),

  /// The whole window.
  full('Full window', double.infinity);

  const HomericWritingWidth(this.label, this.measure);

  /// The name shown in menus.
  final String label;

  /// Widest the text column gets; [double.infinity] fills the window.
  final double measure;

  /// One step narrower, or null at [narrow].
  HomericWritingWidth? get narrower => index == 0 ? null : values[index - 1];

  /// One step wider, or null at [full].
  HomericWritingWidth? get wider =>
      index == values.length - 1 ? null : values[index + 1];
}
