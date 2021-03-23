import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:swayze_math/swayze_math.dart';

import '../../core/controller/editor/inline_editor_controller.dart';
import '../../core/internal_state/table_focus/table_focus_provider.dart';
import '../../core/viewport_context/viewport_context_provider.dart';
import '../internal_scope.dart';
import 'overlay.dart';
import 'rect_positions.dart';

/// Type signature of functions that builds the widget that allows the editing
/// of an individual cell in the same physical position as the once occupied by
/// the cell in the table.
///
/// See also:
/// - [SwayzeInlineEditorController] that defines if the inline editor is
/// open or not.
/// - [InlineEditorPlacer] internal widget that answers to
/// [SwayzeInlineEditorController] and adds an [OverlayEntry] when the editor is
/// open.
/// - [generateOverlayEntryForInlineEditor] that creates the [OverlayEntry]
/// that will contain the widget built here.
typedef InlineEditorBuilder = Widget Function(
  BuildContext context,
  IntVector2 coordinate,
  VoidCallback requestClose, {
  required bool overlapCell,
  required bool overlapTable,
  String? initialText,
});

/// An internal [Widget] that responds to [SwayzeInlineEditorController]
/// and adds or removes an [OverlayEntry] (generated by
/// [generateOverlayEntryForInlineEditor]) when the inline editor opens or
/// closes.
///
/// Also keeps track of the space occupied by the referred table and cell and
/// informs the overlay entry in order to know wether the inline editor
/// position overlaps the table or the cell.
///
/// See also:
/// - [SwayzeInlineEditorController] that defines if the inline editor is open
/// or not.
/// - [InlineEditorPlacer] internal widget that answers to
/// [SwayzeInlineEditorController] and adds an [OverlayEntry] when the editor is
/// open.
/// - [InlineEditorBuilder] the callback passed by to swayze to define what
/// should be rendered in the inline editor position.
class InlineEditorPlacer extends StatefulWidget {
  final InlineEditorBuilder inlineEditorBuilder;
  final Widget child;

  const InlineEditorPlacer({
    Key? key,
    required this.child,
    required this.inlineEditorBuilder,
  }) : super(key: key);

  @override
  State<InlineEditorPlacer> createState() => _InlineEditorPlacerState();
}

class _InlineEditorPlacerState extends State<InlineEditorPlacer> {
  late final internalScope = InternalScope.of(context);
  late final inlineEditorController = internalScope.controller.inlineEditor;
  late final tableFocus = TableFocus.of(context);
  final rectNotifier = RectPositionsNotifier(
    cellRect: Rect.zero,
    tableRect: Rect.zero,
  );

  OverlayEntry? overlayEntryCache;
  bool isOpen = false;

  @override
  void initState() {
    super.initState();

    inlineEditorController.addListener(handleEditorControllerUpdate);
    tableFocus.addListener(handleFocusNodeChange);
    assert(inlineEditorController.coordinate == null);
    handleEditorControllerUpdate();
  }

  @override
  void dispose() {
    if (isOpen) {
      overlayEntryCache?.remove();
    }
    super.dispose();
    tableFocus.removeListener(handleFocusNodeChange);
    inlineEditorController.removeListener(handleEditorControllerUpdate);
  }

  /// Keep track of the physical position occupied by the table and the editing
  /// cell in the screen.
  void updateRectPositions() {
    final cellCoordinate = inlineEditorController.coordinate;
    if (cellCoordinate == null) {
      // if the editor is not open, do nothing
      return;
    }

    final tableRect = _getTableRect(context) ?? Rect.zero;

    final cellRect = _getCellRect(
          context: context,
          tableRect: tableRect,
          cellCoordinate: cellCoordinate,
        ) ??
        Rect.zero;

    scheduleMicrotask(() {
      rectNotifier.setRect(tableRect: tableRect, cellRect: cellRect);
    });
  }

  void handleFocusNodeChange() {
    if (!tableFocus.value.isActive && inlineEditorController.isOpen) {
      inlineEditorController.close();
    }
  }

  void handleEditorControllerUpdate() {
    final wasOpen = isOpen;

    // If it was open somewhere else, close it and open in the current cell
    if (wasOpen) {
      overlayEntryCache?.remove();
      overlayEntryCache = null;
    }

    final coordinate = inlineEditorController.coordinate;
    final initialText = inlineEditorController.initialText;
    if (coordinate != null) {
      updateRectPositions();
      Overlay.of(context)!.insert(
        overlayEntryCache = generateOverlayEntryForInlineEditor(
          cellCoordinate: coordinate,
          initialText: initialText,
          originContext: context,
          rectNotifier: rectNotifier,
          inlineEditorBuilder: widget.inlineEditorBuilder,
          requestClose: inlineEditorController.close,
        ),
      );
    }

    isOpen = coordinate != null;
  }

  @override
  Widget build(BuildContext context) {
    updateRectPositions();
    return widget.child;
  }
}

/// Get the current physical position occupied by the table in relation to the
/// closest [Overlay].
Rect? _getTableRect(BuildContext context) {
  final table = context.findRenderObject();

  if (table == null) {
    return null;
  }

  final overlay =
      Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;

  final topLeft = MatrixUtils.transformPoint(
    table.getTransformTo(overlay),
    Offset.zero,
  );

  return topLeft & table.paintBounds.size;
}

/// Get the current physical position occupied by the cell located on
/// [cellCoordinate] in relation to the closest [Overlay].
Rect? _getCellRect({
  required BuildContext context,
  required Rect tableRect,
  required IntVector2 cellCoordinate,
}) {
  final viewportContext = ViewportContextProvider.of(context);
  final cellPositionResult = viewportContext.getCellPosition(cellCoordinate);

  if (cellPositionResult.isOffscreen) {
    return null;
  }

  final overlay =
      (Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox)
          .paintBounds;

  final displacedRect =
      cellPositionResult.leftTop & cellPositionResult.cellSize;

  final displacementLeft =
      viewportContext.columns.virtualizationState.displacement;
  final displacementTop = viewportContext.rows.virtualizationState.displacement;

  final tableLeft = tableRect.left;
  final tableTop = tableRect.top;

  final headerWidth = viewportContext.columns.virtualizationState.headerSize;
  final headerHeight = viewportContext.rows.virtualizationState.headerSize;

  final limitLeft = overlay.right - displacedRect.width;
  final limitTop = overlay.bottom - displacedRect.height;

  final finalLeft =
      (headerWidth + displacedRect.left + displacementLeft + tableLeft).clamp(
    headerWidth,
    limitLeft,
  );

  final finalTop =
      (headerHeight + displacedRect.top + displacementTop + tableTop).clamp(
    // if window is resized to the point that the table's top is offscreen, the
    // tableTop + headerHeight will be bigger than limitTop, therefore we need
    // to get the min between these for the lower bound.
    min<double>(tableTop + headerHeight, limitTop),
    limitTop,
  );

  return Offset(finalLeft, finalTop) & displacedRect.size;
}
