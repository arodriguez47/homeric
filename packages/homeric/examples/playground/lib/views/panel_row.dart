/// A horizontally-scrollable row for the playground's form panels
/// ([DecorationPanel], [TransactionPanel]): both wrap their fixed-width
/// number fields and buttons in exactly this shape, so it lives here once
/// rather than as a private per-panel copy.
///
/// Wrapped in a horizontal scroll view rather than relying on `Expanded`
/// everywhere: some rows mix fixed-width number fields with buttons whose
/// label text length depends on the platform, and each panel is a
/// fixed-width sidebar — scrolling a row instead of overflowing it keeps
/// every control reachable regardless of window width.
library;

import 'package:flutter/material.dart';

/// One horizontally-scrollable row of form controls.
class PanelRow extends StatelessWidget {
  /// Creates a row over [children].
  const PanelRow(this.children, {super.key});

  /// The row's controls, in order.
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: children),
        ),
      );
}
