/// A soft cap on length: the note's word count against two marks.
///
/// Brevity never stops typing or trims anything. It counts words as the
/// writer types and says where the text stands: within the first mark,
/// past it (the note is getting long), or past the second (the note is
/// long). The host decides what each stage looks like; for the words past
/// the second mark, [HomericBrevityReading.decorationsFor] gives inline
/// decorations the host styles in its run-style resolver, so the overflow
/// can be set apart in the text itself.
///
/// It can count characters instead ([HomericBrevityUnit.characters], for a
/// note bound for a post with a character limit), and can carry a [goal]
/// the note means to reach, so a host can show a target range: at least
/// the goal, at most the second mark.
library;

import 'package:characters/characters.dart';
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

/// What brevity counts.
enum HomericBrevityUnit {
  /// Words, as [HomericBrevity.wordPattern] finds them.
  words,

  /// Characters as a reader sees them (grapheme clusters), spaces and
  /// punctuation included, with one for each line break between blocks.
  characters,
}

/// Whether the word at block-local `[start, end)` of [block] counts.
typedef HomericWordTest = bool Function(Block block, int start, int end);

/// One count of a document against a feature's marks.
@immutable
final class HomericBrevityReading {
  const HomericBrevityReading._({
    required this.count,
    required this.firstMark,
    required this.secondMark,
    this.unit = HomericBrevityUnit.words,
    this.goal,
    this.pastBlockId,
    this.pastOffset = 0,
    this.laterBlockIds = const <String>{},
  });

  /// An empty document's reading against [firstMark] and [secondMark].
  const HomericBrevityReading.empty({
    required this.firstMark,
    required this.secondMark,
    this.unit = HomericBrevityUnit.words,
    this.goal,
  })  : count = 0,
        pastBlockId = null,
        pastOffset = 0,
        laterBlockIds = const <String>{};

  /// Words or characters counted, in [unit].
  final int count;

  /// Words counted; the same as [count], in whichever [unit].
  int get words => count;

  /// What [count] and the marks are in.
  final HomericBrevityUnit unit;

  /// Words (or characters) the note can have before it reads as getting
  /// long.
  final int firstMark;

  /// Words (or characters) the note can have before it reads as long.
  final int secondMark;

  /// What the note means to reach, if anything; under [secondMark].
  final int? goal;

  /// The block holding the first word past [secondMark]; null when within.
  final String? pastBlockId;

  /// Block-local offset where that word starts.
  final int pastOffset;

  /// Blocks after [pastBlockId], all of whose text is past the mark.
  final Set<String> laterBlockIds;

  /// The stage [words] puts the note at.
  HomericBrevityStage get stage => count > secondMark
      ? HomericBrevityStage.overlong
      : count > firstMark
          ? HomericBrevityStage.long
          : HomericBrevityStage.brief;

  /// How far toward [secondMark] the note is, from 0 to 1.
  double get progress =>
      secondMark <= 0 ? 1 : (count / secondMark).clamp(0.0, 1.0);

  /// Whether the note has reached its [goal]; true when there is none.
  bool get reachedGoal => goal == null || count >= goal!;

  /// How far toward [goal] the note is, from 0 to 1; 1 without a goal.
  double get goalProgress {
    final goal = this.goal;
    if (goal == null || goal <= 0) return 1;
    return (count / goal).clamp(0.0, 1.0);
  }

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
      other.count == count &&
      other.unit == unit &&
      other.goal == goal &&
      other.firstMark == firstMark &&
      other.secondMark == secondMark &&
      other.pastBlockId == pastBlockId &&
      other.pastOffset == pastOffset &&
      setEquals(other.laterBlockIds, laterBlockIds);

  @override
  int get hashCode => Object.hash(
        count,
        unit,
        goal,
        firstMark,
        secondMark,
        pastBlockId,
        pastOffset,
        Object.hashAllUnordered(laterBlockIds),
      );

  @override
  String toString() =>
      'HomericBrevityReading($count ${unit.name}, ${stage.name}, marks '
      '$firstMark/$secondMark${goal == null ? '' : ', goal $goal'})';
}

