import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../platform/clipboard_access.dart';
import '../../platform/file_picker.dart';
import '../theme.dart';
import 'thumbnail_image_provider.dart';

/// The draft identity and range where a native clipboard or picker request began.
class ChatDraftPasteTarget {
  const ChatDraftPasteTarget._(this._owner, this._generation, this.text);
  final ChatDraftController _owner;
  final int _generation;
  final TextEditingValue text;
}

/// The exact unsent draft submitted to an asynchronous send operation.
class ChatDraftSubmission {
  const ChatDraftSubmission._(this._owner, this._generation, this.text, this.attachments);
  final ChatDraftController _owner;
  final int _generation;
  final String text;
  final List<PickedFile> attachments;
}

/// One unsent message, retained while the user switches tabs or pane widths.
class ChatDraftController extends ChangeNotifier {
  ChatDraftController() {
    text.addListener(_onTextChanged);
  }

  final text = TextEditingController();
  TextEditingValue _lastText = TextEditingValue.empty;
  int _generation = 0;
  bool _applyingTextEdit = false;

  // A continued edit keeps the same unsent draft. Clearing, replacing the
  // whole selection, or assigning another draft text retires pending pastes.
  void _onTextChanged() {
    final next = text.value;
    if (!_applyingTextEdit && next.text != _lastText.text) {
      final selection = _lastText.selection;
      final replacedAll =
          _lastText.text.isNotEmpty &&
          selection.isValid &&
          selection.start == 0 &&
          selection.end == _lastText.text.length;
      final cleared = _lastText.text.isNotEmpty && next.text.isEmpty;
      if (cleared || replacedAll || !next.selection.isValid) _generation++;
    }
    _lastText = next;
  }

  ChatDraftPasteTarget capturePasteTarget() => ChatDraftPasteTarget._(this, _generation, text.value);

  /// Changing conversations retires pending native reads and send completions
  /// without discarding the draft.
  void retirePendingPastes() => _generation++;
  final List<PickedFile> _attachments = [];
  List<PickedFile> get attachments => List.unmodifiable(_attachments);
  bool get hasAttachments => _attachments.isNotEmpty;
  bool sending = false;
  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void addFiles(List<PickedFile> files, {ChatDraftPasteTarget? at}) {
    if (files.isEmpty) return;
    if (_disposed || (at != null && (at._owner != this || at._generation != _generation))) {
      throw StateError('This message changed before file selection finished. Choose the files again when ready.');
    }
    if (sending) throw StateError('Wait for the current message to send before adding another attachment.');
    if (_attachments.length + files.length > 8) throw StateError('Attach up to 8 files to one message.');
    var total = _attachments.fold(0, (sum, file) => sum + file.bytes.length);
    for (final file in files) {
      if (file.bytes.length > 20 * 1024 * 1024) throw StateError('${file.name} exceeds the 20 MB file limit.');
      total += file.bytes.length;
    }
    if (total > 32 * 1024 * 1024) throw StateError('Attachments exceed the 32 MB limit for one message.');
    _attachments.addAll([
      for (final file in files)
        PickedFile(bytes: Uint8List.fromList(file.bytes), name: file.name, mimeType: file.mimeType),
    ]);
    _notify();
  }

  void insertText(String value, {bool append = false, TextSelection? selection}) {
    if (value.isEmpty) return;
    if (sending) throw StateError('Wait for the current message to send before pasting.');
    final current = text.value;
    final requested = selection ?? current.selection;
    final target = append || !requested.isValid ? TextSelection.collapsed(offset: current.text.length) : requested;
    final prefix = append && current.text.isNotEmpty && !current.text.endsWith('\n') ? '\n' : '';
    final inserted = '$prefix$value';
    if (current.text.isNotEmpty && target.start == 0 && target.end == current.text.length) _generation++;
    _applyingTextEdit = true;
    try {
      text.value = TextEditingValue(
        text: current.text.replaceRange(target.start, target.end, inserted),
        selection: TextSelection.collapsed(offset: target.start + inserted.length),
      );
    } finally {
      _applyingTextEdit = false;
    }
  }

  void stageClipboard(ClipboardContent content, {bool append = false, ChatDraftPasteTarget? at}) {
    if (_disposed || (at != null && (at._owner != this || at._generation != _generation))) {
      throw StateError('This message was sent, cleared, or replaced before paste finished. Paste again when ready.');
    }
    // An image is an attachment to the same draft, so continued typing is
    // harmless. Text replacement requires the exact initiating text/range.
    if (at != null && (content.text?.isNotEmpty ?? false) && at.text.text != text.text) {
      throw StateError('Your message changed before paste finished. Paste again when ready.');
    }
    if (content.image case final image?) {
      addFiles([PickedFile(bytes: image.bytes, name: image.name, mimeType: image.mimeType)]);
    }
    if (content.text case final value?) insertText(value, append: append, selection: at?.text.selection);
  }

