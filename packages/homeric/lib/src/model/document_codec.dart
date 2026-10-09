/// Public JSON document codec (format version 1).
///
/// Wire-compatible with the sprintnotes host codec
/// (`lib/services/homeric_document.dart` on branch
/// `cursor/firebase-macos-desktop-f483`): a top-level `v: 1` envelope with
/// `blocks` carrying `id`, `type`, `attributes`, and `runs` (each run has
/// `text` + `attributes`). Pure Dart — no Flutter / `dart:ui`.
///
/// Sprintnotes parity notes:
/// - [HomericDocumentCodecException] extends [FormatException] so
///   `documentFromStored()` can `catch (FormatException)` and fall back to
///   plain-text migration.
/// - An empty `blocks` array decodes to one empty paragraph with
///   `runs: [InlineRun('')]`.
/// - Missing or empty `runs` on a block become `[InlineRun('')]`.
/// - Encode always writes `attributes` maps and normalizes empty content to
///   one empty run so the wire shape stays
///   `{v:1, blocks:[{id,type,attributes,runs:[{text,attributes}]}]}`.
library;

import 'dart:convert';

import 'attributes.dart';
import 'block.dart';
import 'document.dart';
import 'inline_run.dart';

/// Thrown when [HomericDocumentCodec.decode] / [decodeJson] rejects input.
///
/// Extends [FormatException] so host migration paths that catch
/// [FormatException] (e.g. sprintnotes `documentFromStored`) keep working
/// when swapping to this codec.
final class HomericDocumentCodecException extends FormatException {
  /// Creates an exception describing a codec failure.
  HomericDocumentCodecException(super.message, [super.source, super.offset]);

  @override
  String toString() => 'HomericDocumentCodecException: $message';
}

/// Encodes and decodes [Document] values as Homeric JSON format version 1.
final class HomericDocumentCodec {
  HomericDocumentCodec._();

  /// Current wire-format version.
  static const int formatVersion = 1;

  /// Default block type written for the empty-document migration.
  static const String defaultBlockType = 'paragraph';

  /// Encodes [document] to a JSON-compatible map (`v` + `blocks`).
  ///
  /// Empty documents encode as a single empty paragraph so the wire form
  /// always carries at least one block (sprintnotes store shape).
  static Map<String, Object?> encode(Document document) {
    final blocks = document.blocks.isEmpty
        ? <Block>[
            Block(
              id: 'block_0',
              type: defaultBlockType,
              runs: <InlineRun>[InlineRun('')],
            ),
          ]
        : document.blocks;
    return <String, Object?>{
      'v': formatVersion,
      'blocks': <Object?>[
        for (final block in blocks) _encodeBlock(block),
      ],
    };
  }

  /// Decodes a JSON-compatible [payload] produced by [encode].
  ///
  /// Throws [HomericDocumentCodecException] (a [FormatException]) when the
  /// payload is not a valid format-version-1 document.
  static Document decode(Object? payload) {
    if (payload is! Map) {
      throw HomericDocumentCodecException(
        'expected a JSON object, got ${payload.runtimeType}',
      );
    }
    final map = _asStringKeyedMap(payload, 'root');
    final version = map['v'];
    if (version != formatVersion) {
      throw HomericDocumentCodecException(
        'unsupported format version: $version (expected $formatVersion)',
      );
    }
    final blocksRaw = map['blocks'];
    if (blocksRaw is! List) {
      throw HomericDocumentCodecException(
        'blocks must be a JSON array (at root.blocks)',
      );
    }
    if (blocksRaw.isEmpty) {
      return Document([
        Block(
          id: 'block_0',
          type: defaultBlockType,
          runs: <InlineRun>[InlineRun('')],
        ),
      ]);
    }
    final blocks = <Block>[];
    for (var i = 0; i < blocksRaw.length; i++) {
      blocks.add(_decodeBlock(blocksRaw[i], 'root.blocks[$i]', i));
    }
    return Document(blocks);
  }

  /// Encodes [document] to a JSON string.
  static String encodeJson(Document document, {bool indent = false}) {
    final encoded = encode(document);
    if (!indent) return jsonEncode(encoded);
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(encoded);
  }

