import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../platform/files.dart';
import '../tools/confirmation.dart';
import 'theme.dart';
import 'widgets/diff_view.dart';
import 'widgets/empty_state.dart' show KeyHint;

/// Shows approval dialogs one at a time. Anything that cannot be shown is
/// rejected (fail closed).
class UiConfirmationService implements ConfirmationService {
  UiConfirmationService(this.navigatorKey, {this.onShow});

  final GlobalKey<NavigatorState> navigatorKey;

  /// Called as a dialog opens (raise/focus the window, play a cue).
  final Future<void> Function()? onShow;
  Future<void> _tail = Future.value();

  Future<bool> _serial(Future<bool?> Function(BuildContext ctx) show) {
    final result = _tail.then((_) async {
      // Approvals open on the home screen, never on top of Settings.
      navigatorKey.currentState?.popUntil((r) => r.isFirst);
      final ctx = navigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return false;
      final cue = onShow?.call().catchError((Object e) => debugPrint('approval cue: $e'));
      if (cue != null) unawaited(cue);
      return (await show(ctx)) ?? false;
    });
    _tail = result.then((_) {}, onError: (_) {});
    return result.catchError((_) => false);
  }

  @override
  Future<bool> confirmFileWrite(FileWriteRequest request) => _serial(
    (ctx) => showDialog<bool>(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => EditConfirmDialog(request: request),
    ),
  );

  @override
  Future<bool> confirmCommand(String command) => _serial(
    (ctx) => showDialog<bool>(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => CommandConfirmDialog(command: command),
    ),
  );
}

class _ApprovalShortcuts extends StatelessWidget {
  const _ApprovalShortcuts({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).pop(false),
      const SingleActivator(LogicalKeyboardKey.enter): () => Navigator.of(context).pop(true),
      const SingleActivator(LogicalKeyboardKey.numpadEnter): () => Navigator.of(context).pop(true),
      const SingleActivator(LogicalKeyboardKey.enter, control: true): () => Navigator.of(context).pop(true),
    },
    child: Focus(autofocus: true, child: child),
  );
}

Widget _header(IconData icon, Color color, String title, String subtitle) => Row(
  children: [
    Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Icon(icon, color: color),
    ),
    const SizedBox(width: 14),
    Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: display(19)),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: mono(12, color: WoiColors.textDim),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    ),
  ],
);

Widget _actions(BuildContext context, {required String approve, required String reject, required bool narrow}) {
  final children = [
    OutlinedButton.icon(
      onPressed: () => Navigator.of(context).pop(false),
      icon: const Icon(Icons.close),
      label: Text(reject),
    ),
    const SizedBox(width: 12, height: 10),
    FilledButton.icon(
      onPressed: () => Navigator.of(context).pop(true),
      icon: const Icon(Icons.check),
      label: Text(approve),
    ),
  ];
  return narrow
      ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children.reversed.toList())
      : Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            const KeyHint(keys: ['Enter'], label: 'approve'),
            const SizedBox(width: 14),
            const KeyHint(keys: ['Esc'], label: 'reject'),
            const Spacer(),
            ...children,
          ],
        );
}

/// Diff preview for a pending file write: unified or side-by-side,
/// syntax-coloured. Enter approves, Esc rejects.
class EditConfirmDialog extends StatefulWidget {
  const EditConfirmDialog({super.key, required this.request, this.initialLayout});
  final FileWriteRequest request;
  final DiffLayout? initialLayout;

  @override
  State<EditConfirmDialog> createState() => _EditConfirmDialogState();
}

class _EditConfirmDialogState extends State<EditConfirmDialog> {
  DiffLayout? _layout;

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    final size = MediaQuery.sizeOf(context);
    final narrow = size.width < 640;
    final canSplit = size.width >= 820 && !request.isNewFile;
    final layout = canSplit ? (_layout ?? widget.initialLayout ?? DiffLayout.split) : DiffLayout.unified;
    final d = request.diff;
    return _ApprovalShortcuts(
      child: Dialog(
        insetPadding: EdgeInsets.all(narrow ? 10 : 32),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 1200, maxHeight: size.height * 0.9),
          child: Padding(
            padding: EdgeInsets.all(narrow ? 16 : 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(
                  request.isNewFile ? Icons.note_add_outlined : Icons.edit_note,
                  WoiColors.amber,
                  request.isNewFile ? 'Create this file?' : 'Apply this change?',
                  request.path,
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _stat('+${d.added}', WoiColors.mint),
                          _stat('−${d.removed}', WoiColors.red),
                          if (request.isNewFile) _stat('new file', WoiColors.cyan),
                          if (request.reason != null) Text(request.reason!, style: body(12, color: WoiColors.textDim)),
                        ],
                      ),
                    ),
                    if (canSplit)
                      SegmentedButton<DiffLayout>(
                        showSelectedIcon: false,
                        style: const ButtonStyle(visualDensity: VisualDensity.compact),
                        segments: const [
                          ButtonSegment(
                            value: DiffLayout.split,
                            icon: Icon(Icons.vertical_split_outlined, size: 16),
                            label: Text('Split'),
                          ),
                          ButtonSegment(
                            value: DiffLayout.unified,
                            icon: Icon(Icons.view_agenda_outlined, size: 16),
                            label: Text('Unified'),
                          ),
                        ],
                        selected: {layout},
                        onSelectionChanged: (s) => setState(() => _layout = s.first),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (layout == DiffLayout.split)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text('BEFORE', style: eyebrow(color: WoiColors.red)),
                        ),
                        Expanded(
                          child: Text('AFTER', style: eyebrow(color: WoiColors.mint)),
                        ),
                      ],
                    ),
                  ),
                Flexible(
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 120),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.38),
                      borderRadius: BorderRadius.circular(WoiRadii.md),
                      border: Border.all(color: WoiColors.stroke),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: DiffView(diff: d, path: request.path, layout: layout),
                  ),
                ),
                const SizedBox(height: 18),
                _actions(
                  context,
                  approve: request.isNewFile ? 'Create file' : 'Apply change',
                  reject: 'Reject',
                  narrow: narrow,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _stat(String s, Color c) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
    decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
    child: Text(s, style: mono(12, color: c)),
  );
}

/// Shell command approval.
class CommandConfirmDialog extends StatelessWidget {
  const CommandConfirmDialog({super.key, required this.command});
  final String command;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 640;
    return _ApprovalShortcuts(
      child: Dialog(
        insetPadding: EdgeInsets.all(narrow ? 10 : 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Padding(
            padding: EdgeInsets.all(narrow ? 16 : 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(Icons.terminal, WoiColors.amber, 'Run this command?', 'bash on this computer'),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(14),
                  constraints: const BoxConstraints(maxHeight: 280),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: WoiColors.stroke),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '\$ ',
                            style: mono(13.5, color: WoiColors.mint),
                          ),
                          TextSpan(text: command, style: mono(13.5)),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text('You can turn this prompt off in Settings → Safety.', style: body(12, color: WoiColors.textFaint)),
                const SizedBox(height: 18),
                _actions(context, approve: 'Run', reject: 'Deny', narrow: narrow),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
