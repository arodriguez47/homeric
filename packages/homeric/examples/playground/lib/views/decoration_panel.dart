/// The decoration panel: hide-delimiters toggle, mention/annotation paint
/// layer demos, and widget-chip insertion (R8) — every button calls
/// exactly one [DocumentViewModel] decoration command.
library;

import 'package:flutter/material.dart' hide Decoration;

import '../view_models/document_view_model.dart';
import 'panel_row.dart';

/// Buttons/fields driving [DocumentViewModel]'s decoration commands.
class DecorationPanel extends StatefulWidget {
  /// Creates the panel over [viewModel].
  const DecorationPanel({super.key, required this.viewModel});

  /// The document view-model the panel's commands run against.
  final DocumentViewModel viewModel;

  @override
  State<DecorationPanel> createState() => _DecorationPanelState();
}

class _DecorationPanelState extends State<DecorationPanel> {
  final _hideBlockId = TextEditingController(text: 'intro');
  final _washBlockId = TextEditingController(text: 'intro');
  final _washFrom = TextEditingController(text: '0');
  final _washTo = TextEditingController(text: '4');
  final _underlineBlockId = TextEditingController(text: 'intro');
  final _underlineFrom = TextEditingController(text: '0');
  final _underlineTo = TextEditingController(text: '4');
  final _chipBlockId = TextEditingController(text: 'notes');
  final _chipOffset = TextEditingController(text: '0');
  final _chipLabel = TextEditingController(text: '📎');

  @override
  void dispose() {
    _hideBlockId.dispose();
    _washBlockId.dispose();
    _washFrom.dispose();
    _washTo.dispose();
    _underlineBlockId.dispose();
    _underlineFrom.dispose();
    _underlineTo.dispose();
    _chipBlockId.dispose();
    _chipOffset.dispose();
    _chipLabel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Decorations', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text('Reveal-on-selection (R10): tap the caret inside a '
                'hidden ** or %% run to see it reveal.'),
            const SizedBox(height: 12),
            PanelRow([
              SizedBox(
                  width: 160,
                  child: TextField(
                      controller: _hideBlockId,
                      decoration: const InputDecoration(labelText: 'blockId'))),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () =>
                    widget.viewModel.toggleHideDelimiters(_hideBlockId.text),
                child: Text(
                    widget.viewModel.isHidingDelimiters(_hideBlockId.text)
                        ? 'Show delimiters'
                        : 'Hide delimiters (**/%%)'),
              ),
            ]),
            const Divider(height: 24),
            Text('Mention wash (underlay)',
                style: Theme.of(context).textTheme.labelLarge),
            PanelRow([
              SizedBox(
                  width: 160,
                  child: TextField(
                      controller: _washBlockId,
                      decoration: const InputDecoration(labelText: 'blockId'))),
              const SizedBox(width: 8),
              SizedBox(
                  width: 56,
                  child: TextField(
                      controller: _washFrom,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'from'))),
              const SizedBox(width: 8),
              SizedBox(
                  width: 56,
                  child: TextField(
                      controller: _washTo,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'to'))),
            ]),
            PanelRow([
              FilledButton(
                onPressed: () {
                  final from = int.tryParse(_washFrom.text);
                  final to = int.tryParse(_washTo.text);
                  if (from == null || to == null) return;
                  widget.viewModel.addMentionWash(_washBlockId.text, from, to);
                },
                child: const Text('Add mention wash'),
              ),
            ]),
            const Divider(height: 24),
            Text('Annotation underline (overlay)',
                style: Theme.of(context).textTheme.labelLarge),
            PanelRow([
              SizedBox(
                  width: 160,
                  child: TextField(
                      controller: _underlineBlockId,
                      decoration: const InputDecoration(labelText: 'blockId'))),
              const SizedBox(width: 8),
              SizedBox(
                  width: 56,
                  child: TextField(
                      controller: _underlineFrom,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'from'))),
              const SizedBox(width: 8),
              SizedBox(
                  width: 56,
                  child: TextField(
                      controller: _underlineTo,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'to'))),
            ]),
            PanelRow([
              FilledButton(
                onPressed: () {
                  final from = int.tryParse(_underlineFrom.text);
                  final to = int.tryParse(_underlineTo.text);
                  if (from == null || to == null) return;
                  widget.viewModel
                      .addAnnotationUnderline(_underlineBlockId.text, from, to);
                },
                child: const Text('Add annotation underline'),
              ),
            ]),
            const Divider(height: 24),
            Text('Widget chip', style: Theme.of(context).textTheme.labelLarge),
            PanelRow([
              SizedBox(
                  width: 160,
                  child: TextField(
                      controller: _chipBlockId,
                      decoration: const InputDecoration(labelText: 'blockId'))),
              const SizedBox(width: 8),
              SizedBox(
                  width: 56,
                  child: TextField(
                      controller: _chipOffset,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'offset'))),
              const SizedBox(width: 8),
              SizedBox(
                  width: 56,
                  child: TextField(
                      controller: _chipLabel,
                      decoration: const InputDecoration(labelText: 'label'))),
            ]),
            PanelRow([
              FilledButton(
                onPressed: () {
                  final offset = int.tryParse(_chipOffset.text);
                  if (offset == null) return;
                  widget.viewModel.insertWidgetChip(_chipBlockId.text, offset,
                      label: _chipLabel.text);
                },
                child: const Text('Insert widget chip'),
              ),
            ]),
          ],
        );
      },
    );
  }
}
