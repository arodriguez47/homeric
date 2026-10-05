/// Optional margin annotations for Homeric documents.
///
/// A presentation module built only on the document geometry capability of
/// `package:homeric/homeric.dart`: [HomericMarginLayer] places host notes
/// beside an editable document, and [solveMarginLayout] with
/// [MarginLayoutMemory] decides where each note sits. The core library does
/// not export these types and no core module imports them.
library;

export 'src/margin/margin_layer.dart';
export 'src/margin/margin_layout_memory.dart';
export 'src/margin/margin_layout_solver.dart';
