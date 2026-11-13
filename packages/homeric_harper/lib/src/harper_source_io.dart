import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show TextRange;
import 'package:homeric/homeric.dart';

import 'harper_worker.dart';

/// The English Harper checks against.
enum HarperDialect { american, british, australian, canadian, indian }

/// Harper's English grammar checker, on the device, as a Homeric
/// [HomericProofingSource].
///
/// Spelling is left to the platform checker. Every check runs on one
/// background isolate; the first one loads Harper's dictionary there.
class HarperProofingSource implements HomericProofingSource {
  HarperProofingSource({this.dialect = HarperDialect.american});

  /// Whether Harper can run on this platform: everywhere but the web.
  static bool get isSupported => true;

  final HarperDialect dialect;
  bool _broken = false;

  /// Starts the worker and loads the dictionary before the first check.
  Future<void> warmUp() async {
    try {
      (await HarperWorker.shared()).warmUp(dialect.index);
    } on Object catch (error) {
      _fail(error);
    }
  }

  @override
  Future<List<HomericProofingIssue>> check(String text) async {
    if (_broken || text.trim().isEmpty) return const [];
    try {
      final worker = await HarperWorker.shared();
      final json = await worker.check(text, dialect.index);
      if (json == null) return const [];
      return parseHarperFindings(json, text.length);
    } on Object catch (error) {
      _fail(error);
      return const [];
    }
  }

  void _fail(Object error) {
    // A missing native library (a build without Rust) turns grammar off
    // quietly rather than failing every paragraph.
    _broken = true;
    debugPrint('homeric_harper: grammar checking is off: $error');
  }
}

/// Reads the Rust side's findings; exposed for tests.
@visibleForTesting
List<HomericProofingIssue> parseHarperFindings(String json, int length) {
  final decoded = jsonDecode(json);
  if (decoded is! List) return const [];
  final found = <HomericProofingIssue>[];
  for (final item in decoded) {
    if (item is! Map) continue;
    final start = item['start'];
    final end = item['end'];
    final rule = item['rule'];
    final kind = item['kind'];
    final message = item['message'];
    final replacements = item['replacements'];
    if (start is! int ||
        end is! int ||
        rule is! String ||
        kind is! String ||
        message is! String ||
        start < 0 ||
        end > length ||
        end <= start) {
      continue;
    }
    found.add(
      HomericProofingIssue(
        range: TextRange(start: start, end: end),
        group: harperGroupOf(rule, kind),
        ruleId: rule,
        message: message,
        replacements: [
          if (replacements is List)
            for (final replacement in replacements)
              if (replacement is String) replacement,
        ],
      ),
    );
  }
  return found;
}

/// The settings group a Harper rule falls under.
@visibleForTesting
HomericProofingGroup harperGroupOf(String rule, String kind) {
  if (rule == 'LongSentences') return HomericProofingGroup.longSentences;
  return switch (kind) {
    'Repetition' ||
    'Punctuation' ||
    'Formatting' => HomericProofingGroup.repetitionAndPunctuation,
    'Redundancy' ||
    'Style' ||
    'Enhancement' ||
    'Readability' ||
    'Regionalism' => HomericProofingGroup.wordiness,
    _ => HomericProofingGroup.grammar,
  };
}
