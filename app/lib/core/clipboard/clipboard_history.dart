import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../platform/clipboard_access.dart';

const kClipboardHistoryEntries = 50;
const kClipboardHistoryBytes = 32 * 1024 * 1024;

/// An immutable snapshot: later system clipboard changes cannot alter an item.
class ClipboardHistoryEntry {
  const ClipboardHistoryEntry({required this.id, required this.copiedAt, required this.content});
  final String id;
  final DateTime copiedAt;
  final ClipboardContent content;

  bool get hasImage => content.image != null;
  int get sizeBytes => utf8.encode(content.text ?? '').length + (content.image?.bytes.length ?? 0);
  String get label => content.image?.name ?? 'Text';
  String get searchableText => '${content.text ?? ''} ${content.image?.name ?? ''} ${hasImage ? 'image' : 'text'}';
}

/// Bounded, local clipboard history. Automatic reads never request focus;
/// explicit Capture and Paste may use a native focus handoff on Android.
class ClipboardHistoryController extends ChangeNotifier {
  ClipboardHistoryController({
    required this.clipboard,
    required this.directory,
    this.maxEntries = kClipboardHistoryEntries,
    this.maxBytes = kClipboardHistoryBytes,
    this.pollInterval = const Duration(seconds: 2),
  }) : assert(maxEntries > 0),
       assert(maxBytes > 0);

  final ClipboardAccess clipboard;
  final Directory directory;
  final int maxEntries;
  final int maxBytes;
  final Duration pollInterval;
  List<ClipboardHistoryEntry> _entries = const [];
  List<ClipboardHistoryEntry> get entries => List.unmodifiable(_entries);
  bool loading = true;
  bool capturing = false;
  String? error;
  bool _disposed = false;
  Timer? _timer;
  StreamSubscription<void>? _changes;
  bool _active = false;
  bool _automaticCaptureQueued = false;
  Future<void>? _loading;
  Future<void> _queue = Future.value();
  Future<ClipboardHistoryEntry?>? _capturing;
  String? _lastObservedId;

  bool get supportsBackgroundCapture {
    final source = clipboard;
    return source is ClipboardChangeEvents && (source as ClipboardChangeEvents).supportsBackgroundCapture;
  }

