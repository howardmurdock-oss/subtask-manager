import 'dart:math';
import 'package:flutter/material.dart';

class DraggableDialog extends StatefulWidget {
  final String title;
  final Widget child;
  final double maxWidth;
  final double? maxHeight;
  final List<Widget>? actions;
  final bool Function()? hasUnsavedChanges;

  const DraggableDialog({
    super.key,
    required this.title,
    required this.child,
    this.maxWidth = 620,
    this.maxHeight,
    this.actions,
    this.hasUnsavedChanges,
  });

  static Future<T?> show<T>({
    required BuildContext context,
    required String title,
    required Widget Function(BuildContext context, StateSetter setDialogState) builder,
    double maxWidth = 620,
    double? maxHeight,
    bool Function()? hasUnsavedChanges,
  }) {
    return showDialog<T>(
      context: context,
      barrierDismissible: false,
      useSafeArea: true,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (innerCtx, setInnerState) {
            return DraggableDialog(
              title: title,
              maxWidth: maxWidth,
              maxHeight: maxHeight,
              hasUnsavedChanges: hasUnsavedChanges,
              child: builder(innerCtx, setInnerState),
            );
          },
        );
      },
    );
  }

  @override
  State<DraggableDialog> createState() => _DraggableDialogState();
}

class _DraggableDialogState extends State<DraggableDialog> {
  Offset _offset = Offset.zero;

  Future<void> _attemptClose(BuildContext context) async {
    final hasChanges = widget.hasUnsavedChanges != null && widget.hasUnsavedChanges!();
    if (!hasChanges) {
      Navigator.of(context, rootNavigator: true).pop();
      return;
    }

    final shouldDiscard = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Unsaved Changes'),
          content: const Text(
            'Are you sure you want to close without saving your changes?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep Editing'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Close without Saving'),
            ),
          ],
        );
      },
    );

    if (shouldDiscard == true && context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mediaQuery = MediaQuery.of(context);
    final bottomInset = mediaQuery.viewInsets.bottom;
    final topPadding = mediaQuery.padding.top;
    final bottomPadding = mediaQuery.padding.bottom;

    // Available vertical space above the soft keyboard
    final availableHeight = mediaQuery.size.height - bottomInset - topPadding - bottomPadding;
    final double maxAllowedHeight = widget.maxHeight != null
        ? widget.maxHeight!.clamp(160.0, max(160.0, availableHeight * 0.95)).toDouble()
        : max(160.0, availableHeight * 0.94).toDouble();

    final dialogWidth = mediaQuery.size.width < (widget.maxWidth + 24)
        ? (mediaQuery.size.width - 24).clamp(240.0, widget.maxWidth)
        : widget.maxWidth;

    // If keyboard pops up, gently reset or constrain offset so the dialog doesn't get pushed off screen
    final effectiveOffset = bottomInset > 0 ? Offset(_offset.dx, 0) : _offset;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _attemptClose(context);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => _attemptClose(context),
        child: AnimatedPadding(
          padding: EdgeInsets.only(
            bottom: bottomInset,
          ),
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
          child: Center(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {}, // Prevent click inside dialog card from triggering backdrop dismiss
              child: Transform.translate(
                offset: effectiveOffset,
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    width: dialogWidth,
                    constraints: BoxConstraints(
                      maxHeight: maxAllowedHeight,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: theme.colorScheme.onSurface.withOpacity(0.12),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.4),
                          blurRadius: 28,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Draggable Header Bar
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanUpdate: (details) {
                            setState(() {
                              _offset += details.delta;
                            });
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.4),
                              border: Border(
                                bottom: BorderSide(
                                  color: theme.colorScheme.onSurface.withOpacity(0.08),
                                ),
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.drag_indicator_rounded,
                                  size: 18,
                                  color: theme.colorScheme.onSurface.withOpacity(0.4),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    widget.title,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.close_rounded, size: 20),
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () => _attemptClose(context),
                                  tooltip: 'Close',
                                ),
                              ],
                            ),
                          ),
                        ),

                        // Scrollable Content
                        Flexible(
                          child: SingleChildScrollView(
                            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                            padding: const EdgeInsets.all(20),
                            child: widget.child,
                          ),
                        ),

                        // Optional Actions
                        if (widget.actions != null && widget.actions!.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            decoration: BoxDecoration(
                              border: Border(
                                top: BorderSide(
                                  color: theme.colorScheme.onSurface.withOpacity(0.08),
                                ),
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: widget.actions!,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
