# HOM-21 geometry-capability handoff

## Outcome

Closed a headless-verifiable IME candidate/caret placement race without
claiming platform certification. Platform geometry publication is now bound to
an opaque lease retrievable only by the exact active block and host owner.

## Failure that established the work

The proof-first input-session test failed to compile because
`publishGeometry` had no block/host capability witness. Inspection then showed
that a post-frame callback from a recycled prior row or replaced same-block
host could pass the existing document-identity and layout-generation checks.

## Implementation

- `HomericTextInputSession` issues a unique `HomericTextInputGeometryLease` to
  an identified `(blockId, owner)` attachment.
- Lease retrieval fails closed for the wrong block, wrong owner, or ownerless
  attachment.
- Attach, retarget, structural survivor changes, blur, platform close, and
  disposal rotate or revoke the lease as appropriate.
- Publication also rechecks active block, read-only state, document identity,
  and monotonic layout generation.
- `HomericEditableParagraph` captures the exact lease with measured geometry
  before its post-frame callback.

## Verification

- Focused input session: 22/22 passed.
- Input + editable paragraph + editable document: 136/136 passed.
- Playground integration trace: 1/1 passed on macOS; foregrounding failed
  because the Mac was locked, but the runner completed successfully.
- Focused analysis: no issues.
- Scoped diff checks: clean.

## Evidence boundary

This proves stale in-process geometry cannot move the current IME candidate or
caret rect. It does not certify actual candidate-window placement on macOS,
Windows, Linux, iOS, Android, or web. Those real-platform rows remain open in
`docs/testing/ime-acceptance.md` and Linear HOM-21.

No commit, push, GitHub Actions run, publication, or deployment was performed.