/// The soft word cap as a [HomericWritingFeature].
///
/// Needs the host's [onReading], so it is not in the standard kit: an app
/// passes it in `with_`, or installs it on its own. [onReading] is called
/// once on install and again whenever an edit changes the reading.
final class HomericBrevity extends HomericWritingFeature {
  /// Creates the feature; [secondMark] must not be under [firstMark], nor
  /// [goal] past [secondMark].
  const HomericBrevity({
    this.firstMark = 100,
    this.secondMark = 200,
    this.unit = HomericBrevityUnit.words,
    this.goal,
    required this.onReading,
    this.isCounted,
  }) : assert(
          firstMark >= 0 &&
              secondMark >= firstMark &&
              (goal == null || (goal >= 0 && goal <= secondMark)),
        );

  /// Words (or characters) the note can have before it reads as getting
  /// long.
  final int firstMark;

  /// Words (or characters) the note can have before it reads as long.
  final int secondMark;

  /// Whether the marks count words or characters.
  final HomericBrevityUnit unit;

  /// What the note means to reach, carried on each reading for the host
  /// to show; it changes no stage.
  final int? goal;

  /// Gets each new reading.
  final ValueChanged<HomericBrevityReading> onReading;

  /// Leaves words out of the count (a host's hidden syntax, a link target).
  /// Null counts every word. Counting characters, it is asked of each one.
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
  HomericBrevityReading read(Document document) =>
      unit == HomericBrevityUnit.characters
          ? _readCharacters(document)
          : _readWords(document);

  HomericBrevityReading _readWords(Document document) {
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
      count: words,
      firstMark: firstMark,
      secondMark: secondMark,
      goal: goal,
      pastBlockId: pastBlockId,
      pastOffset: pastOffset,
      laterBlockIds: later,
    );
  }

  HomericBrevityReading _readCharacters(Document document) {
    var count = 0;
    String? pastBlockId;
    var pastOffset = 0;
    final later = <String>{};
    var first = true;
    for (final block in document.blocks) {
      if (pastBlockId != null) {
        later.add(block.id);
        // Still counted, for the number shown.
        if (!first) count++;
        count += _charactersIn(block);
        continue;
      }
      // The line break before this block is a character, and when it is
      // the first one past the mark, the whole block reads past it.
      if (!first) {
        count++;
        if (count == secondMark + 1) {
          pastBlockId = block.id;
          pastOffset = 0;
          count += _charactersIn(block);
          continue;
        }
      }
      first = false;
      var offset = 0;
      for (final character in block.text.characters) {
        final end = offset + character.length;
        if (isCounted?.call(block, offset, end) != false) {
          count++;
          if (count == secondMark + 1) {
            pastBlockId = block.id;
            pastOffset = offset;
          }
        }
        offset = end;
      }
    }
    return HomericBrevityReading._(
      count: count,
      firstMark: firstMark,
      secondMark: secondMark,
      unit: HomericBrevityUnit.characters,
      goal: goal,
      pastBlockId: pastBlockId,
      pastOffset: pastOffset,
      laterBlockIds: later,
    );
  }

  int _charactersIn(Block block) {
    final isCounted = this.isCounted;
    if (isCounted == null) return block.text.characters.length;
    var count = 0;
    var offset = 0;
    for (final character in block.text.characters) {
      final end = offset + character.length;
      if (isCounted(block, offset, end)) count++;
      offset = end;
    }
    return count;
  }

  /// Words in [text], every word counted.
  static int countWords(String text) => wordPattern.allMatches(text).length;

  /// Characters in [text] as a reader sees them, every one counted.
  static int countCharacters(String text) => text.characters.length;

  /// [text] counted in [unit], for a note shown but not being edited.
  static int countIn(String text, HomericBrevityUnit unit) => switch (unit) {
        HomericBrevityUnit.words => countWords(text),
        HomericBrevityUnit.characters => countCharacters(text),
      };

  /// A word: letters, digits and combining marks, joined by an apostrophe
  /// or hyphen inside it (`don’t`, `well-known` are one word each).
  static final RegExp wordPattern = RegExp(
    r"[\p{L}\p{N}\p{M}]+(?:['’\-][\p{L}\p{N}\p{M}]+)*",
    unicode: true,
  );
}
