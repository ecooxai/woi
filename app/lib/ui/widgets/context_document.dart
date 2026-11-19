import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/context/context_manager.dart';
import '../../core/context/image_tiers.dart';
import '../../core/models/message.dart';
import '../../core/models/message_file_attachment.dart';
import '../../core/voice/voice_backend.dart' show ToolSpec;
import '../../platform/audio_io.dart';
import '../../platform/media_viewer.dart';
import '../theme.dart';
import 'audio_button.dart';
import 'image_viewer.dart';
import 'thumbnail_image_provider.dart';

/// Inspectable configuration only; never includes credentials or session keys.
class ContextDocumentData {
  const ContextDocumentData({
    this.instructions = '',
    this.pinnedNote = '',
    this.tools = const [],
    this.delegationInstructions,
  });

  final String instructions;
  final String pinnedNote;
  final List<ToolSpec> tools;
  final String? delegationInstructions;
}

/// A document of the locally recorded context. Bodies are built only after a
/// heading is opened, so opening the meter never decodes all retained media.
class ContextDocument extends StatelessWidget {
  const ContextDocument({
    super.key,
    required this.manager,
    required this.conversation,
    required this.meter,
    required this.usageDetails,
    required this.accent,
    this.data,
    this.audio,
    this.viewer,
    this.onCompact,
  });

  final ContextManager manager;
  final Conversation? conversation;
  final ContextDocumentData? data;
  final AudioIO? audio;
  final MediaViewer? viewer;
  final Widget meter;
  final Widget usageDetails;
  final Color accent;
  final VoidCallback? onCompact;

