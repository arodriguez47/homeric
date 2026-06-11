# Architecture Audit

> **Status: Phase 1 Week 3 placeholder.** This document is filled in during week 3 of Phase 1. It maps the inherited super_editor architecture and identifies the file-level injection points for Phase 2 (virtualization) and Phase 3 (StepMap, DecorationSet).

See [`ARCHITECTURE_DECISION.md`](ARCHITECTURE_DECISION.md) for the underlying decision and rationale.

## Sections to fill in

### 1. The edit pipeline

- Trace `Editor.execute(EditRequest)` from entry point to `Listener` notification.
- Catalog every built-in `EditCommand` subclass.
- Identify the exact line where each command would emit a `StepMap` (Phase 3).

### 2. Document model

- Every `DocumentNode` subclass with its serialization story.
- The relationship between `MutableDocument`, `DocumentComposer`, and `Editor`.

### 3. Rendering path

- `SuperEditor` widget → `SuperEditorViewport` → `SuperDocumentLayout` → `ComponentBuilders`.
- The exact widget where `Column` lives today. (This is the file we replace in Phase 2.)
- How `SelectionLayout` discovers components and how it must change when components are off-screen.

### 4. Text layout

- `super_text_layout` / `homeric_text_layout`'s relationship to Flutter's `RenderParagraph`.
- Where `Paragraph.layout()` is called — exactly. (Phase 2 needs `Timeline.startSync` here.)

### 5. Layer system

- How `DocumentLayerBuilder` works.
- Which built-in layers exist (selection, caret, drag handles).
- How a Phase 4 `CommentLayer` would slot in.

## Open questions

Tracked in `docs/OPEN_QUESTIONS.md` as we go.
