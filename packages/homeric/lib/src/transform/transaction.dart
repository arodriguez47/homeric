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
/// (composed into [mapping]). Retention is cheap by construction: each
/// document version shares every untouched block with its predecessor, so
/// keeping [docs] costs O(changed blocks), never a deep copy.
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

  /// The applied steps, in order (unmodifiable view).
  List<Step> get steps => UnmodifiableListView(_steps);

  /// For each applied step, the document it was applied to (unmodifiable
  /// view); `docs[i]` is the input to `steps[i]`.
  List<Document> get docs => UnmodifiableListView(_docs);

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

  /// Records a structural outcome produced at the builder level (e.g. a
  /// block move, which is two replace steps plus intent).
  void recordStructuralChange(StructuralChange change) {
    _structural.add(change);
  }

  /// The change list for everything applied so far: touched block ids with
  /// their old/new global ranges, plus split/join/move outcomes.
  ChangeList get changes => ChangeList.compute(before, _doc, _structural);

  /// The transaction's summary: `(new Document, ChangeList, Mapping)`.
  TransactionResult finish() => TransactionResult(_doc, changes, mapping);

  @override
  String toString() => 'Transaction(${_steps.length} steps, $_doc)';
}
