import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../platform/clipboard_access.dart';

class _ClipboardScope extends InheritedWidget {
  const _ClipboardScope({required this.clipboard, required super.child});
  final ClipboardAccess clipboard;
  @override
  bool updateShouldNotify(_ClipboardScope oldWidget) => oldWidget.clipboard != clipboard;
}

class _CopySelectedIntent extends Intent {
  const _CopySelectedIntent();
}

/// Preserves Flutter's cross-message selection and Select all, but sends Copy
/// through Woi's native service when a headless assistant engine has no host
/// Activity for Flutter's default platform clipboard plugin.
class ClipboardSelectionArea extends StatefulWidget {
  const ClipboardSelectionArea({super.key, required this.child, this.clipboard});
  final Widget child;
  final ClipboardAccess? clipboard;

  static ClipboardAccess clipboardOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ClipboardScope>()?.clipboard ?? const SystemClipboardAccess();

  @override
  State<ClipboardSelectionArea> createState() => _ClipboardSelectionAreaState();
}

class _ClipboardSelectionAreaState extends State<ClipboardSelectionArea> {
  String _selected = '';
  ClipboardAccess get _clipboard => widget.clipboard ?? ClipboardSelectionArea.clipboardOf(context);

  Future<void> _copy(String text) async {
    if (text.isEmpty) return;
    try {
      await _clipboard.writeText(text);
    } catch (error) {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Copy failed: $error')));
    }
  }

  @override
  Widget build(BuildContext context) => _ClipboardScope(
    clipboard: _clipboard,
    child: Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyC, control: true): _CopySelectedIntent(),
        SingleActivator(LogicalKeyboardKey.keyC, meta: true): _CopySelectedIntent(),
      },
      child: Actions(
        actions: {
          _CopySelectedIntent: CallbackAction<_CopySelectedIntent>(
            onInvoke: (_) {
              unawaited(_copy(_selected));
              return null;
            },
          ),
        },
        child: SelectionArea(
          onSelectionChanged: (content) => _selected = content?.plainText ?? '',
          contextMenuBuilder: (context, selectable) => AdaptiveTextSelectionToolbar.buttonItems(
            anchors: selectable.contextMenuAnchors,
            buttonItems: [
              for (final item in selectable.contextMenuButtonItems)
                item.type == ContextMenuButtonType.copy
                    ? ContextMenuButtonItem(
                        type: ContextMenuButtonType.copy,
                        onPressed: () {
                          final text = _selected;
                          selectable.hideToolbar();
                          unawaited(_copy(text));
                        },
                      )
                    : item,
            ],
          ),
          child: widget.child,
        ),
      ),
    ),
  );
}
