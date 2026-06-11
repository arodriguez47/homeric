# Corpus

Deterministic Markdown fixtures used by the benchmark harness.

## Regenerating

```bash
dart run tools/corpus/generate.dart
```

Outputs `tools/corpus/out/{tiny,small,medium,large,xl}.md`. The PRNG is seeded per-file so the same Dart version produces byte-identical fixtures.

The `out/` directory is gitignored — fixtures are regenerated on demand.

## Phase 1 Week 2 TODO

Replace the in-file lexicon with a small set of public-domain Project Gutenberg texts so line-break behavior is realistic and reflects natural word-length distributions.
