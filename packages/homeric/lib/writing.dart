/// Optional writing features for Homeric editors.
///
/// Editing behaviour a host switches on per app, built only on the public
/// controller seams of `package:homeric/homeric.dart`: a
/// [HomericWritingKit] installs [HomericWritingFeature]s such as
/// [HomericSmartPunctuation] on a controller. The core library does not
/// export these types and no core module imports them.
library;

export 'src/writing/smart_punctuation.dart';
export 'src/writing/writing_feature.dart';
export 'src/writing/writing_kit.dart';
