/// Homeric: a Flutter editor library for long-form writing.
///
/// Built from fundamentals in pure Dart around three primitives:
/// `StepMap` position mapping, `DecorationSet` range overlays, and
/// (from Phase 2) virtualized rendering. See docs/ROADMAP.md.
library homeric;

export 'src/decoration/decoration.dart';
export 'src/decoration/decoration_set.dart';
export 'src/decoration/markdown_mark_visibility.dart';
export 'src/editing/editor_controller.dart';
export 'src/editing/editable_document.dart'
    hide homericPhysicalSelectionEndpoint;
export 'src/editing/spell_check.dart'
    show HomericSpellCheckProvider, HomericSpellCheckRequest;
export 'src/editing/editor_clipboard.dart'
    show
        HomericClipboardAdapter,
        HomericClipboardFailure,
        HomericClipboardOperation,
        HomericHostEvent,
        HomericPasteRejected,
        SystemHomericClipboard;
export 'src/editing/editable_paragraph.dart';
export 'src/editing/markdown_list_indent.dart';

export 'src/input/macos_history_bridge.dart';
export 'src/input/text_input_session.dart';
export 'src/model/attributes.dart';
export 'src/model/block.dart';
export 'src/model/document.dart';
export 'src/model/inline_run.dart';
export 'src/model/position.dart';
export 'src/model/selection.dart';
export 'src/render/homeric_paragraph.dart'
    hide HomericParagraphLayoutCache, HomericParagraphLayoutCacheScope;
export 'src/render/paint_layers.dart';
export 'src/render/paragraph_layout_instrumentation.dart';
export 'src/render/paragraph_geometry.dart';
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
