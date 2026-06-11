# Homeric — Phase 1: Foundation (Weeks 1–4)

A Flutter editor library forked from [super_editor](https://github.com/superlistapp/super_editor) at `0.3.0-dev.51`, optimized for Ulysses-class writing on 100k+ word documents.

**Goal of Phase 1:** stand up the fork, establish a reproducible perf baseline, and prove the bottleneck is exactly where the research said it would be. No new features. No virtualization yet. Just measurement infrastructure and a clean working tree.

---

## Decisions locked in

| Decision | Value |
|---|---|
| Name | `homeric` |
| Repo | `arodriguez47/homeric` (private at start, MIT) |
| License | MIT (preserving super_editor upstream attribution) |
| Platforms (v1) | macOS, Windows, Linux, Android, Web (best-effort, Latin-script first) |
| Base version | super_editor `0.3.0-dev.51` (latest dev) |
| Collaboration | None |
| Repo layout | Monorepo, Melos-managed |

---

## Monorepo layout

```
homeric/
├── melos.yaml                          # workspace config
├── pubspec.yaml                        # workspace root
├── README.md
├── LICENSE                             # MIT, with super_editor attribution
├── NOTICE                              # attribution to Superlist + ProseMirror
├── CONTRIBUTING.md
├── .github/
│   └── workflows/
│       ├── ci.yaml                     # analyze + test on push
│       └── benchmark.yaml              # perf regression on PRs touching core
├── docs/
│   ├── PHASE_1_PLAN.md                 # this file
│   ├── ROADMAP.md                      # the 8-month phased plan
│   ├── ARCHITECTURE.md                 # design doc (StepMap, DecorationSet, virtualization)
│   └── PERF_BUDGET.md                  # SLOs and benchmark thresholds
├── packages/
│   ├── homeric/                        # forked super_editor
│   ├── homeric_text_layout/            # forked super_text_layout
│   ├── homeric_attributed_text/        # forked attributed_text
│   └── homeric_markdown/               # forked super_editor_markdown (Phase 4 extensions)
├── examples/
│   ├── benchmark_100k/                 # the perf harness — primary Phase 1 deliverable
│   └── playground/                     # editor smoke test
└── tools/
    └── corpus/                         # generated long-form text fixtures (10k/50k/100k/500k words)
```

**Why fork the companion packages too:** `super_text_layout` is where the `Paragraph.layout()` calls actually happen. We will need to add a layout-cost instrumentation hook there in Phase 2. Forking now avoids a painful retrofit later.

---

## Week-by-week breakdown

### Week 1 — Repo stand-up

**Deliverables**
- [ ] Private repo `arodriguez47/homeric` created on GitHub
- [ ] super_editor `0.3.0-dev.51` source vendored into `packages/homeric/` (and companions)
- [ ] All package names rewritten: `super_editor` → `homeric`, `super_text_layout` → `homeric_text_layout`, etc.
- [ ] All `pubspec.yaml` files point at the workspace
- [ ] Melos workspace bootstraps cleanly: `melos bootstrap` runs without error
- [ ] `melos run analyze` is green
- [ ] `melos run test` is green (all super_editor's tests still pass under the new names)
- [ ] `LICENSE`, `NOTICE`, `README.md`, `CONTRIBUTING.md` written with proper attribution

**Acceptance criteria**
- A new contributor can `git clone && melos bootstrap && melos run test` and have a green build in under 10 minutes.
- The provenance is unambiguous in `NOTICE`: which files came from super_editor, at which commit, under MIT.

**Tasks (concrete)**
1. `gh repo create arodriguez47/homeric --private --license mit --description "A Flutter editor for long-form writing"`
2. Clone super_editor at `068a20d` (the dev.51 commit confirmed today). Copy `super_editor/`, `super_text_layout/`, `attributed_text/`, `super_editor_markdown/` into `packages/homeric*/`.
3. Find/replace package names with a script in `tools/rename.sh` (committed so the rename is reproducible).
4. Add `melos.yaml` with `bootstrap`, `analyze`, `test`, `format` scripts.
5. Write attribution: top of every renamed file gets a header comment citing the super_editor original path + commit.

### Week 2 — The benchmark harness (the most important week)

The whole project lives or dies on whether we can *measure* the things we're trying to fix. This week we build the regression suite.

**Deliverables**
- [ ] `tools/corpus/` script generating reproducible fixtures: 10k, 50k, 100k, 500k word Markdown documents
- [ ] `examples/benchmark_100k/` Flutter app that loads any of these fixtures and reports:
  - Time-to-first-frame (cold load)
  - Frame build time, percentiles (p50/p95/p99) during scroll
  - Frame raster time, same percentiles
  - Active widget count
  - Active `RenderObject` count
  - Cumulative `Paragraph.layout()` time across the session
- [ ] A `Timeline.startSync(...)` instrumentation in `homeric_text_layout` around every layout call so the Dart DevTools timeline shows them by name
- [ ] A headless benchmark mode using `flutter test --machine` + `IntegrationTestWidgetsFlutterBinding.traceAction` that writes JSON results to `benchmarks/results/`
- [ ] Document baseline numbers from the unmodified fork in `docs/PERF_BUDGET.md`

**Acceptance criteria**
- Running `melos run benchmark` produces a JSON result and a human-readable summary.
- The 100k-word document baseline is recorded and committed. We expect it to be bad — that's the point. It becomes the floor we improve against.

**Why this week first:** without a benchmark, every future optimization is folklore. Phase 2's virtualization PRs must show a delta against these baseline numbers or they don't merge.

### Week 3 — Architecture audit + design doc

Now that the code builds and we can measure it, read it and write down what's there.

**Deliverables**
- [ ] `docs/ARCHITECTURE.md` covering:
  - Map of the current `Editor.execute` pipeline: `EditRequest → EditCommand → ChangeList → Reaction → Listener`
  - Catalog of every `DocumentNode` subclass, where it lives, and what `ComponentBuilder` renders it
  - Trace of the render path: `SuperEditor → SuperEditorViewport → SuperDocumentLayout → ComponentBuilders → SuperTextLayout`
  - Identified injection point for `SliverVariedExtentList` (Phase 2)
  - Identified injection point for `StepMap` emission from `EditCommand` (Phase 3)
  - Identified injection point for `DecorationSet` (Phase 3)
- [ ] One-page diagrams (Mermaid in markdown) for each
- [ ] Open-question log: things we don't yet know how to do (e.g., selection across off-screen blocks)

**Acceptance criteria**
- A new engineer reading `ARCHITECTURE.md` can locate, in the codebase, the exact file and line where each Phase 2/3 change will land.

### Week 4 — CI, perf regression gate, and Phase 2 kickoff prep

**Deliverables**
- [ ] `.github/workflows/ci.yaml` — runs `melos run analyze` + `melos run test` on every push
- [ ] `.github/workflows/benchmark.yaml` — runs benchmark on PRs touching `packages/homeric/lib/src/core/**` or `homeric_text_layout/**`; comments perf delta on the PR
- [ ] Goldens pipeline for visual regression (super_editor already has one — adapt it)
- [ ] Issue templates: bug, perf regression, design proposal
- [ ] `docs/ROADMAP.md` updated with concrete Phase 2 ticket list
- [ ] First Phase 2 spike: a throwaway PR that wraps the existing `SuperDocumentLayout` `Column` in a `CustomScrollView` with a non-virtualized `SliverList` — proves the migration is mechanically possible without changing rendering behavior. Merged only if benchmarks are within 5% of baseline.

**Acceptance criteria**
- CI is green on a fresh PR.
- The Phase 2 spike PR demonstrates the sliver migration path works.
- Phase 2 ticket list is ready to execute against.

---

## What Phase 1 is NOT

To stay focused:

- ❌ No virtualization (Phase 2)
- ❌ No `StepMap` (Phase 3)
- ❌ No `DecorationSet` (Phase 3)
- ❌ No footnotes, comments, backlinks (Phase 4)
- ❌ No Markdown extensions (Phase 4)
- ❌ No design system / theming work
- ❌ No public API stabilization — this is internal-only until Phase 5

The single hardest discipline in Phase 1 is *not building features*. Build the measuring stick first.

---

## Risks specific to Phase 1

| Risk | Severity | Mitigation |
|---|---|---|
| Rename break: super_editor's internal cross-references miss a `package:super_editor/...` import | Medium | Reproducible rename script; `melos run analyze` must be 0 errors before week 1 closes |
| Benchmark numbers vary too much across runs to detect regressions | Medium | Use `IntegrationTestWidgetsFlutterBinding.traceAction`; run on a fixed machine (Alvaro's M5 Max MBP); record p50/p95/p99 over 30 runs |
| super_editor upstream lands changes we conflict with mid-Phase | Low | Pin to `068a20d` (dev.51); track a separate `upstream` branch; merge upstream quarterly |
| Web fixture loads too slow / OOMs in best-effort mode | Low | Use Latin-only 100k fixture for Web baseline; document if CJK or huge fixtures crash |

---

## Phase 1 success definition

At the end of week 4:

1. `arodriguez47/homeric` exists, is clean, builds, tests pass on macOS/Windows/Linux/Android (Web nice-to-have).
2. A documented, reproducible benchmark proves super_editor's 100k-word performance is unacceptable and exactly *why* (Paragraph.layout time, widget count, frame jank).
3. The codebase is well-understood enough that Phase 2's virtualization work has a known landing site, file by file.
4. CI guards against regressions on both correctness and performance.

If all four hold, Phase 2 starts with maximum momentum.
