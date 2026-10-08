/// Opt-in markdown typing shortcuts that write stock run attributes.
///
/// Default is **off**: hosts must register [interceptor] (or call
/// [installOn]) to enable. This path converts typed `**bold**`, `*italic*`,
/// and `` `code` `` delimiters into run attributes and removes the markers.
/// It does **not** participate in the journal live-preview / hide-marker
/// path, which keeps literal markdown in the document and paints via
/// decorations — Nexus must leave this policy uninstalled.
library;

import 'package:flutter/foundation.dart';

import '../model/block.dart';
import '../model/inline_run.dart';
import '../model/position.dart';
import '../transform/replace_step.dart';
import '../transform/transaction.dart';
import 'editor_controller.dart';

/// Maps typed markdown delimiters to stock run attributes while typing.
final class HomericMarkdownShortcutPolicy {
  /// Creates a policy. All delimiter families default to enabled once the
  /// policy itself is installed.
  const HomericMarkdownShortcutPolicy({
    this.bold = true,
    this.italic = true,
    this.code = true,
    this.boldKey = 'bold',
    this.italicKey = 'italic',
    this.codeKey = 'code',
  });

  /// Whether `**…**` converts to [boldKey].
  final bool bold;

  /// Whether `*…*` converts to [italicKey] (not `**`).
  final bool italic;

  /// Whether `` `…` `` converts to [codeKey].
  final bool code;

  /// Attribute key written for bold shortcuts.
  final String boldKey;

  /// Attribute key written for italic shortcuts.
  final String italicKey;

  /// Attribute key written for code shortcuts.
  final String codeKey;

  /// Command interceptor that applies shortcuts on [HomericCommandKind.preInsert].
  HomericCommandInterceptor get interceptor => _intercept;

  /// Registers [interceptor] on [controller]; returns the unregister callback.
  VoidCallback installOn(HomericEditorController controller) =>
      controller.addCommandInterceptor(interceptor);

  HomericCommandInterception _intercept(HomericEditorCommand command) {
    if (command.kind != HomericCommandKind.preInsert) {
      return HomericCommandInterception.ignored;
    }
    final inserted = command.text;
    final selection = command.selection;
    final blockId = command.blockId;
    if (inserted == null ||
        inserted.length != 1 ||
        selection == null ||
        !selection.isCollapsed ||
        blockId == null) {
      return HomericCommandInterception.ignored;
    }

    final controller = command.controller;
    final document = controller.document;
    final resolved = document.resolve(selection.head);
    if (resolved is! InlinePosition || resolved.block.id != blockId) {
      return HomericCommandInterception.ignored;
    }

    final block = resolved.block;
    final offset = resolved.offset;
    final before = block.text.substring(0, offset);
    final afterInsert = '$before$inserted';

    final match = _matchClosing(afterInsert);
    if (match == null) return HomericCommandInterception.ignored;

    final openLen = match.marker.length;
    final closeStart = afterInsert.length - openLen;
    final markerStart = closeStart - match.innerLength - openLen;
    if (markerStart < 0) return HomericCommandInterception.ignored;
    final innerStart = markerStart + openLen;
    if (innerStart > closeStart) return HomericCommandInterception.ignored;
    final inner = afterInsert.substring(innerStart, closeStart);
    if (inner.isEmpty) return HomericCommandInterception.ignored;

    final globalFrom = document.positionAt(resolved.blockIndex, markerStart);
    final globalTo = document.positionAt(resolved.blockIndex, offset);
    final tx = Transaction(document);
    try {
      tx.step(ReplaceStep(
        globalFrom,
        globalTo,
        Slice(
          <Block>[
            Block(
              id: block.id,
              type: block.type,
              attributes: block.attributes,
              runs: <InlineRun>[
                InlineRun(
                  inner,
                  attributes: <String, Object?>{match.key: true},
                ),
              ],
            ),
          ],
          openStart: true,
          openEnd: true,
        ),
      ));
    } on ArgumentError {
      return HomericCommandInterception.ignored;
    } on StateError {
      return HomericCommandInterception.ignored;
    }

    final applied = controller.applyTransaction(tx);
    if (!applied) return HomericCommandInterception.ignored;
    // Caret was collapsed at [globalTo]; mapping lands it after [inner].
    return HomericCommandInterception.handled;
  }

  _ShortcutMatch? _matchClosing(String text) {
    if (bold && text.endsWith('**')) {
      final innerLength = _findOpen(
        text,
        marker: '**',
        allowNestedDelimiter: false,
      );
      if (innerLength != null) {
        return _ShortcutMatch(
          marker: '**',
          key: boldKey,
          innerLength: innerLength,
        );
      }
    }
    if (code && text.endsWith('`')) {
      final innerLength = _findOpen(
        text,
        marker: '`',
        allowNestedDelimiter: false,
      );
      if (innerLength != null) {
        return _ShortcutMatch(
          marker: '`',
          key: codeKey,
          innerLength: innerLength,
        );
      }
    }
    if (italic && text.endsWith('*') && !text.endsWith('**')) {
      final innerLength = _findOpen(
        text,
        marker: '*',
        allowNestedDelimiter: false,
      );
      if (innerLength != null) {
        return _ShortcutMatch(
          marker: '*',
          key: italicKey,
          innerLength: innerLength,
        );
      }
    }
    return null;
  }

  /// Returns the inner content length between the last opening [marker] and
  /// the closing marker at the end of [text], or `null` when no match.
  int? _findOpen(
    String text, {
    required String marker,
    required bool allowNestedDelimiter,
  }) {
    final closeStart = text.length - marker.length;
    if (closeStart <= marker.length) return null;
    final search = text.substring(0, closeStart);
    final openAt = search.lastIndexOf(marker);
    if (openAt < 0) return null;
    final innerStart = openAt + marker.length;
    if (innerStart >= closeStart) return null;
    final inner = text.substring(innerStart, closeStart);
    if (inner.isEmpty) return null;
    if (!allowNestedDelimiter && inner.contains(marker)) return null;
    // For single `*`, reject when the opening is actually part of `**`.
    if (marker == '*' && openAt > 0 && text[openAt - 1] == '*') {
      return null;
    }
    return inner.length;
  }
}

final class _ShortcutMatch {
  const _ShortcutMatch({
    required this.marker,
    required this.key,
    required this.innerLength,
  });

  final String marker;
  final String key;
  final int innerLength;
}
