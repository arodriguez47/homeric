/// OpenType typography for a writing surface: ligatures, figures, kerning.
///
/// Flutter turns a font's standard ligatures and kerning on by default and
/// everything else off. [HomericTypography] names the choices a writing app
/// makes so every app makes them the same way: an app passes one value to
/// its body and heading styles and gets the same set of features in each.
library;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/painting.dart';

/// How a font's figures are drawn.
enum HomericFigureStyle {
  /// The font's own default.
  fontDefault,

  /// Old-style (text) figures that sit in a line of lowercase like letters.
  oldStyle,

  /// Lining figures, the height of capitals.
  lining,
}

/// The OpenType features a writing surface asks of its fonts.
///
/// Defaults keep what Flutter already does (standard ligatures, contextual
/// alternates and kerning) and add nothing; each flag turns one feature on
/// or off. A feature the font lacks is ignored by the shaper, so the same
/// value is safe for any face.
@immutable
final class HomericTypography {
  /// Creates a typography choice.
  const HomericTypography({
    this.ligatures = true,
    this.contextualAlternates = true,
    this.discretionaryLigatures = false,
    this.kerning = true,
    this.figures = HomericFigureStyle.fontDefault,
    this.tabularFigures = false,
    this.smallCapsHeadings = false,
  });

  /// Standard ligatures (`fi`, `fl`, `ff`): `liga`.
  final bool ligatures;

  /// Contextual alternates and ligatures: `calt` and `clig`.
  final bool contextualAlternates;

  /// Discretionary ligatures (`ct`, `st` in faces that draw them): `dlig`.
  final bool discretionaryLigatures;

  /// Pair kerning: `kern`.
  final bool kerning;

  /// Old-style or lining figures: `onum` / `lnum`.
  final HomericFigureStyle figures;

  /// Figures of one width, for columns of numbers: `tnum`.
  final bool tabularFigures;

  /// Headings set in small capitals where the face has them: `smcp` on
  /// [heading] styles only.
  final bool smallCapsHeadings;

  /// Flutter's own defaults: every flag at its default.
  static const HomericTypography standard = HomericTypography();

  /// The features for running text.
  List<FontFeature> get bodyFeatures => <FontFeature>[
        FontFeature('liga', ligatures ? 1 : 0),
        FontFeature('calt', contextualAlternates ? 1 : 0),
        FontFeature('clig', contextualAlternates ? 1 : 0),
        if (discretionaryLigatures) const FontFeature('dlig'),
        FontFeature('kern', kerning ? 1 : 0),
        if (figures == HomericFigureStyle.oldStyle)
          const FontFeature.oldstyleFigures(),
        if (figures == HomericFigureStyle.lining)
          const FontFeature.liningFigures(),
        if (tabularFigures) const FontFeature.tabularFigures(),
      ];

  /// The features for headings: [bodyFeatures], plus small capitals when
  /// [smallCapsHeadings] is on.
  List<FontFeature> get headingFeatures => <FontFeature>[
        ...bodyFeatures,
        if (smallCapsHeadings) const FontFeature.enable('smcp'),
      ];

  /// [style] with the body features. Features already on [style] that this
  /// value does not name are kept.
  TextStyle body(TextStyle style) => _with(style, bodyFeatures);

  /// [style] with the heading features.
  TextStyle heading(TextStyle style) => _with(style, headingFeatures);

  static TextStyle _with(TextStyle style, List<FontFeature> features) {
    final named = <String>{for (final feature in features) feature.feature};
    return style.copyWith(fontFeatures: <FontFeature>[
      for (final feature in style.fontFeatures ?? const <FontFeature>[])
        if (!named.contains(feature.feature)) feature,
      ...features,
    ]);
  }

  /// A copy with the given fields replaced.
  HomericTypography copyWith({
    bool? ligatures,
    bool? contextualAlternates,
    bool? discretionaryLigatures,
    bool? kerning,
    HomericFigureStyle? figures,
    bool? tabularFigures,
    bool? smallCapsHeadings,
  }) =>
      HomericTypography(
        ligatures: ligatures ?? this.ligatures,
        contextualAlternates: contextualAlternates ?? this.contextualAlternates,
        discretionaryLigatures:
            discretionaryLigatures ?? this.discretionaryLigatures,
        kerning: kerning ?? this.kerning,
        figures: figures ?? this.figures,
        tabularFigures: tabularFigures ?? this.tabularFigures,
        smallCapsHeadings: smallCapsHeadings ?? this.smallCapsHeadings,
      );

  @override
  bool operator ==(Object other) =>
      other is HomericTypography &&
      other.ligatures == ligatures &&
      other.contextualAlternates == contextualAlternates &&
      other.discretionaryLigatures == discretionaryLigatures &&
      other.kerning == kerning &&
      other.figures == figures &&
      other.tabularFigures == tabularFigures &&
      other.smallCapsHeadings == smallCapsHeadings;

  @override
  int get hashCode => Object.hash(
        ligatures,
        contextualAlternates,
        discretionaryLigatures,
        kerning,
        figures,
        tabularFigures,
        smallCapsHeadings,
      );
}
