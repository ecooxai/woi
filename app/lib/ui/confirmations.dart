import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../platform/files.dart';
import '../tools/confirmation.dart';
import 'theme.dart';
import 'widgets/diff_view.dart';

/// Shows approval dialogs one at a time. Anything that cannot be shown is
/// rejected (fail closed).
class UiConfirmationService implements ConfirmationService {
  UiConfirmationService(this.navigatorKey);

  final GlobalKey<NavigatorState> navigatorKey;
  Future<void> _tail = Future.value();

  Future<bool> _serial(Future<bool?> Function(BuildContext ctx) show) {
    final result = _tail.then((_) async {
      final ctx = navigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return false;
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
            Text('Esc to reject · Ctrl+Enter to approve', style: body(12, color: WoiColors.textFaint)),
            const Spacer(),
            ...children,
          ],
        );
}

/// Diff preview for a pending file write.
class EditConfirmDialog extends StatelessWidget {
  const EditConfirmDialog({super.key, required this.request});
  final FileWriteRequest request;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final narrow = size.width < 640;
    final d = request.diff;
    return _ApprovalShortcuts(
      child: Dialog(
        insetPadding: EdgeInsets.all(narrow ? 10 : 32),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 1000, maxHeight: size.height * 0.88),
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
                Wrap(
                  spacing: 10,
                  children: [
                    _stat('+${d.added}', WoiColors.mint),
                    _stat('−${d.removed}', WoiColors.red),
                    if (request.isNewFile) _stat('new file', WoiColors.cyan),
                    if (request.reason != null) Text(request.reason!, style: body(12, color: WoiColors.textDim)),
                  ],
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 120),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: WoiColors.stroke),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: DiffView(diff: d),
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
