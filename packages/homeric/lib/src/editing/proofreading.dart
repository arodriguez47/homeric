/// Optional grammar and style proofreading for editable Homeric paragraphs.
///
/// Spelling has its own slot ([HomericSpellCheckProvider]); proofreading is
/// the layer above it: wrong words, agreement, repeated words, wordy
/// phrases and the writer's own phrase rules. A paragraph asks its
/// [HomericProofreader] only once the caret has left it, so nothing is
/// checked while the writer is typing there, and the marks it paints stay
/// off the paragraph being written.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show TextRange;

import 'spell_check.dart';

/// How a finding is drawn: a correction, or a nudge.
enum HomericProofingMark {
  /// Something reads as wrong: a dotted underline.
  grammar,

  /// Something could read better: a soft wash.
  style,
}

/// The groups a writer switches on and off.
enum HomericProofingGroup {
  /// Agreement, wrong words (their / they're), a / an, word choice.
  grammar(HomericProofingMark.grammar),

  /// Repeated words, punctuation, spacing.
  repetitionAndPunctuation(HomericProofingMark.grammar),

  /// Wordy and redundant phrases.
  wordiness(HomericProofingMark.style),

  /// Sentences long enough to lose a reader.
  longSentences(HomericProofingMark.style),

  /// The writer's own phrase rules.
  yourRules(HomericProofingMark.style);

  const HomericProofingGroup(this.mark);

  /// How findings in this group are drawn.
  final HomericProofingMark mark;
}

/// One finding in a paragraph's projected text.
@immutable
final class HomericProofingIssue {
  const HomericProofingIssue({
    required this.range,
    required this.group,
    required this.ruleId,
    required this.message,
    this.replacements = const <String>[],
  });

  /// `[start, end)` in the request's text.
  final TextRange range;

  /// The group the rule belongs to, and so how it is drawn.
  final HomericProofingGroup group;

  /// A stable id for the rule (`RepeatedWords`, `phrase:in order to`).
  final String ruleId;

  /// One plain sentence on what is wrong or could be better.
  final String message;

  /// Replacements for the whole range, best first. Empty when the rule only
  /// flags the words.
  final List<String> replacements;

  /// How the finding is drawn.
  HomericProofingMark get mark => group.mark;

  HomericProofingIssue shifted(int by) => HomericProofingIssue(
        range: TextRange(start: range.start + by, end: range.end + by),
        group: group,
        ruleId: ruleId,
        message: message,
        replacements: replacements,
      );

  @override
  bool operator ==(Object other) =>
      other is HomericProofingIssue &&
      other.range == range &&
      other.group == group &&
      other.ruleId == ruleId &&
      other.message == message &&
      listEquals(other.replacements, replacements);

  @override
  int get hashCode => Object.hash(
        range,
        group,
        ruleId,
        message,
        Object.hashAll(replacements),
      );

  @override
  String toString() =>
      'HomericProofingIssue($ruleId ${range.start}-${range.end}: $message)';
}

