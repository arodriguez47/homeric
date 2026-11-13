/// The writer's own phrase rules: flag a word or phrase, and offer what to
/// write instead ("in order to" → "to", "utilize" → "use").
///
/// Matching ignores case and only takes whole words, so "use" never
/// matches inside "because". A replacement keeps the capital of the words
/// it replaces at the start of a sentence.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show TextRange;

import '../editing/proofreading.dart';

/// One phrase rule.
@immutable
final class HomericPhraseRule {
  const HomericPhraseRule({required this.find, this.replace});

  /// What to flag. Spaces inside match any run of spaces.
  final String find;

  /// What to offer instead, or null to flag only. Empty offers removal.
  final String? replace;

  /// The rule's stable id, the same for any capitalisation of [find].
  String get id => 'phrase:${_normal(find)}';

  /// Whether the rule has anything to find.
  bool get isValid => _normal(find).isNotEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
        'find': find,
        if (replace != null) 'replace': replace,
      };

  static HomericPhraseRule? fromJson(Object? json) {
    if (json is! Map) return null;
    final find = json['find'];
    final replace = json['replace'];
    if (find is! String || (replace != null && replace is! String)) {
      return null;
    }
    final rule = HomericPhraseRule(find: find, replace: replace as String?);
    return rule.isValid ? rule : null;
  }

  @override
  bool operator ==(Object other) =>
      other is HomericPhraseRule &&
      other.find == find &&
      other.replace == replace;

  @override
  int get hashCode => Object.hash(find, replace);

  @override
  String toString() => 'HomericPhraseRule($find → $replace)';
}

String _normal(String phrase) =>
    phrase.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

/// Finds the writer's [HomericPhraseRule]s in a paragraph.
class HomericPhraseRules implements HomericProofingSource {
  HomericPhraseRules([List<HomericPhraseRule> rules = const []]) {
    this.rules = rules;
  }

  List<HomericPhraseRule> _rules = const [];
  List<(HomericPhraseRule, RegExp)> _patterns = const [];

  List<HomericPhraseRule> get rules => _rules;
  set rules(List<HomericPhraseRule> value) {
    _rules = List.unmodifiable(value.where((rule) => rule.isValid));
    _patterns = List.unmodifiable([
      for (final rule in _rules)
        (
          rule,
          RegExp(
            r'(?<![\p{L}\p{N}_])' +
                _normal(rule.find).split(' ').map(RegExp.escape).join(r'\s+') +
                r'(?![\p{L}\p{N}_])',
            caseSensitive: false,
            unicode: true,
          ),
        ),
    ]);
  }

  /// Findings in [text], synchronously.
  List<HomericProofingIssue> find(String text) {
    final found = <HomericProofingIssue>[];
    for (final (rule, pattern) in _patterns) {
      for (final match in pattern.allMatches(text)) {
        final words = match[0]!;
        final replace = rule.replace;
        final message = replace == null
            ? 'Your rule flags "${_normal(rule.find)}".'
            : replace.isEmpty
                ? 'Your rule: leave out "${_normal(rule.find)}".'
                : 'Your rule: "${_normal(rule.find)}" → "$replace".';
        found.add(HomericProofingIssue(
          range: TextRange(start: match.start, end: match.end),
          group: HomericProofingGroup.yourRules,
          ruleId: rule.id,
          message: message,
          replacements: [
            if (replace != null) _matchCase(words, replace),
          ],
        ));
      }
    }
    return found;
  }

  @override
  Future<List<HomericProofingIssue>> check(String text) =>
      SynchronousFuture(find(text));
}

/// [replace] with the first letter's case of [words]: "In order to" →
/// "To".
String _matchCase(String words, String replace) {
  if (replace.isEmpty || words.isEmpty) return replace;
  final first = words[0];
  final upper = first.toUpperCase() == first && first.toLowerCase() != first;
  if (!upper) return replace;
  return replace[0].toUpperCase() + replace.substring(1);
}