  /// Decodes a JSON [source] string into a [Document].
  static Document decodeJson(String source) {
    late final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw HomericDocumentCodecException(
        'invalid JSON: ${error.message}',
        error.source,
        error.offset,
      );
    }
    return decode(decoded);
  }

  static Map<String, Object?> _encodeBlock(Block block) {
    final runs = block.runs.isEmpty ? <InlineRun>[InlineRun('')] : block.runs;
    return <String, Object?>{
      'id': block.id,
      'type': block.type,
      'attributes': _encodeAttributes(block.attributes),
      'runs': <Object?>[
        for (final run in runs) _encodeRun(run),
      ],
    };
  }

  static Map<String, Object?> _encodeRun(InlineRun run) {
    return <String, Object?>{
      'text': run.text,
      'attributes': _encodeAttributes(run.attributes),
    };
  }

  /// Copies a frozen bag into a mutable JSON map for encoding.
  static Map<String, Object?> _encodeAttributes(Attributes attributes) {
    if (attributes.isEmpty) return <String, Object?>{};
    return <String, Object?>{
      for (final entry in attributes.entries)
        entry.key: _encodeAttributeValue(entry.value),
    };
  }

  static Object? _encodeAttributeValue(Object? value) {
    return switch (value) {
      null || bool() || int() || double() || String() => value,
      final Map<Object?, Object?> map => <String, Object?>{
          for (final entry in map.entries)
            if (entry.key is String)
              entry.key as String: _encodeAttributeValue(entry.value),
        },
      final List<Object?> list => <Object?>[
          for (final item in list) _encodeAttributeValue(item),
        ],
      _ => throw HomericDocumentCodecException(
          'non-JSON attribute value of type ${value.runtimeType}',
        ),
    };
  }

  static Block _decodeBlock(Object? raw, String path, int index) {
    if (raw is! Map) {
      throw HomericDocumentCodecException(
        'block must be a JSON object (at $path)',
      );
    }
    final map = _asStringKeyedMap(raw, path);
    final id = map['id'];
    final type = map['type'];
    if (id is! String || id.isEmpty) {
      throw HomericDocumentCodecException(
        'block id must be a non-empty string (at $path.id)',
      );
    }
    if (type is! String || type.isEmpty) {
      throw HomericDocumentCodecException(
        'block type must be a non-empty string (at $path.type)',
      );
    }
    final attributes = _decodeAttributes(map['attributes'], '$path.attributes');
    final runsRaw = map['runs'];
    if (runsRaw == null || (runsRaw is List && runsRaw.isEmpty)) {
      return Block(
        id: id,
        type: type,
        attributes: attributes,
        runs: <InlineRun>[InlineRun('')],
      );
    }
    if (runsRaw is! List) {
      throw HomericDocumentCodecException(
        'runs must be a JSON array (at $path.runs)',
      );
    }
    final runs = <InlineRun>[];
    for (var i = 0; i < runsRaw.length; i++) {
      runs.add(_decodeRun(runsRaw[i], '$path.runs[$i]'));
    }
    return Block(id: id, type: type, attributes: attributes, runs: runs);
  }

  static InlineRun _decodeRun(Object? raw, String path) {
    if (raw is! Map) {
      throw HomericDocumentCodecException(
        'run must be a JSON object (at $path)',
      );
    }
    final map = _asStringKeyedMap(raw, path);
    final text = map['text'];
    if (text is! String) {
      throw HomericDocumentCodecException(
        'run text must be a string (at $path.text)',
      );
    }
    final attributes = _decodeAttributes(map['attributes'], '$path.attributes');
    return InlineRun(text, attributes: attributes);
  }

  static Attributes _decodeAttributes(Object? raw, String path) {
    if (raw == null) return emptyAttributes;
    if (raw is! Map) {
      throw HomericDocumentCodecException(
        'attributes must be a JSON object (at $path)',
      );
    }
    final map = _asStringKeyedMap(raw, path);
    try {
      return freezeAttributes(map);
    } on ArgumentError catch (error) {
      throw HomericDocumentCodecException(
        'invalid attributes at $path: ${error.message}',
      );
    }
  }

  static Map<String, Object?> _asStringKeyedMap(
      Map<dynamic, dynamic> raw, String path) {
    final result = <String, Object?>{};
    raw.forEach((key, value) {
      if (key is! String) {
        throw HomericDocumentCodecException(
          'non-String key at $path (got ${key.runtimeType})',
        );
      }
      result[key] = value as Object?;
    });
    return result;
  }
}
