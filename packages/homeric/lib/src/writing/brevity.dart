/// A soft cap on length: the note's word count against two marks.
///
/// Brevity never stops typing or trims anything. It counts words as the
/// writer types and says where the text stands: within the first mark,
/// past it (the note is getting long), or past the second (the note is
/// long). The host decides what each stage looks like; for the words past
/// the second mark, [HomericBrevityReading.decorationsFor] gives inline
/// decorations the host styles in its run-style resolver, so the overflow
/// can be set apart in the text itself.
library;

import 'package:flutter/foundation.dart';

import '../decoration/decoration.dart';
import '../editing/editor_controller.dart';
import '../model/block.dart';
import '../model/document.dart';
import 'writing_feature.dart';

/// Where a note stands against its two marks.
enum HomericBrevityStage {
  /// At or under the first mark.
  brief,

  /// Past the first mark, at or under the second.
  long,

  /// Past the second mark.
  overlong,
}

/// Whether the word at block-local `[start, end)` of [block] counts.
typedef HomericWordTest = bool Function(Block block, int start, int end);

/// One count of a document against a feature's marks.
@immutable
final class HomericBrevityReading {
  const HomericBrevityReading._({
    required this.words,
    required this.firstMark,
    required this.secondMark,
    this.pastBlockId,
    this.pastOffset = 0,
    this.laterBlockIds = const <String>{},
  });

  /// An empty document's reading against [firstMark] and [secondMark].
  const HomericBrevityReading.empty({
    required this.firstMark,
    required this.secondMark,
  })  : words = 0,
        pastBlockId = null,
        pastOffset = 0,
        laterBlockIds = const <String>{};

  /// Words counted.
  final int words;

  /// Words the note can have before it reads as getting long.
  final int firstMark;

  /// Words the note can have before it reads as long.
  final int secondMark;

  /// The block holding the first word past [secondMark]; null when within.
  final String? pastBlockId;

  /// Block-local offset where that word starts.
  final int pastOffset;

  /// Blocks after [pastBlockId], all of whose text is past the mark.
  final Set<String> laterBlockIds;

  /// The stage [words] puts the note at.
  HomericBrevityStage get stage => words > secondMark
      ? HomericBrevityStage.overlong
      : words > firstMark
          ? HomericBrevityStage.long
          : HomericBrevityStage.brief;

  /// How far toward [secondMark] the note is, from 0 to 1.
  double get progress =>
      secondMark <= 0 ? 1 : (words / secondMark).clamp(0.0, 1.0);

  /// Inline decorations over [block]'s text past [secondMark], carrying
  /// [spec] for the host's run-style resolver. Empty within the mark.
  Iterable<Decoration> decorationsFor(Block block, {Object? spec}) sync* {
    final length = block.contentLength;
    if (length == 0) return;
    if (block.id == pastBlockId && pastOffset < length) {
      yield Decoration.inline(
        block.id,
        pastOffset,
        length,
        inclusiveEnd: true,
        spec: spec,
      );
    } else if (laterBlockIds.contains(block.id)) {
      yield Decoration.inline(
        block.id,
        0,
        length,
        inclusiveStart: true,
        inclusiveEnd: true,
        spec: spec,
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is HomericBrevityReading &&
      other.words == words &&
      other.firstMark == firstMark &&
      other.secondMark == secondMark &&
      other.pastBlockId == pastBlockId &&
      other.pastOffset == pastOffset &&
      setEquals(other.laterBlockIds, laterBlockIds);

  @override
  int get hashCode => Object.hash(
        words,
        firstMark,
        secondMark,
        pastBlockId,
        pastOffset,
        Object.hashAllUnordered(laterBlockIds),
      );

  @override
  String toString() =>
      'HomericBrevityReading($words words, ${stage.name}, marks $firstMark/'
      '$secondMark)';
}

/// The soft word cap as a [HomericWritingFeature].
///
/// Needs the host's [onReading], so it is not in the standard kit: an app
/// passes it in `with_`, or installs it on its own. [onReading] is called
/// once on install and again whenever an edit changes the reading.
final class HomericBrevity extends HomericWritingFeature {
  /// Creates the feature; [secondMark] must not be under [firstMark].
  const HomericBrevity({
    this.firstMark = 100,
    this.secondMark = 200,
    required this.onReading,
    this.isCounted,
  }) : assert(firstMark >= 0 && secondMark >= firstMark);

  /// Words the note can have before it reads as getting long.
  final int firstMark;

  /// Words the note can have before it reads as long.
  final int secondMark;

  /// Gets each new reading.
  final ValueChanged<HomericBrevityReading> onReading;

  /// Leaves words out of the count (a host's hidden syntax, a link target).
  /// Null counts every word.
  final HomericWordTest? isCounted;

  @override
  String get id => 'brevity';

  @override
  VoidCallback installOn(HomericEditorController controller) {
    var revision = controller.contentRevision;
    var last = read(controller.document);
    onReading(last);
    void onChanged() {
      if (controller.contentRevision == revision) return;
      revision = controller.contentRevision;
      final next = read(controller.document);
      if (next == last) return;
      last = next;
      onReading(next);
    }

    controller.addListener(onChanged);
    return () => controller.removeListener(onChanged);
  }

  /// Counts [document] against the marks. Pure, for hosts that read a note
  /// they are not editing (a card, a preview).
  HomericBrevityReading read(Document document) {
    var words = 0;
    String? pastBlockId;
    var pastOffset = 0;
    final later = <String>{};
    for (final block in document.blocks) {
      if (pastBlockId != null) later.add(block.id);
      for (final match in wordPattern.allMatches(block.text)) {
        if (isCounted?.call(block, match.start, match.end) == false) {
          continue;
        }
        words++;
        if (words == secondMark + 1) {
          pastBlockId = block.id;
          pastOffset = match.start;
        }
      }
    }
    return HomericBrevityReading._(
      words: words,
      firstMark: firstMark,
      secondMark: secondMark,
      pastBlockId: pastBlockId,
      pastOffset: pastOffset,
      laterBlockIds: later,
    );
  }

  /// Words in [text], every word counted.
  static int countWords(String text) => wordPattern.allMatches(text).length;

  /// A word: letters, digits and combining marks, joined by an apostrophe
  /// or hyphen inside it (`don’t`, `well-known` are one word each).
  static final RegExp wordPattern = RegExp(
    r"[\p{L}\p{N}\p{M}]+(?:['’\-][\p{L}\p{N}\p{M}]+)*",
    unicode: true,
  );
}