/// A second action a menu offers for a finding, after the fix and Ignore:
/// "Turn off this rule", "Edit rule".
@immutable
final class HomericProofingRuleAction {
  const HomericProofingRuleAction({
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback onPressed;
}

/// Proofreads one paragraph at a time for an editable paragraph.
abstract interface class HomericProofreader {
  /// Findings in [request]'s text, ordered by start.
  Future<List<HomericProofingIssue>> proofread(
    HomericSpellCheckRequest request,
  );

  /// Fires when the findings for unchanged text may differ: a group or rule
  /// was turned off, a finding was ignored, a phrase rule changed.
  Listenable get proofingChanges;

  /// Stops showing [issue] in block [blockId], where it reads [text], until
  /// the app quits.
  void ignore(String blockId, HomericProofingIssue issue, String text);

  /// The rule action a menu offers for [issue], or null for none.
  HomericProofingRuleAction? ruleActionFor(HomericProofingIssue issue);
}

/// Something that finds issues in plain text: Harper, the writer's own
/// phrase rules.
abstract interface class HomericProofingSource {
  /// Findings in [text], in any order.
  Future<List<HomericProofingIssue>> check(String text);
}

/// A [HomericProofreader] over several [HomericProofingSource]s, with the
/// writer's choices applied: groups on and off, rules turned off, findings
/// ignored for the session.
///
/// The host keeps the choices in its settings and sets them here; each
/// change fires [proofingChanges] so open paragraphs check again.
class HomericProofingSuite extends ChangeNotifier
    implements HomericProofreader {
  HomericProofingSuite({
    required List<HomericProofingSource> sources,
    Set<HomericProofingGroup> groups = const {
      HomericProofingGroup.grammar,
      HomericProofingGroup.repetitionAndPunctuation,
      HomericProofingGroup.wordiness,
      HomericProofingGroup.yourRules,
    },
    Set<String> rulesOff = const {},
    this.onTurnOffRule,
    this.onEditRule,
  })  : _sources = List.unmodifiable(sources),
        _groups = Set.unmodifiable(groups),
        _rulesOff = Set.unmodifiable(rulesOff);

  List<HomericProofingSource> _sources;
  Set<HomericProofingGroup> _groups;
  Set<String> _rulesOff;
  final Set<(String, String, String)> _ignored = {};
  bool _enabled = true;

  /// Called with a rule the writer turned off from a menu; the host saves
  /// it and sets [rulesOff].
  final ValueChanged<HomericProofingIssue>? onTurnOffRule;

  /// Called to edit the writer's own rule behind a finding.
  final ValueChanged<HomericProofingIssue>? onEditRule;

  /// Whether proofreading runs at all.
  bool get enabled => _enabled;
  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
  }

  List<HomericProofingSource> get sources => _sources;
  set sources(List<HomericProofingSource> value) {
    if (listEquals(_sources, value)) return;
    _sources = List.unmodifiable(value);
    notifyListeners();
  }

  /// Notes that a source's own findings changed (a phrase rule was added).
  void sourcesChanged() => notifyListeners();

  Set<HomericProofingGroup> get groups => _groups;
  set groups(Set<HomericProofingGroup> value) {
    if (setEquals(_groups, value)) return;
    _groups = Set.unmodifiable(value);
    notifyListeners();
  }

  Set<String> get rulesOff => _rulesOff;
  set rulesOff(Set<String> value) {
    if (setEquals(_rulesOff, value)) return;
    _rulesOff = Set.unmodifiable(value);
    notifyListeners();
  }

  @override
  Listenable get proofingChanges => this;

  @override
  Future<List<HomericProofingIssue>> proofread(
    HomericSpellCheckRequest request,
  ) async {
    if (!_enabled || _groups.isEmpty || request.text.trim().isEmpty) {
      return const [];
    }
    final text = request.text;
    final found = <HomericProofingIssue>[];
    // A source that fails or throws leaves the others' findings standing.
    Future<List<HomericProofingIssue>> safely(
      HomericProofingSource source,
    ) async {
      try {
        return await source.check(text);
      } on Object {
        return const <HomericProofingIssue>[];
      }
    }

    final results = await Future.wait(<Future<List<HomericProofingIssue>>>[
      for (final source in _sources) safely(source),
    ]);
    for (final issues in results) {
      for (final issue in issues) {
        final range = issue.range;
        if (range.start < 0 ||
            range.end > text.length ||
            range.end <= range.start) {
          continue;
        }
        if (!_groups.contains(issue.group)) continue;
        if (_rulesOff.contains(issue.ruleId)) continue;
        final words = text.substring(range.start, range.end);
        if (_ignored.contains((request.blockId, issue.ruleId, words))) {
          continue;
        }
        if (found.contains(issue)) continue;
        found.add(issue);
      }
    }
    found.sort((a, b) => a.range.start != b.range.start
        ? a.range.start.compareTo(b.range.start)
        : a.range.end.compareTo(b.range.end));
    return List.unmodifiable(found);
  }

  @override
  void ignore(String blockId, HomericProofingIssue issue, String text) {
    if (_ignored.add((blockId, issue.ruleId, text))) notifyListeners();
  }

  @override
  HomericProofingRuleAction? ruleActionFor(HomericProofingIssue issue) {
    if (issue.group == HomericProofingGroup.yourRules) {
      final edit = onEditRule;
      if (edit == null) return null;
      return HomericProofingRuleAction(
        label: 'Edit rule',
        onPressed: () => edit(issue),
      );
    }
    final turnOff = onTurnOffRule;
    if (turnOff == null) return null;
    return HomericProofingRuleAction(
      label: 'Turn off this rule',
      onPressed: () {
        rulesOff = {..._rulesOff, issue.ruleId};
        turnOff(issue);
      },
    );
  }
}
