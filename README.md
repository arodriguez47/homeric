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

**Pre-alpha. Not yet usable.** Phase 1 (document model, positions, StepMap, DecorationSet) is in progress — plan at [`docs/plans/`](docs/plans/), phases tracked in Linear (team Homeric) and mirrored in [`docs/ROADMAP.md`](docs/ROADMAP.md).

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
│       └── examples/
│           └── playground/         # interactive editing-primitives demo app
├── tools/
│   └── corpus/                     # generated long-form text fixtures for benchmarks
├── benchmarks/                     # benchmark baselines and results
└── docs/
    ├── ROADMAP.md
    ├── PERF_BUDGET.md
    └── plans/                      # implementation plans (ce-plan)
```

## Getting started

```bash
# Once you have Flutter 3.24+ and Dart 3.5+ installed:
dart pub global activate melos
melos bootstrap
melos run analyze
melos run test
```

### Run the playground

`packages/homeric/examples/playground` is a runnable Flutter app built around
one `HomericEditableDocument`. Its lazily mounted paragraphs share one
experimental `HomericEditorController` and `HomericTextInputSession`, so
keyboard, pointer, composition, cross-block selection, structural editing,
decorations, and undo/redo all observe the same canonical state. Every row has
an accessible `⋮` grabber; on macOS, `Cmd+Shift+Up/Down` moves the focused
block through the same controller command. The Phase 1 transaction controls
remain available for inspecting the pipeline by hand.

This combines the macOS-first [HOM-18](https://linear.app/xana-studios/issue/HOM-18)
editing foundation with the multi-block viewport from
[HOM-6](https://linear.app/xana-studios/issue/HOM-6). Automated playground and
profile-benchmark coverage are in place; real macOS acceptance and
Windows/Linux certification are not claimed here. Touch selection remains
[HOM-20](https://linear.app/xana-studios/issue/HOM-20), and cross-platform IME
certification remains [HOM-21](https://linear.app/xana-studios/issue/HOM-21).

```bash
cd packages/homeric/examples/playground
flutter pub get
flutter run -d macos
```

## License

[MIT](LICENSE).

The `StepMap` and `DecorationSet` designs are inspired by [ProseMirror](https://prosemirror.net) (MIT, © Marijn Haverbeke and contributors). Where Homeric ports a ProseMirror algorithm verbatim, the file header cites the specific upstream file and commit.