  void remove(PickedFile file) {
    if (sending) return;
    if (_attachments.remove(file) && _attachments.isEmpty && text.text.isEmpty) _generation++;
    _notify();
  }

  void setSending(bool value) {
    if (sending == value) return;
    sending = value;
    if (value) _generation++;
    _notify();
  }

  ChatDraftSubmission captureSubmission() =>
      ChatDraftSubmission._(this, _generation, text.text, List.unmodifiable(_attachments));

  /// Only acceptance of this exact draft can clear it. A replacement, another
  /// conversation, or external edits while reconnecting retain the newer draft.
  bool clearSubmitted(ChatDraftSubmission submission) {
    if (_disposed ||
        submission._owner != this ||
        submission._generation != _generation ||
        submission.text != text.text ||
        !listEquals(submission.attachments, _attachments)) {
      return false;
    }
    _generation++;
    text.clear();
    _attachments.clear();
    _notify();
    return true;
  }

  void clearAttachments() {
    if (_attachments.isNotEmpty && (_disposed || text.text.isEmpty)) _generation++;
    _attachments.clear();
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    text.removeListener(_onTextChanged);
    text.dispose();
    super.dispose();
  }
}

class ChatAttachmentTray extends StatefulWidget {
  const ChatAttachmentTray({super.key, required this.draft});
  final ChatDraftController draft;

  @override
  State<ChatAttachmentTray> createState() => _ChatAttachmentTrayState();
}

class _ChatAttachmentTrayState extends State<ChatAttachmentTray> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.draft,
    builder: (context, _) {
      final draft = widget.draft;
      final files = draft.attachments;
      if (files.isEmpty) return const SizedBox.shrink();
      final contentWidth = files.fold<double>(8, (width, file) => width + (file.isImage ? 140 : 180) + 8);
      return LayoutBuilder(
        builder: (context, constraints) => Column(
          key: const ValueKey('chat-attachment-tray'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${files.length} attachment${files.length == 1 ? '' : 's'}',
                      style: body(12, color: WoiColors.textDim),
                    ),
                  ),
                  if (contentWidth > constraints.maxWidth)
                    Text('Swipe or scroll', style: body(11, color: WoiColors.textFaint)),
                ],
              ),
            ),
            SizedBox(
              height: 116,
              child: Scrollbar(
                controller: _scroll,
                thumbVisibility: true,
                child: ListView.separated(
                  key: const ValueKey('chat-attachments-scroll'),
                  controller: _scroll,
                  primary: false,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
                  itemCount: files.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final file = files[index];
                    return Tooltip(
                      message: file.name,
                      child: Container(
                        key: ValueKey('chat-attachment-$index'),
                        width: file.isImage ? 140 : 180,
                        decoration: BoxDecoration(
                          color: WoiColors.glassStrong,
                          borderRadius: BorderRadius.circular(WoiRadii.md),
                          border: Border.all(color: WoiColors.stroke),
                        ),
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(8, 7, 8, 6),
                                child: Column(
                                  children: [
                                    Expanded(
                                      child: file.isImage
                                          ? ClipRRect(
                                              borderRadius: BorderRadius.circular(4),
                                              child: Image(
                                                image: ThumbnailImage(MemoryImage(file.bytes), width: 280, height: 160),
                                                fit: BoxFit.contain,
                                                semanticLabel: file.name,
                                                errorBuilder: (_, _, _) =>
                                                    const Icon(Icons.broken_image_outlined, size: 27),
                                              ),
                                            )
                                          : Icon(Icons.insert_drive_file_outlined, size: 28, color: WoiColors.textDim),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${index + 1}. ${file.name}',
                                      key: ValueKey('chat-attachment-name-$index'),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: body(11, color: WoiColors.textDim),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Positioned(
                              top: 0,
                              right: 0,
                              child: SizedBox(
                                width: 48,
                                height: 48,
                                child: IconButton(
                                  key: ValueKey('remove-chat-attachment-$index'),
                                  tooltip: 'Remove ${file.name}',
                                  onPressed: draft.sending ? null : () => draft.remove(file),
                                  padding: const EdgeInsets.all(6),
                                  icon: Container(
                                    width: 28,
                                    height: 28,
                                    decoration: BoxDecoration(
                                      color: WoiColors.bg1.withValues(alpha: .94),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(Icons.close_rounded, size: 16),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
