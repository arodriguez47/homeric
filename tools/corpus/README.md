# Corpus

Byte-deterministic synthetic Markdown fixtures used by the benchmark harness.

## Regenerating

```bash
dart run tools/corpus/generate.dart
```

Outputs `tools/corpus/out/{tiny,small,medium,large,xl}.md`. The
repository-owned PRNG is seeded per file, so supported Dart runtimes produce
byte-identical fixtures.

The generator does not use Dart's platform `Random` implementation or
`String.hashCode`. Its versioned 32-bit arithmetic, literal seeds, exact word
counts, and expected FNV-1a byte hashes are repository contracts. The current
manifest is committed in [`hashes.json`](hashes.json); generated fixture bodies
remain ignored.

Use `--output-dir <directory>` for isolated comparison runs. This does not
rewrite the repository manifest. A widget regression runs the generator in two
clean Dart processes and independently pins every manifest hash.

The corpus is intentionally synthetic. It is not Project Gutenberg prose and
does not claim to model natural-language word-length distributions. A future
realistic corpus may complement these fixtures, but must not silently replace
the stable synthetic performance contract.
