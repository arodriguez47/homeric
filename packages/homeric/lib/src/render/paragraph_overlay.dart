part of 'homeric_paragraph.dart';

/// Builds presentation chosen by the consumer from current paragraph
/// geometry.
///
/// Return [Positioned] children when placing individual marks. The returned
/// widgets are hosted in a fixed overlay plane, so even a non-positioned child
/// cannot change the paragraph's constraints or create a relayout loop.
typedef ParagraphOverlayBuilder = List<Widget> Function(
  BuildContext context,
  ParagraphGeometry geometry,
);

/// Renders one [HomericParagraph] with a layout-neutral geometry overlay.
///
/// This packages the subscription every geometry-derived consumer otherwise
/// has to hand-roll: the first overlay appears after the paragraph's first
/// layout, and a fresh [ParagraphGeometry] is delivered after each relayout.
/// The overlay decides what to paint and whether it handles pointer input;
/// this widget supplies placement only and carries no footnote, annotation,
/// caret, or other presentation semantics.
///
/// The interaction plane is exactly the paragraph's bounds. With
/// [clipBehavior] set to [Clip.none], presentation may paint outside those
/// bounds, but Flutter does not hit-test a render box outside its own size.
/// Interactive margin UI must stay inside the paragraph bounds or use an
/// editor-level [OverlayPortal] with coordinate conversion.
///
/// Geometry results remain generation-stamped. An asynchronous consumer that
/// holds one can check [GeometryResult.isStale] before applying its response.
///
/// The paragraph is the only non-positioned child of the outer [Stack]. The
/// overlay is hosted inside [Positioned.fill], which structurally prevents
/// overlay content from feeding back into paragraph layout.
class ParagraphOverlay extends StatefulWidget {
  /// Creates a paragraph plus its geometry-derived overlay plane.
  const ParagraphOverlay({
    super.key,
    required this.paragraph,
    required this.slotLayoutRevision,
    required this.overlayBuilder,
    this.clipBehavior = Clip.none,
    this.excludeParagraphSemantics = false,
  });

  /// The paragraph this widget observes and places overlays over.
  ///
  /// Its key and every constructor input are preserved. If it already has an
  /// [HomericParagraph.onGeometryChanged] callback, that callback is composed
  /// with this widget's internal observer rather than replaced.
  final HomericParagraph paragraph;

  /// Additional value-equal revision for geometry-affecting state owned by
  /// [HomericParagraph.slotBuilder] rather than [HomericParagraph.source].
  ///
  /// Pass `null` when there are no slot children, or when every slot child's
  /// measured size is completely determined by [HomericParagraph.source] and
  /// the paragraph's other constructor inputs. Otherwise change this value
  /// whenever a slot child can measure differently (for example after a chip
  /// expands). Requiring an explicit nullable value makes that choice visible
  /// at every call site instead of silently assuming slot geometry is static.
  final Object? slotLayoutRevision;

  /// Builds the widgets placed over the current paragraph geometry.
  final ParagraphOverlayBuilder overlayBuilder;

  /// How the outer paragraph-and-overlay stack clips its contents.
  ///
  /// [Clip.none] permits visual overflow; it does not expand the hit-test
  /// bounds described on this class.
  final Clip clipBehavior;

  /// Whether the paragraph's own semantics are replaced by an owning host.
  ///
  /// Geometry-derived overlay semantics remain visible. Editable hosts use
  /// this to expose one text-field node plus consumer actions without also
  /// exposing the read-only paragraph text a second time.
  final bool excludeParagraphSemantics;

  @override
  State<ParagraphOverlay> createState() => _ParagraphOverlayState();
}

class _ParagraphOverlayState extends State<ParagraphOverlay> {
  RenderHomericParagraph? _paragraph;
  int? _generation;
  Key? _paragraphKey;
  Object? _slotLayoutRevision;
  bool _slotCatchUpScheduled = false;
  ({
    RenderHomericParagraph paragraph,
    int generation,
    Key? paragraphKey,
    Object? slotLayoutRevision,
  })? _pendingSlotCatchUp;
  bool _publicCatchUpPending = false;

