// Step contract semantics ported from prosemirror-transform src/step.ts
// @ 662b7a937bafde19b7e2a83241dbc8888e257c89; MIT (c) Marijn Haverbeke.
// The upstream source was read to learn the semantics; this implementation
// is original Dart and no source code was copied.

import '../model/document.dart';
import 'change_list.dart';
import 'step_map.dart';

/// The value-level outcome of [Step.apply]: a new document on success, or a
/// failure message.
///
/// Steps never throw on a document they do not fit — misapplication (e.g. a
/// rebased step landing on changed content) is an expected outcome, reported
/// as a value so callers can drop or retry the step. Only
/// `Transaction.step` converts a failure into a thrown error.
final class StepResult {
  /// A successful application producing [doc], with any structural
  /// block-identity outcomes the step caused.
  StepResult.ok(Document this.doc,
      [List<StructuralChange> structural = const []])
      : failure = null,
        structural = List<StructuralChange>.unmodifiable(structural);

  /// A failed application; [failure] describes the misfit.
  StepResult.fail(String this.failure)
      : doc = null,
        structural = const [];

  /// The resulting document, or `null` when the step failed.
  final Document? doc;

  /// Why the step failed, or `null` on success.
  final String? failure;

  /// Split/join outcomes produced by the step (empty on failure).
  final List<StructuralChange> structural;

  /// Whether the application failed.
  bool get failed => doc == null;

  @override
  String toString() =>
      failed ? 'StepResult.fail($failure)' : 'StepResult.ok($doc)';
}

/// A single atomic document change.
///
/// Steps are the unit of editing: they apply as values (never throwing on a
/// misfit), describe their position effect as a [StepMap], invert
/// losslessly against the document they were applied to, and rebase over
/// other changes by mapping through a [Mappable].
abstract class Step {
  /// Const-enabling base constructor.
  const Step();

  /// Applies this step to [doc]. Returns a failed [StepResult] — never
  /// throws — when the step does not fit the document.
  StepResult apply(Document doc);

  /// The position map describing the deletions and insertions this step
  /// makes. Steps that move no positions return [StepMap.empty].
  StepMap getMap() => StepMap.empty;

  /// Creates a step that exactly undoes this one. [docBefore] must be the
  /// document this step was applied to.
  Step invert(Document docBefore);

  /// Maps this step through [mapping], rebasing it over the changes the
  /// mapping represents. Returns `null` when the step's target was
  /// destroyed and the step no longer applies.
  Step? map(Mappable mapping);

  /// Tries to merge this step with [other], the step applied directly
  /// after it, into a single equivalent step (typing coalescing). Returns
  /// `null` when the two cannot merge.
  Step? merge(Step other) => null;
}