  @override
  Widget build(BuildContext context) {
    final conv = conversation;
    final active = [
      for (final message in conv?.messages ?? const <Message>[])
        if (!message.compacted && (message.kind != MessageKind.system || message.meta['type'] == 'screenshot')) message,
    ];
    final source = data;
    final summary = conv?.summary ?? '';
    final compacted = conv?.messages.where((message) => message.compacted).length ?? 0;
    final images = active.where((message) => message.image != null).length;
    final recordings = active.where((message) => message.audio != null).length;
    final textOnly = manager.accounting == ContextAccounting.textEstimate;
    final sections = <Widget>[
      if (source != null && source.instructions.isNotEmpty)
        ContextDocumentSection(
          key: const ValueKey('context-section-instructions'),
          title: 'Session instructions',
          subtitle: 'Current session configuration',
          icon: Icons.tune_rounded,
          builder: (_) => _DocumentText(source.instructions),
        ),
      if (source != null && source.tools.isNotEmpty)
        ContextDocumentSection(
          key: const ValueKey('context-section-tools'),
          title: 'Tool definitions',
          subtitle: _count(source.tools.length, 'available tool'),
          icon: Icons.build_outlined,
          builder: (_) => _DocumentText(
            const JsonEncoder.withIndent('  ').convert([for (final tool in source.tools) tool.toJson()]),
            code: true,
          ),
        ),
      if (source?.delegationInstructions case final String instructions when instructions.isNotEmpty)
        ContextDocumentSection(
          key: const ValueKey('context-section-delegation'),
          title: 'Delegation instructions',
          subtitle: 'Instructions for delegated tasks',
          icon: Icons.account_tree_outlined,
          builder: (_) => _DocumentText(instructions),
        ),
      if (source != null && source.pinnedNote.isNotEmpty)
        ContextDocumentSection(
          key: const ValueKey('context-section-note'),
          title: 'Pinned note',
          subtitle: 'Included every turn',
          icon: Icons.push_pin_outlined,
          builder: (_) => _DocumentText(source.pinnedNote),
        ),
      if (summary.isNotEmpty)
        ContextDocumentSection(
          key: const ValueKey('context-section-summary'),
          title: 'Memory summary',
          subtitle: compacted > 0 ? '${_count(compacted, 'earlier message')} summarised' : 'Earlier conversation',
          icon: Icons.history_rounded,
          builder: (_) => _DocumentText(summary),
        ),
      for (var index = 0; index < active.length; index++)
        ContextDocumentSection(
          key: ValueKey('context-section-message-${active[index].id}'),
          title: '${index + 1}. ${_messageTitle(active[index])}',
          subtitle: _messageSubtitle(active[index]),
          icon: _messageIcon(active[index]),
          builder: (_) => _ContextMessage(message: active[index], audio: audio, viewer: viewer, textOnly: textOnly),
        ),
      ContextDocumentSection(
        key: const ValueKey('context-section-usage'),
        title: 'Usage details',
        subtitle: 'Token breakdown and compaction',
        icon: Icons.data_usage_rounded,
        builder: (_) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            usageDetails,
            const SizedBox(height: 12),
            _DocumentText(
              'Older messages are replaced by the memory summary when context is compacted. '
              'The latest turns remain available in full.'
              '${source == null ? ' Detailed session instructions and the pinned note were not supplied to this view.' : ''}',
            ),
          ],
        ),
      ),
    ];

    return ScaffoldMessenger(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('CONTEXT DOCUMENT', style: eyebrow()),
                            const SizedBox(height: 6),
                            Semantics(
                              header: true,
                              child: Text(
                                conv?.title.trim().isNotEmpty == true ? conv!.title : 'Current conversation',
                                key: const ValueKey('context-document-title'),
                                style: display(21),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close context',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 5,
                    alignment: WrapAlignment.spaceBetween,
                    children: [
                      Text(
                        '${_count(active.length, 'message')} · ${_count(images, 'image')} · ${_count(recordings, 'recording')}',
                        style: body(12, color: WoiColors.textDim),
                      ),
                      Text(
                        '${formatTokenCount(manager.estimatedTokens)} / ${formatTokenCount(manager.threshold)} tokens',
                        style: mono(12, color: accent).copyWith(fontFeatures: kTabular),
                      ),
                    ],
                  ),
                  const SizedBox(height: 9),
                  meter,
                  const SizedBox(height: 12),
                  Text(
                    textOnly
                        ? 'Open a heading to read its content. Live voice uses text; images are available to delegated tasks. Recordings are retained for playback.'
                        : 'Open a heading to read its content, view images or play recordings. Summarised messages are represented by the memory summary.',
                    style: body(12.5, color: WoiColors.textDim, height: 1.4),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: WoiColors.stroke),
            Expanded(
              child: ListView.builder(
                key: const ValueKey('context-document-scroll'),
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                itemCount: sections.length + (active.isEmpty ? 1 : 0),
                itemBuilder: (_, index) {
                  if (active.isEmpty && index == sections.length) {
                    return Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('No unsummarised messages yet.', style: body(13, color: WoiColors.textDim)),
                    );
                  }
                  return sections[index];
                },
              ),
            ),
            if (onCompact != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
                child: FilledButton.icon(
                  onPressed: manager.compressing ? null : onCompact,
                  icon: const Icon(Icons.compress_rounded),
                  label: Text(manager.compressing ? 'Compacting…' : 'Compact now'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _count(int count, String word) => '$count $word${count == 1 ? '' : 's'}';

String _messageTitle(Message message) => switch (message.kind) {
  MessageKind.user => 'You',
  MessageKind.assistant => 'Woi',
  MessageKind.tool => 'Tool · ${message.tool?.name ?? 'Result'}',
  MessageKind.system => 'Screenshot / visual context',
};

IconData _messageIcon(Message message) => switch (message.kind) {
  MessageKind.user => Icons.person_outline_rounded,
  MessageKind.assistant => Icons.auto_awesome_outlined,
  MessageKind.tool => Icons.terminal_rounded,
  MessageKind.system => Icons.image_outlined,
};

String _messageSubtitle(Message message) => [
  ContextManager.renderTime(message.createdAt),
  if (message.text.isNotEmpty) 'Text',
  if (message.image != null) 'Image',
  if (message.audio != null) 'Audio',
  if (message.tool != null) message.tool!.status.name,
  if (message.interrupted) 'Interrupted',
  if (message.streaming) 'Updating…',
].join(' · ');

/// Expansion is owned by this route, never persisted in PageStorage. Closing
/// and reopening the document therefore always starts with every part folded.
class ContextDocumentSection extends StatefulWidget {
  const ContextDocumentSection({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.builder,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final WidgetBuilder builder;

  @override
  State<ContextDocumentSection> createState() => _ContextDocumentSectionState();
}

class _ContextDocumentSectionState extends State<ContextDocumentSection> with AutomaticKeepAliveClientMixin {
  bool _expanded = false;

  @override
  bool get wantKeepAlive => _expanded;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Material(
        color: WoiColors.bg1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: _expanded ? WoiColors.strokeStrong : WoiColors.stroke),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              expanded: _expanded,
              header: true,
              child: InkWell(
                key: const ValueKey('context-section-heading'),
                onTap: () {
                  setState(() => _expanded = !_expanded);
                  updateKeepAlive();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                  child: Row(
                    children: [
                      Icon(widget.icon, size: 19, color: WoiColors.textDim),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(widget.title, style: body(14, weight: FontWeight.w600)),
                            const SizedBox(height: 3),
                            Text(widget.subtitle, style: body(11.5, color: WoiColors.textDim)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(_expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: WoiColors.textDim),
                    ],
                  ),
                ),
              ),
            ),
            if (_expanded) Padding(padding: const EdgeInsets.fromLTRB(16, 3, 16, 16), child: widget.builder(context)),
          ],
        ),
      ),
    );
  }
}

class _DocumentText extends StatelessWidget {
  const _DocumentText(this.text, {this.code = false});
  final String text;
  final bool code;

  @override
  Widget build(BuildContext context) => SelectableText(
    text,
    style: code ? mono(12, color: WoiColors.text).copyWith(height: 1.5) : body(14, height: 1.55),
  );
}

class _ContextMessage extends StatelessWidget {
  const _ContextMessage({required this.message, required this.textOnly, this.audio, this.viewer});
  final Message message;
  final bool textOnly;
  final AudioIO? audio;
  final MediaViewer? viewer;

  @override
  Widget build(BuildContext context) {
    final image = message.image;
    final clip = message.audio;
    final tool = message.tool;
    final description = imageDescriptionOf(message);
    final files = messageFileDisplay(message)?.files ?? const <MessageFileAttachment>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (message.text.isNotEmpty) _DocumentText(message.text),
        if (image != null) ...[
          const SizedBox(height: 12),
          Text(switch (imageTierOf(message)) {
            ImageTier.described => 'Image retained locally · model context uses the description below',
            ImageTier.reduced => 'Original image · sent to the model at reduced resolution',
            ImageTier.full => textOnly ? 'Image retained for delegated visual tasks' : 'Image in context',
          }, style: body(12, color: WoiColors.textDim)),
          const SizedBox(height: 8),
          _ContextImage(image: image),
          if (description?.isNotEmpty == true) ...[const SizedBox(height: 8), _DocumentText(description!)],
        ],
        if (clip != null) ...[
          const SizedBox(height: 12),
          Text(
            textOnly ? 'Recording · transcript is used in live voice context' : 'Audio recording',
            style: body(12, color: WoiColors.textDim),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: audio != null
                ? ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: kTouchTarget),
                    child: AudioClipButton(key: ValueKey('context-audio-${message.id}'), clip: clip, audio: audio!),
                  )
                : Text(
                    'Recording ${(clip.durationMs / 1000).toStringAsFixed(1)}s · playback unavailable',
                    style: body(13),
                  ),
          ),
        ],
        if (tool != null) ...[
          const SizedBox(height: 12),
          Text(
            'Arguments',
            style: body(12, weight: FontWeight.w600, color: WoiColors.textDim),
          ),
          const SizedBox(height: 6),
          _DocumentText(tool.argsJson, code: true),
          const SizedBox(height: 12),
          Text(
            'Result · ${tool.status.name}',
            style: body(12, weight: FontWeight.w600, color: WoiColors.textDim),
          ),
          const SizedBox(height: 6),
          _DocumentText(tool.resultJson ?? 'No result recorded yet.', code: true),
        ],
        if (files.isNotEmpty && viewer != null) ...[
          const SizedBox(height: 10),
          for (final file in files)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.attach_file_rounded, size: 18),
                label: Text(file.name, overflow: TextOverflow.ellipsis),
                onPressed: () {
                  final path = Uri.parse(file.uri).toFilePath();
                  viewer!.show(MediaItem(kind: MediaItem.kindForPath(path), path: path, customTitle: file.name));
                },
              ),
            ),
        ],
        if (message.text.isEmpty && image == null && clip == null && tool == null)
          Text(
            message.streaming ? 'Waiting for content…' : 'No content recorded.',
            style: body(13, color: WoiColors.textDim),
          ),
      ],
    );
  }
}

class _ContextImage extends StatelessWidget {
  const _ContextImage({required this.image});
  final ImageAttachment image;

  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    button: true,
    label: 'Context image. Open full size',
    child: InkWell(
      onTap: () => showImageLightbox(context, image.path, caption: 'Context image'),
      borderRadius: BorderRadius.circular(10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360),
          child: Image(
            key: ValueKey('context-image-${image.path}'),
            image: ThumbnailImage(FileImage(File(image.path)), width: 1280, height: 960),
            fit: BoxFit.contain,
            filterQuality: FilterQuality.low,
            errorBuilder: (_, error, stack) => Container(
              padding: const EdgeInsets.all(20),
              color: WoiColors.glass,
              child: Row(
                children: [
                  const Icon(Icons.broken_image_outlined),
                  const SizedBox(width: 12),
                  Expanded(child: Text('Image unavailable on this device.', style: body(13))),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
