# AGENTS.md

Conventions for agents and humans working in this repo.

## What this project is

Homeric: a Flutter text-editing package built from fundamentals — own document model, positions/StepMap, DecorationSet, and (in later phases) layout, RenderObject, and input, with `dart:ui` doing glyph shaping only. Strategy in [`STRATEGY.md`](STRATEGY.md); phases in [`docs/ROADMAP.md`](docs/ROADMAP.md) mirroring Linear (team **Homeric**, epic HOM-1); the active implementation plan lives in `docs/plans/`.

## Hard rules

- **Licensing / provenance:** never copy source from super_editor, AppFlowy, or ProseMirror — including "for reference." Read to learn, then write. When PM's algorithmic math is ported (StepMap ranges, recover), the file header cites the upstream file and commit. Porting *test expectations* is fine and intended.
- **Phase 1 purity:** zero `package:flutter` or `dart:ui` imports under `lib/src/model`, `lib/src/transform`, `lib/src/decoration`, `lib/src/view` — enforced by `no_flutter_imports_test`.
- **No presentation semantics in the core:** decorations/annotations expose anchored ranges and (Phase 2) geometry; margin note vs popover is the consumer's decision.
- **Structural sharing, no deep copies:** history retention and 100k-word memory behavior depend on it; reference-identity tests guard it.

## Compounding rule (mirrored learnings)

A learning about **text layout, offset mapping, selection geometry, or editor architecture** is written to *both* repos in the same change: here in [`LEARNINGS.md`](LEARNINGS.md) (format: `## <role> — <date> — <topic>`) and in Nexus's learnings under `homeric/`. Nexus's AGENTS.md carries the reciprocal clause. This instruction is the automation — an agent reading either repo's AGENTS.md learns to mirror; there is no sync job.

## Workflow

- Conventional commits (see [`CONTRIBUTING.md`](CONTRIBUTING.md)); `perf:` commits need benchmark deltas once the harness exists (Phase 4).
- `melos bootstrap`, then `melos run analyze` / `test` / `format-check` must be green before landing.
- Tests: property-based where the plan says so; unit tests colocated under `test/` mirroring `lib/src/` structure.
- Project tracker: `project_tracker: linear` (team Homeric). Branch names follow Linear's `feature/hom-N` convention.
