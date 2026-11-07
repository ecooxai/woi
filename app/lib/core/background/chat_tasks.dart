import 'dart:async';
import 'dart:io';

import '../auth/auth.dart' show redactSecrets;
import '../images/image_generation.dart';
import '../models/message.dart';
import '../search/web_search.dart';
import '../storage/history_store.dart';

/// Background tool work retains its original chat. Reopening that chat reuses
/// the retained object, so late completions cannot overwrite newer messages.
class BackgroundChatTasks {
  BackgroundChatTasks({
    required this.images,
    required this.search,
    required this.history,
    required this.currentConversation,
    required this.onChanged,
    this.onImageCompleted,
  });
  final ImageGenerationClient images;
  final WebSearchService search;
  final HistoryStore history;
  final Conversation Function() currentConversation;
  final void Function(Conversation conversation) onChanged;
  final Future<void> Function(Conversation conversation, Message message)?
  onImageCompleted;
  final _conversations = <String, Conversation>{};
  final _references = <String, int>{};
  final _deleted = <String>{};
  final _imageJobs = <String, _ImageJob>{};
  bool _stopped = false;

  Conversation? retainedConversation(String id) => _conversations[id];

  Conversation _retain() {
    if (_stopped) throw StateError('Background tools are shutting down.');
    final conversation = currentConversation();
    _conversations[conversation.id] = conversation;
    _references.update(conversation.id, (n) => n + 1, ifAbsent: () => 1);
    return conversation;
  }

  void _release(Conversation conversation) {
    final count = (_references[conversation.id] ?? 1) - 1;
    if (count <= 0) {
      _references.remove(conversation.id);
      _conversations.remove(conversation.id);
    } else {
      _references[conversation.id] = count;
    }
  }

  bool _canPost(Conversation c) => !_stopped && !_deleted.contains(c.id);

  Future<void> _persist(Conversation c) async {
    c.updatedAt = DateTime.now();
    onChanged(c);
    await history.save(c);
  }

  Future<Map<String, Object?>> generateImage({
    required String prompt,
    required String model,
    required String quality,
    required String textModel,
    String size = '1024x1024',
    String outputFormat = 'jpeg',
    String action = 'generate',
    String? sourceMessageId,
  }) async {
    if (prompt.trim().isEmpty || prompt.length > 32000) {
      throw ArgumentError('Image prompt must contain 1–32,000 characters.');
    }
    if (action != 'generate' && action != 'edit') {
      throw ArgumentError('Image action must be generate or edit.');
    }
    if (action == 'generate' &&
        sourceMessageId != null &&
        sourceMessageId.isNotEmpty) {
      throw ArgumentError('Use action edit when specifying a source image.');
    }
    final sourceConversation = currentConversation();
    final references = sourceConversation.messages
        .where((m) => m.image != null)
        .toList();
    final Message? source;
    if (action == 'edit') {
      final artwork = references
          .where(
            (m) =>
                m.image!.generated ||
                m.meta['imageKind'] == 'generated' ||
                m.meta['imageKind'] == 'media',
          )
          .toList();
      final candidates = artwork.isNotEmpty ? artwork : references;
      source = sourceMessageId == null || sourceMessageId.isEmpty
          ? (candidates.isEmpty ? null : candidates.last)
          : references.where((m) => m.id == sourceMessageId).firstOrNull;
      if (source == null) {
        throw ArgumentError(
          'No matching image in this chat to edit. Generate or attach an image first.',
        );
      }
    } else {
      source = null;
    }
    if (_imageJobs.length >= 3) {
      throw StateError(
        'Three images are already being generated. Wait for one to finish.',
      );
    }
    final c = _retain();
    final message = Message(
      kind: MessageKind.assistant,
      text: action == 'edit' ? 'Editing image…' : 'Generating image…',
      meta: {
        'type': 'image_generation',
        'status': 'pending',
        'prompt': prompt.trim(),
        'model': model,
        'quality': quality,
        'size': size,
        'format': outputFormat,
        'action': action,
        if (source != null) 'source_message_id': source.id,
      },
    );
    final job = _ImageJob(c, message);
    _imageJobs[message.id] = job;
    c.add(message);
    try {
      await _persist(c);
    } catch (_) {
      _imageJobs.remove(message.id);
      c.messages.remove(message);
      if (_canPost(c)) onChanged(c);
      _release(c);
      rethrow;
    }
    if (job.cancelled || !_canPost(c)) {
      _imageJobs.remove(message.id);
      _release(c);
      return {
        'ok': false,
        'status': 'cancelled',
        'message_id': message.id,
        'note': 'Image generation was cancelled because its chat was removed or the app closed.',
      };
    }
    unawaited(
      _runImage(
        job,
        prompt: prompt.trim(),
        model: model,
        quality: quality,
        textModel: textModel,
        size: size,
        outputFormat: outputFormat,
        inputImages: source == null ? const [] : [source.image!],
      ),
    );
    return {
      'ok': true,
      'status': 'queued',
      'message_id': message.id,
      'model': model,
      'quality': quality,
      'size': size,
      'format': outputFormat,
      'action': action,
      if (source != null) 'source_message_id': source.id,
      'note':
          'Image ${action == 'edit' ? 'editing' : 'generation'} started in the background. The image will appear in this chat when complete. '
          'Do not claim it is finished or call generate_image again for this same request.',
    };
  }

