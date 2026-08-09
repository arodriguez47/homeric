/// Homeric playground entry point (U7): a runnable Flutter app rendering
/// documents through [HomericParagraph] and driving every Phase 1/2 editing
/// primitive by hand, importing only `package:homeric/homeric.dart`.
library;

import 'package:flutter/material.dart' hide Decoration;

import 'fixtures.dart';
import 'view_models/document_view_model.dart';
import 'views/decoration_panel.dart';
import 'views/editor_page.dart';
import 'views/transaction_panel.dart';

void main() {
  final document = buildFixtureDocument();
  final viewModel = DocumentViewModel(
    document: document,
    decorations: buildFixtureDecorations(document),
  );
  runApp(PlaygroundApp(viewModel: viewModel));
}

/// The playground's root widget.
class PlaygroundApp extends StatelessWidget {
  /// Creates the app over [viewModel].
  const PlaygroundApp({super.key, required this.viewModel});

  /// The single, app-wide document view-model.
  final DocumentViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Homeric Playground',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: Scaffold(
        appBar: AppBar(title: const Text('Homeric Playground')),
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(flex: 3, child: EditorPage(viewModel: viewModel)),
            const VerticalDivider(width: 1),
            SizedBox(
              width: 380,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TransactionPanel(viewModel: viewModel),
                    const Divider(height: 32),
                    DecorationPanel(viewModel: viewModel),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
