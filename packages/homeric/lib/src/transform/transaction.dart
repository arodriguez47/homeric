// Transaction semantics ported from prosemirror-transform
// src/transform.ts @ 662b7a937bafde19b7e2a83241dbc8888e257c89; MIT
// (c) Marijn Haverbeke. The upstream source was read to learn the
// semantics; this implementation is original Dart and no source code was
// copied.

import 'dart:collection';

import '../model/document.dart';
import 'change_list.dart';
import 'mapping.dart';
import 'step.dart';

/// Thrown by [Transaction.step] when a step fails to apply.
///
/// This is the transform layer's only throwing entry point for misfits:
/// [Step.apply] and [Transaction.maybeStep] report failure as a value.
final class StepFailedError extends Error {
  /// Creates the error with the failing step's message.
  StepFailedError(this.message);

  /// Why the step failed.
  final String message;

  @override
  String toString() => 'StepFailedError: $message';
}

/// The outcome of a transaction: the new document, what changed, and how
/// positions map from the old document to the new one.
final class TransactionResult {
  /// Creates a result.
  const TransactionResult(this.doc, this.changes, this.mapping);

  /// The post-transaction document.
  final Document doc;

  /// Touched blocks and structural outcomes.
  final ChangeList changes;

  /// The composed position mapping over every applied step.
  final Mapping mapping;
}

/// An accumulating sequence of steps over a document.
///
/// A transaction tracks, for every applied step, the document it was
/// applied to ([docs]), the step itself ([steps]), and its position map
/// (composed into [mapping]). Retention shares at the [Block] level: each
/// document version reuses every untouched block object, so block content
/// is never deep-copied. Each version does hold its own full-length block
/// *array* (steps rebuild the whole list via `replaceBlockRange`), so
/// keeping [docs] costs O(steps × total block count) in array slots.
final class Transaction {
  /// Starts a transaction over [before].
  Transaction(this.before) : _doc = before;

  /// The document the transaction started from.
  final Document before;

  Document _doc;
  final List<Step> _steps = <Step>[];
  final List<Document> _docs = <Document>[];
  final List<StructuralChange> _structural = <StructuralChange>[];

  /// The composed position mapping. Builders may register mirror pairs on
  /// it (see `moveBlock`) so positions inside moved content recover into
  /// the destination.
  final Mapping mapping = Mapping();

  /// The current document.
  Document get doc => _doc;

  // The views are live (they reflect later steps) and the backing lists are
  // never replaced, so one instance each suffices.
  late final List<Step> _stepsView = UnmodifiableListView(_steps);
  late final List<Document> _docsView = UnmodifiableListView(_docs);

  /// The applied steps, in order (unmodifiable view).
  List<Step> get steps => _stepsView;

  /// For each applied step, the document it was applied to (unmodifiable
  /// view); `docs[i]` is the input to `steps[i]`.
  List<Document> get docs => _docsView;

  /// Whether any step has been applied.
  bool get docChanged => _steps.isNotEmpty;

  /// Tries to apply [step] to the current document. On success the step is
  /// recorded and the current document advances; on failure nothing
  /// changes. Never throws on a misfit.
  StepResult maybeStep(Step step) {
    final result = step.apply(_doc);
    if (!result.failed) {
      _docs.add(_doc);
      _steps.add(step);
      mapping.appendMap(step.getMap());
      _structural.addAll(result.structural);
      _doc = result.doc!;
    }
    return result;
  }

  /// Applies [step], throwing [StepFailedError] when it does not fit.
  void step(Step step) {
    final result = maybeStep(step);
    if (result.failed) throw StepFailedError(result.failure!);
  }

  /// Applies [first], then the step [second] builds against the resulting
  /// document, and registers their position maps as a mirror pair — the
  /// shape of a block move, where positions inside the deleted content
  /// recover into the re-inserted copy. [record], when given, is the
  /// structural outcome the pair produces (e.g. a `BlockMove`).
  ///
  /// [second] is a callback because the second step's positions are
  /// expressed in the coordinates left behind by [first]. Throws
  /// [StepFailedError] (like [step]) when either step does not fit. The
  /// pair is atomic: when either step fails, nothing is recorded — the
  /// transaction is left exactly as it was before the call.
  void stepPairMirrored(Step first, Step Function(Document doc) second,
      {StructuralChange? record}) {
    final firstResult = first.apply(_doc);
    if (firstResult.failed) throw StepFailedError(firstResult.failure!);
    final firstDoc = firstResult.doc!;
    final secondStep = second(firstDoc);
    final secondResult = secondStep.apply(firstDoc);
    if (secondResult.failed) throw StepFailedError(secondResult.failure!);

    _docs
      ..add(_doc)
      ..add(firstDoc);
    _steps
      ..add(first)
      ..add(secondStep);
    mapping
      ..appendMap(first.getMap())
      ..appendMap(secondStep.getMap());
    _structural
      ..addAll(firstResult.structural)
      ..addAll(secondResult.structural);
    _doc = secondResult.doc!;
    mapping.setMirror(_steps.length - 2, _steps.length - 1);
    if (record != null) _structural.add(record);
  }

  ChangeList? _changesCache;
  int _changesCacheSteps = -1;
  int _changesCacheStructural = -1;

  /// The change list for everything applied so far: touched block ids with
  /// their old/new global ranges, plus split/join/move outcomes.
  /// Memoized until the next applied step or structural record.
  ChangeList get changes {
    final cached = _changesCache;
    if (cached != null &&
        _changesCacheSteps == _steps.length &&
        _changesCacheStructural == _structural.length) {
      return cached;
    }
    _changesCacheSteps = _steps.length;
    _changesCacheStructural = _structural.length;
    return _changesCache = ChangeList.compute(before, _doc, _structural);
  }

  /// The transaction's summary: `(new Document, ChangeList, Mapping)`.
  TransactionResult finish() => TransactionResult(_doc, changes, mapping);

  @override
  String toString() => 'Transaction(${_steps.length} steps, $_doc)';
}
