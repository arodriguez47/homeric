/// Homeric: a Flutter editor library for long-form writing.
///
/// Built from fundamentals in pure Dart around three primitives:
/// `StepMap` position mapping, `DecorationSet` range overlays, and
/// (from Phase 2) virtualized rendering. See docs/ROADMAP.md.
library homeric;

export 'src/model/attributes.dart';
export 'src/model/block.dart';
export 'src/model/document.dart';
export 'src/model/inline_run.dart';
export 'src/model/position.dart';
export 'src/transform/mapping.dart';
export 'src/transform/step_map.dart';