  int get totalBytes => _entries.fold(0, (total, entry) => total + entry.sizeBytes);
  String get retentionLabel => 'Keeps the latest $maxEntries items · ${maxBytes ~/ (1024 * 1024)} MB maximum';
  File get _index => File(p.join(directory.path, 'history.json'));
  File _imageFile(String id) => File(p.join(directory.path, '$id.image'));

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      await directory.create(recursive: true);
      if (await _index.exists()) {
        // Escaped JSON can use six bytes per input byte. Reject an invalid
        // index before reading it, while allowing history saved with larger
        // test/custom limits to be trimmed to the current policy.
        final byteLimit = maxBytes > kClipboardHistoryBytes ? maxBytes : kClipboardHistoryBytes;
        final entryLimit = maxEntries > kClipboardHistoryEntries ? maxEntries : kClipboardHistoryEntries;
        if (await _index.length() > byteLimit * 6 + entryLimit * 4096) {
          throw const FormatException('Saved clipboard history is too large');
        }
        final raw = jsonDecode(await _index.readAsString());
        if (raw is! Map || raw['version'] != 1 || raw['entries'] is! List) {
          throw const FormatException('Unsupported clipboard history format');
        }
        final loaded = <ClipboardHistoryEntry>[];
        final seen = <String>{};
        var bytes = 0;
        var skipped = 0;
        var trimmed = 0;
        for (final value in raw['entries'] as List) {
          try {
            if (value is! Map) throw const FormatException('Invalid clipboard item');
            final id = value['id'] as String;
            if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id)) throw const FormatException('Invalid clipboard item ID');
            if (seen.contains(id) || loaded.length >= maxEntries) {
              trimmed++;
              continue;
            }
            final text = value['text'] as String?;
            final textBytes = utf8.encode(text ?? '').length;
            if (textBytes > maxBytes - bytes) {
              trimmed++;
              continue;
            }
            final imageInfo = value['image'];
            ClipboardImage? image;
            var imageBytes = 0;
            if (imageInfo is Map) {
              final file = _imageFile(id);
              imageBytes = await file.length();
              // Check the remaining aggregate budget before allocating bytes.
              if (imageBytes > maxBytes - bytes - textBytes) {
                trimmed++;
                continue;
              }
              image = ClipboardImage(
                bytes: (await file.readAsBytes()).asUnmodifiableView(),
                mimeType: imageInfo['mimeType'] as String,
                name: imageInfo['name'] as String,
              );
            }
            final content = ClipboardContent(text: text, image: image);
            if (content.isEmpty || _fingerprint(content) != id) {
              throw const FormatException('Clipboard item is damaged');
            }
            loaded.add(
              ClipboardHistoryEntry(id: id, copiedAt: DateTime.parse(value['copiedAt'] as String), content: content),
            );
            seen.add(id);
            bytes += textBytes + imageBytes;
          } catch (_) {
            skipped++;
          }
        }
        _entries = loaded;
        if (skipped > 0 || trimmed > 0) await _commit(loaded);
        await _removeUnreferencedImages();
        final notices = [
          if (skipped > 0) '$skipped saved clipboard item${skipped == 1 ? '' : 's'} could not be read.',
          if (trimmed > 0)
            'Saved clipboard history was trimmed to its item and storage limits ($trimmed item${trimmed == 1 ? '' : 's'}).',
        ];
        if (notices.isNotEmpty) error = notices.join(' ');
      }
    } catch (e) {
      error = 'Could not load clipboard history: ${_message(e)}';
    } finally {
      loading = false;
      _notify();
    }
  }

  Future<void> _removeUnreferencedImages() async {
    final kept = {
      for (final item in _entries)
        if (item.hasImage) '${item.id}.image',
    };
    await for (final file in directory.list()) {
      final name = p.basename(file.path);
      if (file is! File || !RegExp(r'^[a-f0-9]{64}\.image$').hasMatch(name) || kept.contains(name)) continue;
      try {
        await file.delete();
      } on FileSystemException {
        // Metadata is durable; a later load can retry orphan cleanup.
      }
    }
  }

  /// The app lifecycle decides whether capture is allowed. Desktop adapters
  /// may keep it active when hidden; mobile access remains foreground-only.
  void setActive(bool active) {
    if (_disposed || active == _active) return;
    _active = active;
    _timer?.cancel();
    _timer = null;
    unawaited(_changes?.cancel());
    _changes = null;
    _automaticCaptureQueued = false;
    if (!active) return;
    final source = clipboard;
    if (source is ClipboardChangeEvents) {
      _changes = (source as ClipboardChangeEvents).changes.listen(
        (_) => _requestAutomaticCapture(),
        // Notifications are an optimization. The timer remains a backstop if
        // a host drops signals or an optional notification stream fails.
        onError: (Object error, StackTrace stackTrace) {},
      );
    }
    _requestAutomaticCapture();
    _timer = Timer.periodic(pollInterval, (_) => _requestAutomaticCapture());
  }

  void _requestAutomaticCapture() {
    if (!_active || _disposed) return;
    _automaticCaptureQueued = true;
    _drainAutomaticCapture();
  }

  void _drainAutomaticCapture() {
    if (!_active || _disposed || !_automaticCaptureQueued || _capturing != null) return;
    _automaticCaptureQueued = false;
    unawaited(capture(allowFocus: false));
  }

  Future<ClipboardHistoryEntry?> capture({bool allowFocus = true}) {
    if (_disposed) return Future.value();
    final running = _capturing;
    if (running != null) {
      // Passive callers may share the snapshot already being read. An explicit
      // Capture must make a fresh native read, including its focus permission.
      return allowFocus ? running.then((_) => capture()) : running;
    }
    final result = Completer<ClipboardHistoryEntry?>();
    // Set the running future before notifying listeners inside _capture, so a
    // listener or an immediate native event cannot start an overlapping read.
    _capturing = result.future;
    unawaited(_completeCapture(result, allowFocus: allowFocus));
    return result.future;
  }

  Future<void> _completeCapture(Completer<ClipboardHistoryEntry?> result, {required bool allowFocus}) async {
    try {
      result.complete(await _capture(allowFocus: allowFocus));
    } catch (error, stackTrace) {
      result.completeError(error, stackTrace);
    } finally {
      _capturing = null;
      // Let explicit captures already waiting on this result take their turn.
      // A burst of events coalesces to one later read of the latest clipboard;
      // no API can recover intermediate contents overwritten during a read.
      if (_automaticCaptureQueued) scheduleMicrotask(_drainAutomaticCapture);
    }
  }

  Future<ClipboardHistoryEntry?> _capture({required bool allowFocus}) async {
    capturing = true;
    _notify();
    try {
      await load();
      if (_disposed) return null;
      final content = await clipboard.readContent(allowFocus: allowFocus);
      if (_disposed) return null;
      error = null;
      if (content == null || content.isEmpty) return null;
      _validateSize(content);
      final id = _fingerprint(content);
      if (!allowFocus && id == _lastObservedId) {
        for (final item in _entries) {
          if (item.id == id) return item;
        }
        return null;
      }
      // Native clipboard buffers are app-owned. No await separates hashing
      // from this copy, and unchanged items avoid another full-image copy.
      final entry = await _rememberSnapshot(_snapshot(content), id);
      _lastObservedId = id;
      return entry;
    } catch (e) {
      final message = 'Clipboard unavailable: ${_message(e)}';
      if (error != message) error = message;
      return null;
    } finally {
      capturing = false;
      _notify();
    }
  }

  /// Stores exact text and image bytes before exposing the item to the UI.
  Future<ClipboardHistoryEntry> remember(ClipboardContent content) async {
    await load();
    if (content.isEmpty) throw ArgumentError('The clipboard item is empty.');
    _validateSize(content);
    final snapshot = _snapshot(content);
    return _rememberSnapshot(snapshot, _fingerprint(snapshot));
  }

  void _validateSize(ClipboardContent content) {
    if (utf8.encode(content.text ?? '').length + (content.image?.bytes.length ?? 0) <= maxBytes) return;
    error = 'This clipboard item is too large. History accepts up to ${maxBytes ~/ (1024 * 1024)} MB per item.';
    _notify();
    throw StateError(error!);
  }

  static ClipboardContent _snapshot(ClipboardContent content) {
    final image = content.image;
    return ClipboardContent(
      text: content.text,
      image: image == null
          ? null
          : ClipboardImage(
              bytes: Uint8List.fromList(image.bytes).asUnmodifiableView(),
              mimeType: image.mimeType,
              name: image.name,
            ),
    );
  }

  Future<ClipboardHistoryEntry> _rememberSnapshot(ClipboardContent snapshot, String id) {
    final entry = ClipboardHistoryEntry(id: id, copiedAt: DateTime.now(), content: snapshot);
    return _serial(() async {
      final next = [
        entry,
        for (final old in _entries)
          if (old.id != entry.id) old,
      ];
      var bytes = 0;
      final kept = <ClipboardHistoryEntry>[];
      for (final item in next) {
        if (kept.length >= maxEntries || bytes + item.sizeBytes > maxBytes) break;
        kept.add(item);
        bytes += item.sizeBytes;
      }
      if (snapshot.image != null) await _imageFile(entry.id).writeAsBytes(snapshot.image!.bytes, flush: true);
      await _commit(kept);
      _lastObservedId = entry.id;
      return entry;
    });
  }

  Future<void> copy(ClipboardHistoryEntry entry) async {
    await clipboard.writeContent(entry.content);
    await remember(entry.content);
  }

  Future<void> remove(String id) async {
    await load();
    await _serial(
      () => _commit([
        for (final entry in _entries)
          if (entry.id != id) entry,
      ]),
    );
  }

  Future<void> clear() async {
    await load();
    await _serial(() => _commit(const []));
  }

  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        result.complete(await operation());
      } catch (e, st) {
        error = 'Could not save clipboard history: ${_message(e)}';
        _notify();
        result.completeError(e, st);
      }
    });
    return result.future;
  }

  Future<void> _commit(List<ClipboardHistoryEntry> next) async {
    final temp = File('${_index.path}.tmp');
    await temp.writeAsString(
      jsonEncode({
        'version': 1,
        'entries': [
          for (final entry in next)
            {
              'id': entry.id,
              'copiedAt': entry.copiedAt.toUtc().toIso8601String(),
              if (entry.content.text != null) 'text': entry.content.text,
              if (entry.content.image case final image?) 'image': {'mimeType': image.mimeType, 'name': image.name},
            },
        ],
      }),
      flush: true,
    );
    await temp.rename(_index.path);
    final removed = _entries.where((old) => old.hasImage && !next.any((item) => item.id == old.id)).toList();
    _entries = next;
    error = null;
    _notify();
    for (final item in removed) {
      try {
        await _imageFile(item.id).delete();
      } on FileSystemException {
        /* Metadata is already durable. */
      }
    }
  }

  Future<void> flush() => _queue;

  static String _fingerprint(ClipboardContent content) {
    // Preserve the v1 digest exactly without expanding image bytes into a
    // generic List<int>. A near-limit image otherwise allocates hundreds of MB.
    final output = _ClipboardDigestSink();
    final input = sha256.startChunkedConversion(output);
    input.add(utf8.encode(content.text ?? ''));
    input.add(const [0]);
    if (content.image case final image?) input.add(image.bytes);
    input.close();
    return output.digest!.toString();
  }

  static String _message(Object error) => error.toString().replaceFirst(RegExp(r'^(Bad state: |Exception: )'), '');

  @override
  void dispose() {
    _disposed = true;
    _active = false;
    _automaticCaptureQueued = false;
    _timer?.cancel();
    unawaited(_changes?.cancel());
    _changes = null;
    super.dispose();
  }
}

class _ClipboardDigestSink implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest value) => digest = value;

  @override
  void close() {}
}
