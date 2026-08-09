/// Homeric: a Flutter editor library for long-form writing.
///
/// Built from fundamentals in pure Dart around three primitives:
/// `StepMap` position mapping, `DecorationSet` range overlays, and
/// (from Phase 2) virtualized rendering. See docs/ROADMAP.md.
library homeric;

export 'src/decoration/decoration.dart';
export 'src/decoration/decoration_set.dart';
export 'src/model/attributes.dart';
export 'src/model/block.dart';
export 'src/model/document.dart';
export 'src/model/inline_run.dart';
export 'src/model/position.dart';
export 'src/render/homeric_paragraph.dart';
export 'src/render/paragraph_source.dart';
export 'src/transform/attr_step.dart';
export 'src/transform/builders.dart';
export 'src/transform/change_list.dart';
export 'src/transform/mapping.dart';
export 'src/transform/replace_step.dart';
export 'src/transform/step.dart';
export 'src/transform/step_map.dart';
export 'src/transform/transaction.dart';
export 'src/view/view_map.dart';
export 'src/view/view_text.dart';
