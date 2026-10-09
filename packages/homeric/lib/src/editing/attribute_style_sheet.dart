/// Stock run-attribute → decoration / TextStyle mapping for hosts.
///
/// Homeric persists marks as keys on [InlineRun.attributes], but painting is
/// decoration-driven. This sheet derives [Decoration.inline] overlays from
/// stock keys (`bold` / `italic` / `code` by default) and resolves them to
/// [TextStyle] so hosts do not need playground-specific glue.
library;

import 'package:flutter/painting.dart' hide Decoration;

import '../decoration/decoration.dart';
import '../model/block.dart';
import '../model/inline_run.dart';
import '../render/paragraph_source.dart';

/// Which stock run attribute a [HomericStockAttributeSpec] represents.
enum HomericStockAttributeKind {
  /// `fontWeight: FontWeight.bold`
  bold,

  /// `fontStyle: FontStyle.italic`
  italic,

  /// Monospace / code styling
  code,
}

/// Opaque [Decoration.spec] for stock attribute styles.
final class HomericStockAttributeSpec {
  /// Creates a stock attribute decoration payload.
  const HomericStockAttributeSpec(this.kind);

  /// Shared bold decoration spec (stable identity for deriveDecorations).
  static const bold = HomericStockAttributeSpec(HomericStockAttributeKind.bold);

  /// Shared italic decoration spec.
  static const italic =
      HomericStockAttributeSpec(HomericStockAttributeKind.italic);

  /// Shared code decoration spec.
  static const code = HomericStockAttributeSpec(HomericStockAttributeKind.code);

  /// Which stock attribute this decoration paints.
  final HomericStockAttributeKind kind;

  @override
  String toString() => 'HomericStockAttributeSpec(${kind.name})';
}

/// Maps stock run attributes to decorations and [TextStyle] values.
final class HomericAttributeStyleSheet {
  /// Creates a sheet over the given attribute keys and code presentation.
  const HomericAttributeStyleSheet({
    this.boldKey = 'bold',
    this.italicKey = 'italic',
    this.codeKey = 'code',
    this.codeFontFamily = 'monospace',
    this.codeBackgroundColor,
  });

  /// Default sheet used by hosts that want stock bold/italic/code painting.
  static const HomericAttributeStyleSheet standard =
      HomericAttributeStyleSheet();

  /// Attribute key treated as bold when truthy.
  final String boldKey;

  /// Attribute key treated as italic when truthy.
  final String italicKey;

  /// Attribute key treated as code when truthy.
  final String codeKey;

  /// Font family applied to code runs.
  final String codeFontFamily;

  /// Optional background color for code runs (via decoration background).
  final Color? codeBackgroundColor;

  /// Derives inline decorations covering every run that carries a stock mark.
  ///
  /// Results target [block.id] and are safe to pass through
  /// [HomericEditableParagraph.deriveDecorations] (recomputed, not history).
  List<Decoration> decorationsFor(Block block) {
    final result = <Decoration>[];
    var offset = 0;
    for (final run in block.runs) {
      final end = offset + run.length;
      if (run.length > 0) {
        for (final kind in _kindsFor(run)) {
          result.add(Decoration.inline(
            block.id,
            offset,
            end,
            inclusiveStart: false,
            inclusiveEnd: false,
            spec: _specFor(kind),
          ));
        }
      }
      offset = end;
    }
    return result;
  }

  /// Resolves [run] against [base], merging any active stock attribute specs.
  TextStyle resolveStyle(RunStyleContext run, {required TextStyle base}) {
    var style = base;
    for (final decoration in run.decorations) {
      final spec = decoration.spec;
      if (spec is! HomericStockAttributeSpec) continue;
      style = applyStockAttribute(style, spec.kind);
    }
    return style;
  }

  /// Convenience [RunStyleResolver] bound to [base].
  RunStyleResolver<TextStyle> styleResolver(TextStyle base) =>
      (run) => resolveStyle(run, base: base);

  /// Applies one stock attribute kind onto [style].
  TextStyle applyStockAttribute(
      TextStyle style, HomericStockAttributeKind kind) {
    return switch (kind) {
      HomericStockAttributeKind.bold =>
        style.copyWith(fontWeight: FontWeight.bold),
      HomericStockAttributeKind.italic =>
        style.copyWith(fontStyle: FontStyle.italic),
      HomericStockAttributeKind.code => style.copyWith(
          fontFamily: codeFontFamily,
          backgroundColor: codeBackgroundColor ?? const Color(0x11000000),
        ),
    };
  }

  /// Whether [value] should activate a stock mark (truthy bool / non-empty).
  static bool isTruthyAttribute(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) return value.isNotEmpty && value != 'false';
    return value != null;
  }

  Iterable<HomericStockAttributeKind> _kindsFor(InlineRun run) sync* {
    final attrs = run.attributes;
    if (isTruthyAttribute(attrs[boldKey])) {
      yield HomericStockAttributeKind.bold;
    }
    if (isTruthyAttribute(attrs[italicKey])) {
      yield HomericStockAttributeKind.italic;
    }
    if (isTruthyAttribute(attrs[codeKey])) {
      yield HomericStockAttributeKind.code;
    }
  }

  HomericStockAttributeSpec _specFor(HomericStockAttributeKind kind) {
    return switch (kind) {
      HomericStockAttributeKind.bold => HomericStockAttributeSpec.bold,
      HomericStockAttributeKind.italic => HomericStockAttributeSpec.italic,
      HomericStockAttributeKind.code => HomericStockAttributeSpec.code,
    };
  }
}
