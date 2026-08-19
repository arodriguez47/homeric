# HOM-17 reflection — ParagraphOverlay

## What changed

- Added `ParagraphOverlay`, a layout-neutral wrapper that publishes only geometry from the currently laid-out `HomericParagraph` generation.
- Kept the paragraph as the sole non-positioned child so overlay content cannot change paragraph constraints or height.
- Added explicit `slotLayoutRevision` invalidation for externally owned inline-slot geometry and guarded catch-up when a conservative revision does not cause relayout.
- Preserved `HomericParagraph.onGeometryChanged`, including late attachment and detach/reattach behavior.
- Migrated the playground caret overlay from its hand-rolled `GlobalKey`/`Stack` observer path.

## Assumptions and boundaries

- Consumers advance `slotLayoutRevision` when slot size can change without a paragraph input change; `null` is appropriate when no slots exist or slot size is fully derived from paragraph inputs.
- `Clip.none` permits visible overflow but does not expand hit-testing beyond paragraph bounds. Interactive margin UI belongs in bounds or in an application overlay.
- The internal paragraph copier lives in the same library as `HomericParagraph`; future constructor fields must be forwarded there.

## Historical failures captured

- Stale geometry could render for one frame after source, style, constraints, paragraph identity, or inline-slot changes.
- Same-size slot revisions could suppress an overlay forever because no render generation changed.
- Late public observers could miss current geometry, including combined slot changes and same-callback reattachment.
- Overlay children could accidentally participate in outer Stack layout.

The focused suite includes regression and mutation coverage for each of these paths. Removing the slot-revision freshness gate or late-callback catch-up makes its targeted test fail.

## Review reflection

The independent review agrees the abstraction now preserves layout neutrality, generation freshness, callback semantics, and the intended interaction boundary. The main residual risk is caller discipline around externally mutable inline slots. A concrete future improvement is a focused constructor-forwarding test for the private `_observedBy` copier so a newly added optional paragraph field cannot be omitted silently.

## Follow-up disposition

No blocking follow-up remains for HOM-17. The caller-owned slot revision contract and paragraph field-forwarding risk are documented in code and `LEARNINGS.md`; a separate issue is not warranted unless a second consumer exposes a better automatic invalidation seam.
