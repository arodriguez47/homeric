// Homeric playground — minimal SuperEditor smoke test.
//
// `flutter run -d macos`

import 'package:flutter/material.dart';
import 'package:homeric/homeric.dart';

void main() => runApp(const PlaygroundApp());

class PlaygroundApp extends StatelessWidget {
  const PlaygroundApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Homeric Playground',
      home: const PlaygroundScreen(),
    );
  }
}

class PlaygroundScreen extends StatefulWidget {
  const PlaygroundScreen({super.key});

  @override
  State<PlaygroundScreen> createState() => _PlaygroundScreenState();
}

class _PlaygroundScreenState extends State<PlaygroundScreen> {
  late final Editor _editor;

  @override
  void initState() {
    super.initState();
    final doc = MutableDocument(nodes: [
      ParagraphNode(
        id: Editor.createNodeId(),
        text: AttributedText('Welcome to Homeric.'),
      ),
      ParagraphNode(
        id: Editor.createNodeId(),
        text: AttributedText('Type here. This is the forked super_editor.'),
      ),
    ]);
    _editor = createDefaultDocumentEditor(
      document: doc,
      composer: MutableDocumentComposer(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Homeric · playground')),
      body: SuperEditor(editor: _editor),
    );
  }
}
