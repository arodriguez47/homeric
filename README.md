# Homeric

> A Flutter editor library for long-form writing.

Homeric is a Flutter rich-text editor library targeting **Ulysses-class writing UX** with **Tiptap-class extensibility**. It is built for documents that are anywhere from atomic, short notes to 100,000+ words long, with first-class support for footnotes, inline comments, annotations, backlinks, writing goals, and visual diff between versions.

Homeric is **built from scratch in pure Dart and Flutter** — it is not a fork of an existing editor, and it embeds no ProseMirror or CodeMirror. Three primitives carry everything:

1. **Viewport virtualization** — only visible blocks pay the cost of `Paragraph.layout()`. The single most important thing for large-document performance.
2. **`StepMap` position mapping** — ProseMirror's transaction-position-mapping idea, implemented natively in Dart. Every edit emits a map; comment anchors, footnote back-references, and version diffs all survive arbitrary surrounding edits.
3. **`DecorationSet`** — non-destructive range overlays that map through `StepMap`s. Comments, search highlights, diff insertions, and spell-check are all decorations rather than content edits.

Everything else (footnotes, comments, backlinks, writing goals, diff view) composes on top of those three primitives.

See [`STRATEGY.md`](STRATEGY.md) for the strategy this serves.

## Status

**Pre-alpha. Not yet usable.** The from-scratch core is being planned; see [`docs/ROADMAP.md`](docs/ROADMAP.md).

## Platforms

| Platform | v1 support |
|---|---|
| macOS | ✅ |
| Windows | ✅ |
| Linux | ✅ |
| Android | ✅ |
| Web (Latin-script) | ⚠️ Best-effort. CJK IME blocked by [flutter/flutter#120613](https://github.com/flutter/flutter/issues/120613). |
| iOS | ❌ Not in v1. |

## Repository layout

```
homeric/
├── packages/
│   └── homeric/                    # the editor library (from scratch)
├── tools/
│   └── corpus/                     # generated long-form text fixtures for benchmarks
├── benchmarks/                     # benchmark baselines and results
└── docs/
    ├── ROADMAP.md
    └── PERF_BUDGET.md
```

## Getting started

```bash
# Once you have Flutter 3.24+ and Dart 3.5+ installed:
dart pub global activate melos
melos bootstrap
melos run analyze
melos run test
```

## License

[MIT](LICENSE).

The `StepMap` and `DecorationSet` designs are inspired by [ProseMirror](https://prosemirror.net) (MIT, © Marijn Haverbeke and contributors). Where Homeric ports a ProseMirror algorithm verbatim, the file header cites the specific upstream file and commit.
