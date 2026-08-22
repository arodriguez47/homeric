# HOM-23 reflection

## What changed

- `ParagraphGeometry.lineBoundaryAt` now detects a genuine two-line caret
  position and queries a grapheme inside the visual line selected by `assoc`.
- Ordinary offsets retain the direct `Paragraph.getLineBoundary` path.
- Producer tests cover the exact wrap, neighboring graphemes, a no-wrap
  control, and a hidden fold sharing the wrap offset on VM and Chrome.

## Assumptions

- Distinct upstream/downstream caret tops are the authoritative witness that a
  view offset has two visual-line homes.
- Homeric block text contains no hard line breaks; structural newlines remain
  separate blocks.

## Failure modes considered

- Shifting every query by one code unit changes ordinary boundaries and can
  split a multi-code-unit grapheme; the implementation shifts only confirmed
  wrap offsets and uses glyph-derived grapheme boundaries.
- Trusting `TextAffinity` at the ambiguous offset remains platform-dependent;
  the chosen query is strictly inside the selected side.
- Folded document offsets can share the same view offset; mapping back retains
  the existing expand convention and is pinned explicitly.

## Verification

- Full `geometry_test.dart`: 39/39 on VM and 39/39 on Chrome.
- `melos run analyze`, `melos run test`, and `melos run format-check`: green.

## Follow-up

- Pin the fixed Homeric revision in Nexus and rerun the Journal line-focus
  consumer test on VM and Chrome before closing HOM-23.
