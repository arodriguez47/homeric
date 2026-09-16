# Contributing to Homeric

## Setup

```bash
# Flutter 3.47.2+ and Dart 3.5+ required.
dart pub global activate melos
melos bootstrap
```

Then to validate:

```bash
melos run analyze
melos run test
melos run format-check
```

## Project status

Homeric is being built **from scratch** and is pre-alpha. Until the core primitives land, please **do not contribute feature PRs**. The most valuable contributions right now are:

1. Improving the corpus generator in `tools/corpus/`
2. Design feedback on the primitives (StepMap, DecorationSet, virtualization) via design-proposal issues

## Commit conventions

We follow [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` new functionality
- `fix:` bug fix
- `perf:` performance improvement (must include benchmark delta)
- `refactor:` no behavior change
- `docs:` documentation
- `chore:` tooling, deps
- `test:` tests only

Once the benchmark harness exists, `perf:` PRs must include before/after numbers from it.

## Performance regressions

Once the benchmark harness is rebuilt, PRs touching the editor core will run it automatically; a regression of more than 5% on any p95 metric blocks merge unless explicitly accepted in the PR description. See [`docs/PERF_BUDGET.md`](docs/PERF_BUDGET.md).

## Code style

`dart format` is enforced. Lint rules live in each package's `analysis_options.yaml`; we inherit from `package:flutter_lints`.
