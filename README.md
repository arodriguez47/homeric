# Homeric

> A Flutter editor library for long-form writing.

Homeric is a Flutter rich-text editor library targeting **Ulysses-class writing UX** with **Tiptap-class extensibility**. It is built for documents that are anywhere from atomic, short notes to 100,000+ words long, with first-class support for footnotes, inline comments, annotations, backlinks, writing goals, and visual diff between versions.

It is a **fork of [super_editor](https://github.com/superlistapp/super_editor) `0.3.0-dev.51`** with three architectural additions the upstream library does not provide:

1. **Viewport virtualization** — only visible blocks pay the cost of `Paragraph.layout()`. The single most important thing for large-document performance.
2. **`StepMap` position mapping** — ProseMirror's transaction-position-mapping idea, ported to Dart. Every edit emits a map; comment anchors, footnote back-references, and version diffs all survive arbitrary surrounding edits.
3. **`DecorationSet`** — non-destructive range overlays that map through `StepMap`s. Comments, search highlights, diff insertions, and spell-check are all decorations rather than content edits.

Everything else (footnotes, comments, backlinks, writing goals, diff view) composes on top of those three primitives.

## Status

**Phase 1: Foundation.** Not yet usable. See [`docs/ROADMAP.md`](docs/ROADMAP.md) and [`docs/PHASE_1_PLAN.md`](docs/PHASE_1_PLAN.md).

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
│   ├── homeric/                    # core editor (forked super_editor)
│   ├── homeric_text_layout/        # text layout primitives (forked super_text_layout)
│   ├── homeric_attributed_text/    # span-based attributed text (forked attributed_text)
│   └── homeric_markdown/           # markdown ser/de (forked super_editor_markdown)
├── examples/
│   ├── benchmark_100k/             # the 100k-word perf harness
│   └── playground/                 # editor smoke test
├── tools/
│   ├── corpus/                     # generated text fixtures
│   └── rename.sh                   # reproducible super_editor → homeric rename
└── docs/
    ├── PHASE_1_PLAN.md
    ├── ROADMAP.md
    ├── ARCHITECTURE.md
    └── PERF_BUDGET.md
```

## Getting started

```bash
# Once you have Flutter 3.24+ and Dart 3.5+ installed:
dart pub global activate melos
melos bootstrap
melos run analyze
melos run test
melos run benchmark   # runs the 100k-word perf harness
```

## License

[MIT](LICENSE). Homeric incorporates code from [super_editor](https://github.com/superlistapp/super_editor) by Superlist GmbH, also MIT-licensed. See [NOTICE](NOTICE) for full attribution.

The `StepMap` and `DecorationSet` designs are ported from [ProseMirror](https://prosemirror.net) (MIT, © Marijn Haverbeke and contributors).
