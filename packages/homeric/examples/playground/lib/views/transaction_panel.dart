/// The transaction panel: a form driving every Phase 1 transaction builder
/// against the live document (R8). Every button calls exactly one
/// [DocumentViewModel] command; this widget owns no document state of its
/// own beyond the form's text controllers.
library;

import 'package:flutter/material.dart' hide Decoration;

import '../view_models/document_view_model.dart';
import 'panel_row.dart';

/// Buttons/fields driving [DocumentViewModel]'s builder commands.
class TransactionPanel extends StatefulWidget {
  /// Creates the panel over [viewModel].
  const TransactionPanel({super.key, required this.viewModel});

  /// The document view-model the panel's commands run against.
  final DocumentViewModel viewModel;

  @override
  State<TransactionPanel> createState() => _TransactionPanelState();
}

class _TransactionPanelState extends State<TransactionPanel> {
  final _insertText = TextEditingController(text: 'hello ');
  final _deleteCount = TextEditingController(text: '1');
  final _blockId = TextEditingController(text: 'notes');
  final _blockType = TextEditingController(text: 'heading');
  final _markFrom = TextEditingController();
  final _markTo = TextEditingController();
  final _markKey = TextEditingController(text: 'bold');

  @override
  void dispose() {
    _insertText.dispose();
    _deleteCount.dispose();
    _blockId.dispose();
    _blockType.dispose();
    _markFrom.dispose();
    _markTo.dispose();
    _markKey.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final caret = widget.viewModel.caret;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Transactions',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(caret == null
                ? 'Caret: none (tap a paragraph)'
                : 'Caret: $caret  ·  doc size: ${widget.viewModel.document.size}'),
            const SizedBox(height: 12),
            PanelRow([
              SizedBox(
                  width: 160,
                  child: TextField(
                      controller: _insertText,
                      decoration: const InputDecoration(labelText: 'text'))),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () =>
                    widget.viewModel.insertTextAtCaret(_insertText.text),
                child: const Text('insertText @ caret'),
              ),
            ]),
            PanelRow([
              SizedBox(
                width: 72,
                child: TextField(
                  controller: _deleteCount,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'count'),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () {
                  final count = int.tryParse(_deleteCount.text) ?? 0;
                  widget.viewModel.deleteBackwardFromCaret(count);
                },
                child: const Text('deleteRange (backspace @ caret)'),
              ),
            ]),
            PanelRow([
              FilledButton(
                onPressed: () => widget.viewModel.splitAtCaret(),
                child: const Text('splitBlock @ caret'),
              ),
            ]),
            const Divider(height: 24),
            PanelRow([
              SizedBox(
                  width: 160,
                  child: TextField(
                      controller: _blockId,
                      decoration: const InputDecoration(labelText: 'blockId'))),
            ]),
            PanelRow([
              FilledButton(
                onPressed: () =>
                    widget.viewModel.joinBlockWithNext(_blockId.text),
                child: const Text('joinBlocks (with next)'),
              ),
            ]),
            PanelRow([
              OutlinedButton(
                onPressed: () => widget.viewModel.moveBlockUp(_blockId.text),
                child: const Text('moveBlock ↑'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => widget.viewModel.moveBlockDown(_blockId.text),
                child: const Text('moveBlock ↓'),
              ),
            ]),
            PanelRow([
              SizedBox(
                  width: 160,
                  child: TextField(
                      controller: _blockType,
                      decoration: const InputDecoration(labelText: 'type'))),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => widget.viewModel
                    .setBlockType(_blockId.text, _blockType.text),
                child: const Text('setBlockType'),
              ),
            ]),
            const Divider(height: 24),
            Text('toggleMark', style: Theme.of(context).textTheme.labelLarge),
            PanelRow([
              SizedBox(
                  width: 64,
                  child: TextField(
                      controller: _markFrom,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'from'))),
              const SizedBox(width: 8),
              SizedBox(
                  width: 64,
                  child: TextField(
                      controller: _markTo,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'to'))),
              const SizedBox(width: 8),
              SizedBox(
                  width: 160,
                  child: TextField(
                      controller: _markKey,
                      decoration: const InputDecoration(labelText: 'key'))),
            ]),
            PanelRow([
              FilledButton(
                onPressed: () {
                  final from = int.tryParse(_markFrom.text);
                  final to = int.tryParse(_markTo.text);
                  if (from == null || to == null) return;
                  widget.viewModel.toggleMark(from, to, _markKey.text, true);
                },
                child: const Text('toggleMark [from, to)'),
              ),
            ]),
            const Divider(height: 24),
            PanelRow([
              OutlinedButton.icon(
                key: const ValueKey<String>('transaction-undo'),
                onPressed:
                    widget.viewModel.canUndo ? widget.viewModel.undoLast : null,
                icon: const Icon(Icons.undo),
                label: const Text('Undo'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                key: const ValueKey<String>('transaction-redo'),
                onPressed:
                    widget.viewModel.canRedo ? widget.viewModel.redoLast : null,
                icon: const Icon(Icons.redo),
                label: const Text('Redo'),
              ),
            ]),
          ],
        );
      },
    );
  }
}
