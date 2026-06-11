# Contributing to Homeric

## Setup

```bash
# Flutter 3.24+ and Dart 3.5+ required.
dart pub global activate melos
melos bootstrap
```

Then to validate:

```bash
melos run analyze
melos run test
melos run format-check
```

## Project phases

Homeric is in **Phase 1: Foundation**. The phase plan is in [`docs/PHASE_1_PLAN.md`](docs/PHASE_1_PLAN.md). Until Phase 2 begins, please **do not contribute feature PRs**. The most valuable contributions right now are:

1. Improving the 100k-word benchmark harness in `examples/benchmark_100k/`
2. Filing accurate baseline numbers across hardware in `docs/PERF_BUDGET.md`
3. Improving the architecture audit in `docs/ARCHITECTURE.md`

## Upstream relationship

Homeric is a fork of [super_editor](https://github.com/superlistapp/super_editor). We track upstream on a separate branch (`upstream`) and merge changes quarterly. When you change a file that originated upstream, the file header comment must reference the upstream path.

## Commit conventions

We follow [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` new functionality
- `fix:` bug fix
- `perf:` performance improvement (must include benchmark delta)
- `refactor:` no behavior change
- `docs:` documentation
- `chore:` tooling, deps
- `test:` tests only

For `perf:` commits, the PR description must include before/after numbers from `melos run benchmark`.

## Performance regressions

PRs that touch `packages/homeric/lib/src/core/**` or `packages/homeric_text_layout/**` automatically run the benchmark harness. A regression of more than 5% on any p95 metric blocks merge unless explicitly accepted in the PR description.

## Code style

`dart format` is enforced. Lint rules live in each package's `analysis_options.yaml`; we inherit from `package:flutter_lints` plus the super_editor-derived `flutter_test_runners` rules.