  Future<void> _runImage(
    _ImageJob job, {
    required String prompt,
    required String model,
    required String quality,
    required String textModel,
    required String size,
    required String outputFormat,
    required List<ImageAttachment> inputImages,
  }) async {
    final watch = Stopwatch()..start();
    try {
      if (job.cancelled || !_canPost(job.conversation)) return;
      final image = await images.generate(
        prompt: prompt,
        model: model,
        quality: quality,
        textModel: textModel,
        outputDirectory: Directory(history.paths.imagesDir),
        size: size,
        outputFormat: outputFormat,
        inputImages: inputImages,
      );
      if (job.cancelled || !_canPost(job.conversation)) {
        // The user removed the chat while the request was running. Do not
        // recreate its JSON or leave an orphaned generated file behind.
        try {
          await File(image.path).delete();
        } catch (_) {}
        return;
      }
      final completed = Message(
        id: job.message.id,
        kind: MessageKind.assistant,
        image: image,
        meta: {
          ...job.message.meta,
          'status': 'completed',
          'imageKind': 'generated',
          'duration_ms':
              image.generationDurationMs ?? watch.elapsedMilliseconds,
          'requested_at': job.message.createdAt.toIso8601String(),
        },
      );
      // Completion is a new visible event: keep its stable reference ID, but
      // move it after any messages sent while the background job was running.
      job.conversation.messages.removeWhere((m) => m.id == job.message.id);
      job.conversation.add(completed);
      job.message = completed;
      if (_canPost(job.conversation) && !job.cancelled) {
        try {
          await onImageCompleted?.call(job.conversation, job.message);
        } catch (e) {
          // The JPEG remains a successful, viewable result even if its live
          // context delivery fails; reconnect can restore it from history.
          job.message.meta['context_error'] = redactSecrets('$e');
          onChanged(job.conversation);
        }
      }
      try {
        await _persist(job.conversation);
      } catch (e) {
        // The image itself succeeded. Keep the attachment and distinguish a
        // disk error from a generation failure so the user can still view it.
        if (!_deleted.contains(job.conversation.id)) {
          job.message.meta['save_error'] = redactSecrets('$e');
          job.message.text =
              'Image generated, but it could not be saved to chat history.';
          onChanged(job.conversation);
        }
      }
      // Deletion can start while the completed snapshot waits in storage's
      // queue. Its earlier JSON may not yet know this file, so clean it here.
      if (_deleted.contains(job.conversation.id)) {
        try {
          await File(image.path).delete();
        } catch (_) {}
      }
    } catch (e) {
      if (job.cancelled || !_canPost(job.conversation)) return;
      job.message.meta['status'] = 'failed';
      job.message.meta['duration_ms'] = watch.elapsedMilliseconds;
      job.message.text = 'Image generation failed: ${redactSecrets('$e')}';
      try {
        await _persist(job.conversation);
      } catch (_) {
        // Still show the actual failure in memory if storage also failed.
        job.message.text += '\nThis result could not be saved to chat history.';
        onChanged(job.conversation);
      }
    } finally {
      _imageJobs.remove(job.message.id);
      _release(job.conversation);
    }
  }

  Future<Map<String, Object?>> searchWeb(String query) async {
    final c = _retain();
    try {
      final result = await search.search(query);
      if (!_canPost(c)) return result;
      // Provider citation markers are only useful with their annotation map.
      // Persist readable source links separately for the chat UI.
      final answer = (result['answer'] as String? ?? '')
          .replaceAll(
            RegExp(r'\uE200[^\uE201]*\uE201|\uE202[^\uE201]*\uE201'),
            '',
          )
          .trim();
      c.add(
        Message(
          kind: MessageKind.assistant,
          text: answer,
          meta: {
            'type': 'web_search',
            'query': query,
            'sources': result['sources'],
            'model': result['model'],
            'duration_ms': result['duration_ms'],
          },
        ),
      );
      await _persist(c);
      return result;
    } finally {
      _release(c);
    }
  }

  /// Called before deleting a chat so a late result can never recreate it.
  void discardConversation(String id) {
    _deleted.add(id);
    for (final job in _imageJobs.values) {
      if (job.conversation.id == id) job.cancelled = true;
    }
    _conversations.remove(id);
  }

  /// A saved pending image cannot keep running across app launches. Mark it
  /// honestly when that chat is loaded; the user can ask to generate it again.
  static bool recoverInterrupted(Conversation c) {
    var changed = false;
    for (final m in c.messages) {
      if (m.meta['type'] == 'image_generation' &&
          m.meta['status'] == 'pending') {
        m.meta['status'] = 'interrupted';
        m.text = 'Image generation was interrupted. Ask to generate the image again.';
        changed = true;
      }
    }
    return changed;
  }

  Future<void> shutdown() async {
    if (_stopped) return;
    _stopped = true;
    final save = <String, Conversation>{};
    for (final job in _imageJobs.values) {
      job.cancelled = true;
      if (_deleted.contains(job.conversation.id)) continue;
      if (job.message.meta['status'] == 'pending') {
        job.message.meta['status'] = 'interrupted';
        job.message.text = 'Image generation was interrupted. Ask to generate the image again.';
      }
      save[job.conversation.id] = job.conversation;
    }
    images.close();
    for (final c in save.values) {
      await history.save(c);
    }
  }
}

class _ImageJob {
  _ImageJob(this.conversation, this.message);
  final Conversation conversation;
  Message message;
  bool cancelled = false;
}
