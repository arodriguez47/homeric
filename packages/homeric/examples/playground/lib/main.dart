/// Homeric playground entry point: a runnable Flutter app editing every block
/// through the public experimental controller, input session, and editable
/// paragraph APIs while retaining the Phase 1/2 debug controls.
library;

import 'package:flutter/material.dart' hide Decoration;

import 'fixtures.dart';
import 'view_models/document_view_model.dart';
import 'views/decoration_panel.dart';
import 'views/editor_page.dart';
import 'views/transaction_panel.dart';

void main() {
  final document = buildTouchFixtureDocument();
  final viewModel = DocumentViewModel(
    document: document,
    decorations: buildTouchFixtureDecorations(document),
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
      home: LayoutBuilder(
        builder: (context, constraints) => Scaffold(
          appBar: AppBar(title: const Text('Homeric Playground')),
          body: constraints.maxWidth < 800
              ? EditorPage(viewModel: viewModel)
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 3,
                      child: EditorPage(viewModel: viewModel),
                    ),
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
      ),
    );
  }
}
