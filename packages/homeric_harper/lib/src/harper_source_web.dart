import 'package:homeric/homeric.dart';

/// The English Harper checks against.
enum HarperDialect { american, british, australian, canadian, indian }

/// Harper does not run on the web build yet: every check finds nothing.
class HarperProofingSource implements HomericProofingSource {
  HarperProofingSource({this.dialect = HarperDialect.american});

  /// Whether Harper can run on this platform: not on the web.
  static bool get isSupported => false;

  final HarperDialect dialect;

  Future<void> warmUp() async {}

  @override
  Future<List<HomericProofingIssue>> check(String text) async => const [];
}
