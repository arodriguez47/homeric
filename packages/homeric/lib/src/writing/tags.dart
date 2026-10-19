/// Inline `#tags`: recognised as they are typed, read out of a note's
/// text and renamed in place.
///
/// Homeric owns the rule for what counts as a tag; what a tag means (a
/// filter, a kind, a menu on click) belongs to the host.
library;

/// Reading, merging and renaming `#tags`.
abstract final class HomericTags {
  /// An inline `#tag`: group 1 is the name. The match can include one
  /// leading space or bracket, so the `#` sits at `end - name.length - 1`.
  static final RegExp pattern =
      RegExp(r'(?:^|[\s([{])#([a-zA-Z0-9][\w-]{0,48})\b');

  /// Parse `#tags` from free-form note text.
  ///
  /// Rules:
  /// - Tag starts with `#` followed by a letter or digit
  /// - Continues with letters, digits, `_`, or `-`
  /// - Normalized to lowercase; duplicates removed (order preserved)
  static List<String> parse(String text) {
    if (text.isEmpty) return const [];
    final seen = <String>{};
    final out = <String>[];
    for (final match in pattern.allMatches(text)) {
      final tag = match.group(1)!.toLowerCase();
      if (seen.add(tag)) out.add(tag);
    }
    return out;
  }

  /// Merge explicit tags with tags parsed from [body], preserving order.
  static List<String> merge(List<String> explicit, String body) {
    final seen = <String>{};
    final out = <String>[];
    for (final t in [...explicit, ...parse(body)]) {
      final n = t.trim().toLowerCase().replaceFirst(RegExp(r'^#'), '');
      if (n.isEmpty) continue;
      if (seen.add(n)) out.add(n);
    }
    return out;
  }

  /// Which of the tag field's [tags] were added by hand: those not written
  /// as a `#tag` in [body], and earlier hand tags ([was]) still in the field.
  static List<String> handTags(
    List<String> tags, {
    required String body,
    List<String> was = const [],
  }) {
    final inline = parse(body).toSet();
    final kept = merge(was, '').toSet();
    return [
      for (final t in merge(tags, ''))
        if (!inline.contains(t) || kept.contains(t)) t,
    ];
  }

  /// [tags] after a note's text changes from [before] to [after]: inline tags
  /// newly typed are added, and ones whose `#tag` was deleted from the text
  /// are dropped, unless they were added by hand ([handTags]). Tags that
  /// were never inline are kept.
  static List<String> retagForBody(
    List<String> tags, {
    required String before,
    required String after,
    Iterable<String> handTags = const [],
  }) {
    String norm(String t) =>
        t.trim().toLowerCase().replaceFirst(RegExp(r'^#'), '');
    final removed = parse(before).toSet()
      ..removeAll(parse(after))
      // A tag added by hand stays, whatever happens to its #tag.
      ..removeAll(handTags.map(norm));
    return merge(
      [
        for (final t in tags)
          if (!removed.contains(norm(t))) t
      ],
      after,
    );
  }

  /// [text] with every inline `#from` renamed to `#to`, or, when [to] is null,
  /// turned back into the plain word (the `#` comes off, the word stays).
  /// [from] matches whatever case it was typed in.
  static String retagText(String text, String from, String? to) {
    final name = from.toLowerCase();
    final out = StringBuffer();
    var last = 0;
    for (final m in pattern.allMatches(text)) {
      final word = m.group(1)!;
      if (word.toLowerCase() != name) continue;
      final hash = m.end - word.length - 1;
      out
        ..write(text.substring(last, hash))
        ..write(to == null ? word : '#$to');
      last = m.end;
    }
    if (last == 0) return text;
    out.write(text.substring(last));
    return out.toString();
  }

  /// [tags] with [from] renamed to [to], or taken out when [to] is null. A
  /// note that already has [to] keeps it once, where it was.
  static List<String> renameInTags(List<String> tags, String from, String? to) {
    final out = <String>[];
    for (final t in tags) {
      final next = t == from ? to : t;
      if (next != null && !out.contains(next)) out.add(next);
    }
    return out;
  }
}
