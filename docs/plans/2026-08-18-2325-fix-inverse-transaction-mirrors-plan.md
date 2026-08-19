---
title: Preserve Mirror Pairs in Inverse Transactions - Plan
type: fix
date: 2026-08-18
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: linear-hom-10
execution: code
---

# Preserve Mirror Pairs in Inverse Transactions - Plan

## Goal Capsule

- **Objective:** Undo transactions restore both document content and the mirror
  routing that keeps caret and decoration anchors inside moved blocks alive.
- **Authority:** Linear HOM-10 and the existing `Mapping.appendMappingInverted`
  contract.
- **Execution profile:** Local implementation and verification only. Do not
  push, merge, deploy, or run GitHub Actions.

## Product Contract

### Requirements

- R1. `Transaction.inverting(source)` starts from `source.doc` and applies each
  source step's inverse in reverse order against `source.docs[i]`.
- R2. The inverse transaction restores `source.before` exactly.
- R3. A source mirror pair `(i, m)` is registered at reversed indices
  `(n - 1 - i, n - 1 - m)` in the inverse mapping.
- R4. Mapping a caret or decoration inside a moved block forward through the
  source and back through the inverse preserves its anchor.
- R5. Transactions without mirror pairs retain ordinary inverse behavior.
- R6. The playground history path consumes the shared inverse-transaction API
  instead of maintaining a second manual inversion loop.
- R7. The deterministic fuzz invariant checks document restoration through the
  shared API and checks decoration round trips for move-only scenarios.

### Scope Boundaries

- Do not redesign history storage, snapshots, redo, or transaction atomicity.
- Do not change `Mapping` mirror semantics or `Step.invert`.
- Do not alter decoration loss policy for destructive edits.

## Implementation Units

### U1. Add inverse transaction construction

**Files:**
- `packages/homeric/lib/src/transform/transaction.dart`
- `packages/homeric/test/transform/transaction_test.dart`

**Goal:** Add and pin the named constructor, reversed step order, exact document
restoration, and reversed mirror indices.

**Verification:** Focused transaction tests pass and a mutation that omits
mirror re-registration drops a moved-block anchor.

### U2. Route history and fuzz through the shared contract

**Files:**
- `packages/homeric/examples/playground/lib/view_models/document_view_model.dart`
- `packages/homeric/examples/playground/test/document_view_model_test.dart`
- `packages/homeric/test/property/generators.dart`

**Goal:** Remove the duplicate manual inversion loop and extend invariant 5 to
exercise inverse transaction mapping for moved-block decorations.

**Verification:** Playground undo tests and the default deterministic fuzz run
pass.

### U3. Record and validate the contract

**Files:**
- `LEARNINGS.md`
- Nexus `LEARNINGS.md` mirror under the reciprocal HOM-2 rule

**Goal:** Record that an inverse transaction is document restoration plus
mapping metadata restoration, not merely reversed steps.

**Verification:** Full Melos test, analyze, and format checks pass; both learning
entries are present; local branches are clean.

## Verification Contract

- Focused transaction test proves reversed mirror indices and caret/decorations
  survive a move round trip.
- Playground undo tests exercise `Transaction.inverting`.
- The 10,000-seed default fuzz run exercises document restoration and
  move-only decoration round trips.
- `melos run test`, `melos run analyze`, and `melos run format-check` pass.
- `git diff --check` passes in every changed repository.

## Definition of Done

- R1-R7 are implemented and covered.
- The old playground manual inversion loop is gone.
- Homeric and Nexus carry the reciprocal learning.
- Work is committed locally and HOM-10 is updated in Linear.
- No GitHub Actions, push, merge, or deployment occurred.
