/// Journal-facing inline markdown: tokenize links and images separately.
///
/// Homeric stores literal source. Hosts call [HomericMarkdownImage.allMatches]
/// and [HomericMarkdownLink.allMatches] before emitting hide / style / widget
/// decorations. Images are `![alt](url)`; links are `[label](url)` that are
/// **not** preceded by `!` — so a host link path cannot eat an image and leave
/// a stray `!` painted as part of a link label.
///
/// Leave-mode for images: emit [HomericMarkdownImage.leavePictureDecorations]
/// and paint [HomericMarkdownImageSlot] from the URL already in the markdown.
/// Homeric does not invent upload, drop, paste, or storage.
library;

import '../decoration/decoration.dart';
import '../decoration/markdown_mark_visibility.dart';

/// One tokenized markdown image: `![alt](url)`.
final class HomericMarkdownImageMatch {
  /// Creates a match over a single `![alt](url)` span.
  const HomericMarkdownImageMatch({
    required this.start,
    required this.end,
    required this.altStart,
    required this.altEnd,
    required this.closeStart,
    required this.alt,
    required this.url,
  });

  /// Inclusive start of `!`.
  final int start;

  /// Exclusive end after the closing `)`.
  final int end;

  /// Inclusive start of the alt text (after `![`).
  final int altStart;

  /// Exclusive end of the alt text (before `]`).
  final int altEnd;

  /// Inclusive start of `](url)`.
  final int closeStart;

  /// Alt text between `[` and `]`.
  final String alt;

  /// Destination URL between `(` and `)`.
  final String url;

  /// Inclusive start of `[` (always [start] + 1).
  int get openBracketStart => start + 1;

  /// Exclusive end of `![` (same as [altStart]).
  int get openBracketEnd => altStart;
}

/// Opaque widget-slot payload for a leave-mode markdown image.
///
/// Hosts put this on a [Decoration.widget] at [HomericMarkdownImageMatch.altStart]
/// (after hiding the chrome and alt) and paint the picture in `slotBuilder`
/// when they have a resolvable [url]. Homeric does not load or store files.
final class HomericMarkdownImageSpec {
  /// Creates an image slot identity for [url] with optional [alt].
  const HomericMarkdownImageSpec({
    required this.url,
    this.alt = '',
  });

  /// Destination from the markdown source.
  final String url;

  /// Alt text from the markdown source.
  final String alt;

  @override
  bool operator ==(Object other) =>
      other is HomericMarkdownImageSpec && other.url == url && other.alt == alt;

  @override
  int get hashCode => Object.hash(url, alt);

  @override
  String toString() => 'HomericMarkdownImageSpec(${Error.safeToString(url)}, '
      'alt: ${Error.safeToString(alt)})';
}

/// Tokenizes inline markdown images.
final class HomericMarkdownImage {
  HomericMarkdownImage._();

  /// `![alt](url)` — alt may be empty; url must be non-empty.
  static final RegExp _pattern = RegExp(r'!\[([^\]]*)\]\(([^)]+)\)');

  /// Every image match in [text], in document order.
  static Iterable<HomericMarkdownImageMatch> allMatches(String text) sync* {
    for (final matched in _pattern.allMatches(text)) {
      final alt = matched.group(1)!;
      final url = matched.group(2)!;
      final start = matched.start;
      final altStart = start + 2; // after `![`
      final altEnd = altStart + alt.length;
      final closeStart = altEnd; // at `]`
      yield HomericMarkdownImageMatch(
        start: start,
        end: matched.end,
        altStart: altStart,
        altEnd: altEnd,
        closeStart: closeStart,
        alt: alt,
        url: url,
      );
    }
  }

  /// Leave-mode decorations for one image: hide `!` `[` alt `](url)`, and
  /// place a widget slot carrying [HomericMarkdownImageSpec] so the host
  /// (or [HomericMarkdownImageSlot]) paints the picture from [match.url].
  static List<Decoration> leavePictureDecorations(
    String blockId,
    HomericMarkdownImageMatch match,
  ) {
    final result = <Decoration>[];

    void hide(int start, int end) {
      if (end > start) {
        result.add(markdownMarkHideReplacement(blockId, start, end));
      }
    }

    hide(match.start, match.openBracketStart); // `!`
    hide(match.openBracketStart, match.openBracketEnd); // `[`
    hide(match.altStart, match.altEnd); // alt — slot replaces it
    hide(match.closeStart, match.end); // `](url)`
    result.add(Decoration.widget(
      blockId,
      match.altStart,
      spec: HomericMarkdownImageSpec(url: match.url, alt: match.alt),
    ));
    return result;
  }
}

/// One tokenized markdown link: `[label](url)` that is not an image.
final class HomericMarkdownLinkMatch {
  /// Creates a match over a single `[label](url)` span.
  const HomericMarkdownLinkMatch({
    required this.start,
    required this.end,
    required this.labelStart,
    required this.labelEnd,
    required this.closeStart,
    required this.label,
    required this.url,
  });

  /// Inclusive start of `[`.
  final int start;

  /// Exclusive end after the closing `)`.
  final int end;

  /// Inclusive start of the label (after `[`).
  final int labelStart;

  /// Exclusive end of the label (before `]`).
  final int labelEnd;

  /// Inclusive start of `](url)`.
  final int closeStart;

  /// Label text between `[` and `]`.
  final String label;

  /// Destination URL between `(` and `)`.
  final String url;
}

/// Tokenizes inline markdown links, skipping images.
final class HomericMarkdownLink {
  HomericMarkdownLink._();

  /// `[label](url)` — label and url must be non-empty.
  static final RegExp _pattern = RegExp(r'\[([^\]]+)\]\(([^)]+)\)');

  /// Every link match in [text] that is not part of an image, in order.
  static Iterable<HomericMarkdownLinkMatch> allMatches(String text) sync* {
    for (final matched in _pattern.allMatches(text)) {
      // Image syntax is `![alt](url)`: the same `[...](...)` shape preceded
      // by `!`. Skip those so the host link path cannot leave a stray `!`.
      if (matched.start > 0 && text.codeUnitAt(matched.start - 1) == 0x21) {
        continue;
      }
      final label = matched.group(1)!;
      final url = matched.group(2)!;
      final start = matched.start;
      final labelStart = start + 1;
      final labelEnd = labelStart + label.length;
      yield HomericMarkdownLinkMatch(
        start: start,
        end: matched.end,
        labelStart: labelStart,
        labelEnd: labelEnd,
        closeStart: labelEnd,
        label: label,
        url: url,
      );
    }
  }
}