  @override
  void didUpdateWidget(ParagraphOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.paragraph.onGeometryChanged != null &&
        widget.paragraph.onGeometryChanged == null) {
      _publicCatchUpPending = false;
    }
    if (oldWidget.paragraph.onGeometryChanged == null &&
        widget.paragraph.onGeometryChanged != null) {
      _publicCatchUpPending = true;
      _schedulePublicCallbackCatchUp();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final paragraph = _paragraph;
        final generation = _generation;
        final paragraphWidget = widget.paragraph;
        final currentExceptForSlotRevision = paragraph != null &&
            generation != null &&
            _paragraphKey == paragraphWidget.key &&
            _matchesCurrentLayout(
                context, constraints, paragraph, paragraphWidget) &&
            paragraph.layoutGeneration == generation;
        if (currentExceptForSlotRevision &&
            _slotLayoutRevision != widget.slotLayoutRevision) {
          _scheduleSlotRevisionCatchUp(
            paragraph,
            generation,
            paragraphWidget.key,
            widget.slotLayoutRevision,
          );
        }
        final geometry = currentExceptForSlotRevision &&
                _slotLayoutRevision == widget.slotLayoutRevision
            ? ParagraphGeometry(paragraph)
            : null;

        return Stack(
          fit: StackFit.passthrough,
          clipBehavior: widget.clipBehavior,
          children: <Widget>[
            if (widget.excludeParagraphSemantics)
              ExcludeSemantics(
                child: paragraphWidget._observedBy(_handleGeometryChanged),
              )
            else
              paragraphWidget._observedBy(_handleGeometryChanged),
            if (geometry != null)
              Positioned.fill(
                child: Stack(
                  fit: StackFit.expand,
                  clipBehavior: Clip.none,
                  children: widget.overlayBuilder(context, geometry),
                ),
              ),
          ],
        );
      },
    );
  }

  bool _matchesCurrentLayout(
    BuildContext context,
    BoxConstraints constraints,
    RenderHomericParagraph paragraph,
    HomericParagraph paragraphWidget,
  ) {
    return paragraph.hasCurrentGeometry &&
        paragraph.constraints == constraints &&
        RenderHomericParagraph._paragraphSourceEquals(
            paragraph.source, paragraphWidget.source) &&
        paragraph.baseStyle == paragraphWidget.baseStyle &&
        paragraph.textAlign == paragraphWidget.textAlign &&
        paragraph.textScaler == paragraphWidget._resolveTextScaler(context) &&
        paragraph.slotAlignment == paragraphWidget.slotAlignment &&
        paragraph.slotBaseline == paragraphWidget.slotBaseline;
  }

  void _handleGeometryChanged(
    RenderHomericParagraph paragraph,
    int generation,
  ) {
    if (mounted &&
        (!identical(_paragraph, paragraph) ||
            _generation != generation ||
            _paragraphKey != widget.paragraph.key ||
            _slotLayoutRevision != widget.slotLayoutRevision)) {
      setState(() {
        _paragraph = paragraph;
        _generation = generation;
        _paragraphKey = widget.paragraph.key;
        _slotLayoutRevision = widget.slotLayoutRevision;
      });
    }
    _notifyPublicCallback(paragraph, generation);
  }

  void _scheduleSlotRevisionCatchUp(
    RenderHomericParagraph paragraph,
    int generation,
    Key? paragraphKey,
    Object? slotLayoutRevision,
  ) {
    _pendingSlotCatchUp = (
      paragraph: paragraph,
      generation: generation,
      paragraphKey: paragraphKey,
      slotLayoutRevision: slotLayoutRevision,
    );
    if (_slotCatchUpScheduled) {
      return;
    }
    _slotCatchUpScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _slotCatchUpScheduled = false;
      final pending = _pendingSlotCatchUp;
      if (!mounted ||
          pending == null ||
          !identical(_paragraph, pending.paragraph) ||
          widget.paragraph.key != pending.paragraphKey ||
          widget.slotLayoutRevision != pending.slotLayoutRevision ||
          !pending.paragraph.hasCurrentGeometry ||
          pending.paragraph.layoutGeneration != pending.generation) {
        return;
      }
      setState(() => _slotLayoutRevision = pending.slotLayoutRevision);
      if (_publicCatchUpPending) {
        _schedulePublicCallbackCatchUp();
      }
    });
  }

  void _schedulePublicCallbackCatchUp() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final callback = widget.paragraph.onGeometryChanged;
      final paragraph = _paragraph;
      final generation = _generation;
      if (!mounted ||
          !_publicCatchUpPending ||
          callback == null ||
          paragraph == null ||
          generation == null ||
          _paragraphKey != widget.paragraph.key ||
          _slotLayoutRevision != widget.slotLayoutRevision ||
          !paragraph.hasCurrentGeometry ||
          paragraph.layoutGeneration != generation ||
          !_matchesCurrentLayout(
              context, paragraph.constraints, paragraph, widget.paragraph)) {
        return;
      }
      _notifyPublicCallback(paragraph, generation);
    });
  }

  void _notifyPublicCallback(
    RenderHomericParagraph paragraph,
    int generation,
  ) {
    final callback = widget.paragraph.onGeometryChanged;
    if (callback == null) {
      return;
    }
    _publicCatchUpPending = false;
    callback(paragraph, generation);
  }
}
